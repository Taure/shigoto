-module(shigoto_repo).
-moduledoc """
All SQL operations for Shigoto jobs. Uses `FOR UPDATE SKIP LOCKED`
for safe multi-node job claiming.
""".

-export([
    insert_job/3,
    insert_all/3,
    claim_jobs/3,
    claim_jobs_fair/3,
    complete_job/2,
    complete_job/3,
    fail_job/4,
    discard_job/2,
    cancel_job/2,
    cancel_by/2,
    snooze_job/3,
    retry_job/2,
    retry_by/2,
    rescue_stale_jobs/2,
    heartbeat/2,
    prune_jobs/2,
    prune_archive/2,
    upsert_cron_entry/2,
    get_due_cron_entries/1,
    try_advisory_xact_lock/2,
    current_minute/1,
    cron_progressing/1,
    update_progress/3,
    get_job/2,
    find_jobs/2,
    resolve_dependencies/2,
    archive_jobs/2,
    fetch_fanout_jobs/3
]).

-export_type([claim/0]).

-doc """
The claim a transition is made under: the job map `claim_jobs/3` answered, or
its id. With the map, the claim's `attempt` fences the write: once the job has
been claimed again its attempt has moved on, and a write under the old claim
finds no row.
""".
-type claim() :: #{id := integer(), attempt => integer(), _ => _} | integer().

-define(DEFAULT_UNIQUE, #{
    keys => [worker, args],
    states => [available, executing, retryable],
    period => infinity,
    replace => [],
    debounce => undefined
}).

-doc """
Insert a new job. Respects worker defaults and unique constraints.

With `depends_on`, every job named must exist
(`{error, {missing_dependencies, Ids}}` otherwise). A dependency that has
already finished is not waited for: its result goes straight into the new
job's `deps_results`. Any dependencies between existing jobs are accepted: a
job has no id until it is inserted, so nothing can depend on it yet and an
insert cannot close a circle.

`on_dependency_failure` says what the job does when a job it waits on is
discarded or cancelled: `run` without it, or be `cancel`led or `discard`ed in
turn. Left out, `shigoto_config:on_dependency_failure/0` decides when the
dependency fails. A job that would be cancelled or discarded for a dependency
that has already failed is not inserted: `{error, {dependency_failed, Ids}}`.
""".
-spec insert_job(atom(), map(), map()) ->
    {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert_job(Pool, JobParams0, Opts) ->
    JobParams1 = apply_worker_defaults(JobParams0),
    case stated_policy(JobParams1) of
        {error, _} = Invalid -> Invalid;
        {ok, _Policy} -> insert_validated(Pool, JobParams1, Opts)
    end.

insert_validated(Pool, JobParams1, Opts) ->
    DependsOn = maps:get(depends_on, JobParams1, []),
    case validate_dependencies(Pool, DependsOn, effective_policy(JobParams1)) of
        {ok, Pending, Results} ->
            JobParams = JobParams1#{depends_on => Pending, deps_results => Results},
            case resolve_unique(JobParams, Opts) of
                none ->
                    do_insert(Pool, JobParams, Opts, null);
                UniqueOpts ->
                    insert_unique(Pool, JobParams, Opts, UniqueOpts)
            end;
        {error, _} = Err ->
            Err
    end.

-doc "Bulk insert multiple jobs in a single SQL statement. Returns the inserted jobs in the order given.".
-spec insert_all(atom(), [map()], map()) -> {ok, [map()]} | {error, term()}.
insert_all(_Pool, [], _Opts) ->
    {ok, []};
insert_all(Pool, JobParamsList, Opts) ->
    Jobs = [apply_worker_defaults(J) || J <- JobParamsList],
    case [Invalid || Job <- Jobs, {error, _} = Invalid <- [stated_policy(Job)]] of
        [Invalid | _] -> Invalid;
        [] -> insert_all_validated(Pool, Jobs, Opts)
    end.

insert_all_validated(Pool, Jobs, Opts) ->
    %% The policy column is only named when a job sets one, so a plain insert
    %% is the same statement as before the column existed.
    WithPolicy = lists:any(fun(Job) -> policy_column(Job) =/= null end, Jobs),
    {ParamsPerJob, PolicyColumn} =
        case WithPolicy of
            true -> {11, ~", on_dependency_failure"};
            false -> {10, <<>>}
        end,
    {ValueClauses, AllParams, _} = lists:foldl(
        fun(JobParams, {Clauses, Params, Idx}) ->
            Worker = atom_to_binary(maps:get(worker, JobParams), utf8),
            Args = encode_json(maps:get(args, JobParams, #{})),
            EncArgs = shigoto_crypto:encrypt(Args),
            Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
            Priority = maps:get(priority, JobParams, 0),
            MaxAttempts = maps:get(max_attempts, JobParams, 3),
            ScheduledAt = maps:get(scheduled_at, JobParams, now_timestamptz()),
            Tags = resolve_tags(JobParams),
            TagsArr = encode_pg_array(Tags),
            BatchId = maps:get(batch, JobParams, null),
            PartitionKey = maps:get(partition_key, JobParams, null),
            DependsOn = maps:get(depends_on, JobParams, []),
            Placeholders = lists:join(~", ", [
                <<"$", (integer_to_binary(Idx + N))/binary>>
             || N <- lists:seq(0, ParamsPerJob - 1)
            ]),
            Clause = iolist_to_binary([~"(", Placeholders, ~")"]),
            NewParams =
                Params ++
                    [
                        Queue,
                        Worker,
                        EncArgs,
                        Priority,
                        MaxAttempts,
                        ScheduledAt,
                        TagsArr,
                        BatchId,
                        PartitionKey,
                        DependsOn
                    ] ++ [policy_column(JobParams) || WithPolicy],
            {[Clause | Clauses], NewParams, Idx + ParamsPerJob}
        end,
        {[], [], 1},
        Jobs
    ),
    ValuesSQL = lists:join(~", ", lists:reverse(ValueClauses)),
    Insert = [
        <<
            "INSERT INTO shigoto_jobs "
            "(queue, worker, args, priority, max_attempts, scheduled_at, tags, batch_id, partition_key, depends_on"
        >>,
        PolicyColumn,
        ~") VALUES ",
        ValuesSQL,
        ~" RETURNING *"
    ],
    Batched = [Batch || #{batch := Batch} <- Jobs, Batch =/= null] =/= [],
    case query(Pool, counting_its_batches(Insert, Batched), AllParams) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

%% A batch's total goes up in the statement that inserts its jobs. Counted
%% afterwards, a job could be claimed and finished before its batch knew of it,
%% and the batch would fire its callback with jobs still to come.
-spec counting_its_batches(iodata(), boolean()) -> binary().
counting_its_batches(Insert, false) ->
    iolist_to_binary(Insert);
counting_its_batches(Insert, true) ->
    iolist_to_binary([
        ~"WITH inserted AS (",
        Insert,
        ~"""
        ), counted AS (
          UPDATE shigoto_batches b SET total_jobs = b.total_jobs + batched.jobs
          FROM (
            SELECT batch_id, count(*) AS jobs FROM inserted
            WHERE batch_id IS NOT NULL GROUP BY batch_id
          ) batched
          WHERE b.id = batched.batch_id
        )
        SELECT * FROM inserted
        """
    ]).

-doc """
Claim up to `Limit` due jobs from a queue using `FOR UPDATE SKIP LOCKED`.

A job is due when it is `available` or `retryable`, its `scheduled_at` has
passed and it waits on no dependency. A failed job is `retryable` until the
backoff written to its `scheduled_at` is over, and is then claimed like any
other.

The jobs are answered as they are stored: with an encryption key configured
their `args` and `meta` are still ciphertext. `shigoto_job:opened/1` decrypts
them, once it has checked the worker the row names.

Never answers more than `Limit` jobs. The locking select runs once, as an
uncorrelated `ARRAY(...)` subquery, because `WHERE id IN (SELECT ... LIMIT ...
FOR UPDATE SKIP LOCKED)` lets PostgreSQL plan a semi join that rescans the
subquery for every outer row, and each rescan locks and returns more rows.
""".
-spec claim_jobs(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs(Pool, Queue, Limit) ->
    SQL =
        ~"""
        UPDATE shigoto_jobs SET
          state = 'executing',
          attempted_at = now(),
          heartbeat_at = now(),
          attempt = attempt + 1
        WHERE id = ANY(ARRAY(
          SELECT id FROM shigoto_jobs
          WHERE queue = $1
          AND state IN ('available', 'retryable')
          AND scheduled_at <= now()
          AND depends_on = '{}'
          ORDER BY priority DESC, scheduled_at ASC
          LIMIT $2
          FOR UPDATE SKIP LOCKED
        )) RETURNING *
        """,
    case query(Pool, SQL, [Queue, Limit]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Claim due jobs with fair partition interleaving. One job per partition first, then fill.".
-spec claim_jobs_fair(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs_fair(Pool, Queue, Limit) ->
    %% Two-phase: first get fair-ordered IDs via window function, then lock and update.
    %% The CTE selects IDs in fair order, outer query locks them.
    SQL =
        ~"""
        WITH ranked AS (
          SELECT id,
            ROW_NUMBER() OVER (
              PARTITION BY COALESCE(partition_key, 'null_' || id::text)
              ORDER BY priority DESC, scheduled_at ASC
            ) as rn
          FROM shigoto_jobs
          WHERE queue = $1 AND state IN ('available', 'retryable') AND scheduled_at <= now()
          AND depends_on = '{}'
        ),
        to_claim AS (
          SELECT id FROM ranked ORDER BY rn, id LIMIT $2
        )
        UPDATE shigoto_jobs SET
          state = 'executing', attempted_at = now(), heartbeat_at = now(), attempt = attempt + 1
        WHERE id IN (SELECT id FROM to_claim)
        AND state IN ('available', 'retryable')
        RETURNING *
        """,
    case query(Pool, SQL, [Queue, Limit]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Mark a job as completed with no result. Equivalent to `complete_job/3` with `null`.".
-spec complete_job(atom(), claim()) -> ok | {error, lost | term()}.
complete_job(Pool, Claim) ->
    complete_job(Pool, Claim, null).

-doc """
Mark a claimed job as completed and store its JSON-encodable result on the row.

`Claim` is the job as `claim_jobs/3` answered it. The write only applies while
that claim still holds: the row is `executing` and its `attempt` is the claim's.
A job that was rescued, claimed again or cancelled in the meantime is left as it
is and the answer is `{error, lost}`. Given a bare job id there is no attempt to
compare, and only the `executing` state is checked.

The result is propagated to any jobs that depend on this one (see
`resolve_dependencies/2`) so they can read it via `deps_results`. With an
encryption key and the `v2` write format it is stored encrypted, bound to this
job's id, and stays so in the `deps_results` of its dependents.
""".
-spec complete_job(atom(), claim(), term()) -> ok | {error, lost | term()}.
complete_job(Pool, Claim, Result) ->
    {JobId, Attempt} = fence(Claim),
    ResultJson = sealed_result(JobId, encode_result(Result)),
    SQL =
        ~"""
        WITH done AS (
          UPDATE shigoto_jobs SET state = 'completed', completed_at = now(), result = $2::jsonb
          WHERE id = $1 AND state = 'executing' AND ($3::integer IS NULL OR attempt = $3)
          RETURNING id, result, batch_id
        ), dependents AS (
          UPDATE shigoto_jobs d
          SET depends_on = array_remove(d.depends_on, done.id),
              deps_results = d.deps_results || jsonb_build_object(done.id::text, done.result)
          FROM done WHERE d.depends_on @> ARRAY[done.id] AND d.depends_on <> '{}'
        )
        SELECT batch_id FROM done
        """,
    case query(Pool, SQL, [JobId, ResultJson, Attempt]) of
        #{rows := [#{batch_id := null}]} ->
            ok;
        #{rows := [#{batch_id := BatchId}]} ->
            shigoto_batch:job_completed(Pool, BatchId);
        #{rows := []} ->
            {error, lost};
        {error, _} = Err ->
            Err
    end.

-doc """
Record the failure of a claimed job, with a structured error and the backoff
before its next attempt. At `max_attempts` the job is discarded instead.

The error is written by `shigoto_error:entry/2`, which keeps job args out of
it, and the job keeps its 50 newest errors.

Like `complete_job/3`, the write only applies while the claim in `Job` still
holds, and answers `{error, lost}` otherwise.
""".
-spec fail_job(atom(), map(), term(), pos_integer()) -> ok | {error, lost | term()}.
fail_job(Pool, Job, Reason, BackoffSeconds) ->
    {JobId, Attempt} = fence(Job),
    ErrorJson = encode_json(shigoto_error:entry(Job, Reason)),
    SQL = with_dependents(
        [
            ~"""
            WITH RECURSIVE done AS (
              UPDATE shigoto_jobs SET
                state = CASE WHEN attempt >= max_attempts THEN 'discarded' ELSE 'retryable' END,
                discarded_at = CASE WHEN attempt >= max_attempts THEN now() ELSE NULL END,
                scheduled_at = CASE WHEN attempt >= max_attempts THEN scheduled_at
                  ELSE now() + make_interval(secs => $3) END,
                errors =
            """,
            ~" ",
            shigoto_error:appended(~"errors", ~"$2::jsonb"),
            ~"""

              WHERE id = $1 AND state = 'executing' AND ($4::integer IS NULL OR attempt = $4)
              RETURNING *
            )
            """
        ],
        ~"$5"
    ),
    case query(Pool, SQL, [JobId, ErrorJson, BackoffSeconds, Attempt, default_policy()]) of
        #{rows := []} ->
            {error, lost};
        #{rows := Rows} ->
            {[Updated], Cascaded} = moved(Rows),
            _ = maybe_on_discard(Job, Updated),
            _ = maybe_batch_discard(Pool, Updated),
            dependents_followed(Pool, Cascaded);
        {error, _} = Err ->
            Err
    end.

-doc """
Discard a job that has not finished. Resolves dependencies so dependent jobs
aren't stuck, and counts the job in its batch. A job that is already completed,
discarded or cancelled is left as it is.
""".
-spec discard_job(atom(), integer()) -> ok | {error, term()}.
discard_job(Pool, JobId) ->
    SQL = with_dependents(
        ~"""
        WITH RECURSIVE done AS (
          UPDATE shigoto_jobs SET state = 'discarded', discarded_at = now()
          WHERE id = $1 AND state IN ('available', 'retryable', 'executing')
          RETURNING *
        )
        """,
        ~"$2"
    ),
    case query(Pool, SQL, [JobId, default_policy()]) of
        #{rows := Rows} -> ended(Pool, Rows);
        {error, _} = Err -> Err
    end.

%% The rows a discarding or cancelling statement answered: its own jobs are
%% counted in their batches, and so are the dependents that went with them.
-spec ended(atom(), [map()]) -> ok.
ended(Pool, Rows) ->
    {Own, Cascaded} = moved(Rows),
    ok = batches_told(Pool, Own),
    dependents_followed(Pool, Cascaded).

%% The jobs a statement just discarded or cancelled, counted in their batches.
-spec batches_told(atom(), [#{batch_id := integer() | null, _ => _}]) -> ok.
batches_told(Pool, Rows) ->
    Batched = [BatchId || #{batch_id := BatchId} <- Rows, is_integer(BatchId)],
    _ = [
        shigoto_batch:jobs_discarded(Pool, BatchId, length([B || B <- Batched, B =:= BatchId]))
     || BatchId <- lists:usort(Batched), is_integer(BatchId)
    ],
    ok.

-doc """
Cancel a job that has not finished. Resolves dependencies so dependent jobs
aren't stuck, and counts the job as discarded in its batch, so the batch can
still finish.
""".
-spec cancel_job(atom(), integer()) -> ok | {error, term()}.
cancel_job(Pool, JobId) ->
    SQL = with_dependents(
        ~"""
        WITH RECURSIVE done AS (
          UPDATE shigoto_jobs SET state = 'cancelled', cancelled_at = now()
          WHERE id = $1 AND state IN ('available', 'retryable', 'executing')
          RETURNING *
        )
        """,
        ~"$2"
    ),
    case query(Pool, SQL, [JobId, default_policy()]) of
        #{rows := Rows} -> ended(Pool, Rows);
        {error, _} = Err -> Err
    end.

-doc """
Cancel available or retryable jobs matching a pattern. Filters: `worker`,
`queue`, `tags`, `args`, `state`.

Like `cancel_job/2`, it releases the jobs that depend on a cancelled one and
counts each cancelled job in its batch. Answers how many jobs were cancelled.

With an encryption key configured an `args` filter answers
`{error, args_filter_unsupported_with_encryption}`: stored args are ciphertext,
so it would match nothing.
""".
-spec cancel_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
cancel_by(Pool, Filters) ->
    case args_filter_refused(Filters) of
        {error, _} = Refused -> Refused;
        ok -> cancel_matching(Pool, Filters)
    end.

cancel_matching(Pool, Filters) ->
    {WhereClauses, Params, Next} = build_filter_clauses(Filters, 1),
    Matching = lists:join(~" AND ", [~"state IN ('available', 'retryable')" | WhereClauses]),
    SQL = with_dependents(
        [
            ~"WITH RECURSIVE done AS (UPDATE shigoto_jobs SET state = 'cancelled', cancelled_at = now() WHERE ",
            Matching,
            ~" RETURNING *)"
        ],
        <<"$", (integer_to_binary(Next))/binary>>
    ),
    case query(Pool, SQL, Params ++ [default_policy()]) of
        #{rows := Rows} ->
            ok = ended(Pool, Rows),
            {Own, _Cascaded} = moved(Rows),
            {ok, length(Own)};
        {error, _} = Err ->
            Err
    end.

-doc """
Snooze a claimed job: reschedule it for later without counting it as a failure.

Claiming counts an attempt, so a snooze raises `max_attempts` by one to give
that attempt back. `attempt` keeps counting runs, and a job that snoozes is
never discarded for it.

Like `complete_job/3`, the write only applies while the claim still holds, and
answers `{error, lost}` otherwise.
""".
-spec snooze_job(atom(), claim(), pos_integer()) -> ok | {error, lost | term()}.
snooze_job(Pool, Claim, Seconds) ->
    {JobId, Attempt} = fence(Claim),
    SQL =
        ~"""
        UPDATE shigoto_jobs SET state = 'available',
          scheduled_at = now() + make_interval(secs => $2),
          max_attempts = max_attempts + 1
        WHERE id = $1 AND state = 'executing' AND ($3::integer IS NULL OR attempt = $3)
        RETURNING id
        """,
    case query(Pool, SQL, [JobId, Seconds, Attempt]) of
        #{rows := [_]} -> ok;
        #{rows := []} -> {error, lost};
        {error, _} = Err -> Err
    end.

-doc "Retry a discarded or cancelled job by resetting to available.".
-spec retry_job(atom(), integer()) -> ok | {error, term()}.
retry_job(Pool, JobId) ->
    SQL =
        <<
            "UPDATE shigoto_jobs SET state = 'available', scheduled_at = now()\n"
            "WHERE id = $1 AND state IN ('discarded', 'cancelled')"
        >>,
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc """
Retry all discarded or cancelled jobs matching a filter.

Filters: `worker`, `queue`, `tags`, `args`, and `state` (`discarded` or
`cancelled`, or a list of them) to retry only one of the two.

With an encryption key configured an `args` filter answers
`{error, args_filter_unsupported_with_encryption}`: stored args are ciphertext,
so it would match nothing.
""".
-spec retry_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
retry_by(Pool, Filters) ->
    case args_filter_refused(Filters) of
        {error, _} = Refused -> Refused;
        ok -> retry_matching(Pool, Filters)
    end.

retry_matching(Pool, Filters) ->
    {WhereClauses, Params, _} = build_filter_clauses(Filters, 1),
    WhereSQL =
        case WhereClauses of
            [] ->
                ~"state IN ('discarded', 'cancelled')";
            _ ->
                iolist_to_binary([
                    ~"state IN ('discarded', 'cancelled') AND ",
                    lists:join(~" AND ", WhereClauses)
                ])
        end,
    SQL = iolist_to_binary([
        ~"UPDATE shigoto_jobs SET state = 'available', scheduled_at = now() WHERE ",
        WhereSQL
    ]),
    case query(Pool, SQL, Params) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc """
Rescue the executing jobs whose owner has gone quiet: no claim and no heartbeat
for `StaleSeconds`.

A rescued job goes back to `available` to be claimed again. One that has used up
its attempts is discarded instead, like a job that failed its last attempt:
`on_discard/2` runs, its batch counts it and its dependents are released. So a
job that takes its node down every time it runs stops after `max_attempts`.
Either way the rescue is added to the job's `errors` as `"rescued"`.

Claiming counts as the first heartbeat, and a heartbeat left over from an
earlier attempt is not held against the current one.

Answers how many jobs were rescued.
""".
-spec rescue_stale_jobs(atom(), number()) -> {ok, non_neg_integer()} | {error, term()}.
rescue_stale_jobs(Pool, StaleSeconds) ->
    Entry =
        ~"jsonb_build_object('error', 'rescued', 'at', $2::text, 'attempt', j.attempt, 'worker', j.worker)",
    SQL = with_dependents(
        [
            ~"""
            WITH RECURSIVE stale AS (
              SELECT id FROM shigoto_jobs
              WHERE state = 'executing'
              AND GREATEST(heartbeat_at, attempted_at) < now() - make_interval(secs => $1)
              FOR UPDATE SKIP LOCKED
            ), done AS (
              UPDATE shigoto_jobs j SET
                state = CASE WHEN j.attempt >= j.max_attempts THEN 'discarded' ELSE 'available' END,
                discarded_at = CASE WHEN j.attempt >= j.max_attempts THEN now() ELSE j.discarded_at END,
                heartbeat_at = NULL,
                errors =
            """,
            ~" ",
            shigoto_error:appended(~"j.errors", Entry),
            ~"""

              FROM stale WHERE j.id = stale.id
              RETURNING j.*
            )
            """
        ],
        ~"$3"
    ),
    case query(Pool, SQL, [float(StaleSeconds), now_timestamptz_str(), default_policy()]) of
        #{rows := Rows} ->
            {Rescued, Cascaded} = moved(Rows),
            ok = lists:foreach(fun(Row) -> rescued(Pool, Row) end, Rescued),
            ok = dependents_followed(Pool, Cascaded),
            {ok, length(Rescued)};
        {error, _} = Err ->
            Err
    end.

rescued(Pool, #{state := ~"discarded"} = Job) ->
    _ = shigoto_telemetry:job_rescued(Job),
    _ = maybe_on_discard(Job, Job),
    _ = maybe_batch_discard(Pool, Job),
    _ = shigoto_telemetry:job_discarded(Job),
    ok;
rescued(_Pool, Job) ->
    _ = shigoto_telemetry:job_rescued(Job),
    ok.

-doc """
Record a heartbeat for the claims this node is running, each `{JobId, Attempt}`.

Answers the claims that still hold. One that is missing was rescued and claimed
again, or cancelled: its row is no longer `executing` under that attempt, and it
gets no heartbeat.
""".
-spec heartbeat(atom(), [{integer(), integer()}]) ->
    {ok, [{integer(), integer()}]} | {error, term()}.
heartbeat(_Pool, []) ->
    {ok, []};
heartbeat(Pool, Claims) ->
    {Ids, Attempts} = lists:unzip(Claims),
    SQL =
        ~"""
        UPDATE shigoto_jobs j SET heartbeat_at = now()
        FROM unnest($1::bigint[], $2::integer[]) AS claim(id, attempt)
        WHERE j.id = claim.id AND j.attempt = claim.attempt AND j.state = 'executing'
        RETURNING j.id, j.attempt
        """,
    case query(Pool, SQL, [Ids, Attempts]) of
        #{rows := Rows} -> {ok, [{Id, Attempt} || #{id := Id, attempt := Attempt} <- Rows]};
        {error, _} = Err -> Err
    end.

-doc "Delete completed/discarded jobs older than given days.".
-spec prune_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
prune_jobs(Pool, Days) ->
    SQL =
        <<
            "DELETE FROM shigoto_jobs\n"
            "WHERE state IN ('completed', 'discarded', 'cancelled')\n"
            "AND inserted_at < now() - make_interval(days => $1)"
        >>,
    case query(Pool, SQL, [Days]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Delete archived jobs older than given days. Bounds the archive table.".
-spec prune_archive(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
prune_archive(Pool, Days) ->
    SQL =
        <<
            "DELETE FROM shigoto_jobs_archive\n"
            "WHERE archived_at < now() - make_interval(days => $1)"
        >>,
    case query(Pool, SQL, [Days]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc """
Resolve dependencies of a finished job.

Removes the finished job ID from every dependent's `depends_on` array (which
ungates the dependent once its last predecessor clears) and records the
finished job's `result` under its ID in each dependent's `deps_results`. A job
that produced no result (plain completion, discard, or cancel) contributes a
JSON `null`.
""".
-spec resolve_dependencies(atom(), integer()) -> {ok, non_neg_integer()} | {error, term()}.
resolve_dependencies(Pool, FinishedJobId) ->
    SQL =
        <<
            "UPDATE shigoto_jobs SET\n"
            "depends_on = array_remove(depends_on, $1),\n"
            "deps_results = deps_results || jsonb_build_object(\n"
            "  $1::text, (SELECT result FROM shigoto_jobs WHERE id = $1)\n"
            ")\n"
            "WHERE depends_on @> ARRAY[$1::bigint] AND depends_on <> '{}'"
        >>,
    case query(Pool, SQL, [FinishedJobId]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Update job progress (0-100).".
-spec update_progress(atom(), integer(), 0..100) -> ok | {error, term()}.
update_progress(Pool, JobId, Progress) ->
    SQL = ~"UPDATE shigoto_jobs SET progress = $2 WHERE id = $1",
    case query(Pool, SQL, [JobId, Progress]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc """
Get a job by ID, with its encrypted columns decrypted for reading
(`shigoto_job:readable/1`).
""".
-spec get_job(atom(), integer()) -> {ok, map()} | {error, not_found | term()}.
get_job(Pool, JobId) ->
    SQL = ~"SELECT * FROM shigoto_jobs WHERE id = $1",
    case query(Pool, SQL, [JobId]) of
        #{rows := [Row]} -> {ok, shigoto_job:readable(Row)};
        #{rows := []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

-doc """
Find jobs matching a filter map. Read-only; used by the testing helpers'
DB-backed enqueue assertions.

Filters: `worker`, `queue`, `args` (jsonb containment), `tags` (array
containment), and `state` (a state binary or a list of them). An empty filter
returns all jobs. Returned args are decrypted. With an encryption key
configured an `args` filter answers
`{error, args_filter_unsupported_with_encryption}`: stored args are ciphertext,
so it would match nothing.
""".
-spec find_jobs(atom(), map()) -> {ok, [map()]} | {error, term()}.
find_jobs(Pool, Filters) ->
    case args_filter_refused(Filters) of
        {error, _} = Refused -> Refused;
        ok -> find_matching(Pool, Filters)
    end.

find_matching(Pool, Filters0) ->
    {StateClauses, StateParams, NextIdx} = state_filter_clause(
        maps:get(state, Filters0, undefined), 1
    ),
    OtherFilters = maps:without([state], Filters0),
    {WhereClauses, OtherParams, _} = build_filter_clauses(OtherFilters, NextIdx),
    AllClauses = StateClauses ++ WhereClauses,
    WhereSQL =
        case AllClauses of
            [] -> ~"TRUE";
            _ -> iolist_to_binary(lists:join(~" AND ", AllClauses))
        end,
    SQL = iolist_to_binary([
        ~"SELECT * FROM shigoto_jobs WHERE ", WhereSQL, ~" ORDER BY id ASC"
    ]),
    case query(Pool, SQL, StateParams ++ OtherParams) of
        #{rows := Rows} -> {ok, [shigoto_job:readable(R) || R <- Rows]};
        {error, _} = Err -> Err
    end.

-spec state_filter_clause(binary() | [binary()] | undefined, pos_integer()) ->
    {[binary()], [term()], pos_integer()}.
state_filter_clause(undefined, Idx) ->
    {[], [], Idx};
state_filter_clause(State, Idx) when is_binary(State) ->
    IBin = integer_to_binary(Idx),
    {[<<"state = $", IBin/binary>>], [State], Idx + 1};
state_filter_clause(States, Idx) when is_list(States) ->
    IBin = integer_to_binary(Idx),
    {[<<"state = ANY($", IBin/binary, ")">>], [encode_pg_array(States)], Idx + 1}.

-doc "Archive completed/discarded/cancelled jobs older than given days. Moves to archive table then deletes.".
-spec archive_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
archive_jobs(Pool, Days) ->
    InsertSQL =
        <<
            "INSERT INTO shigoto_jobs_archive\n"
            "(id, queue, worker, args, state, priority, attempt, max_attempts,\n"
            " scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,\n"
            " inserted_at, errors, meta, unique_key, tags, progress, batch_id,\n"
            " heartbeat_at, partition_key, depends_on, result, deps_results)\n"
            "SELECT id, queue, worker, args, state, priority, attempt, max_attempts,\n"
            " scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,\n"
            " inserted_at, errors, meta, unique_key, tags, progress, batch_id,\n"
            " heartbeat_at, partition_key, depends_on, result, deps_results\n"
            "FROM shigoto_jobs\n"
            "WHERE state IN ('completed', 'discarded', 'cancelled')\n"
            "AND inserted_at < now() - make_interval(days => $1)\n"
            "ON CONFLICT (id) DO NOTHING"
        >>,
    DeleteSQL =
        <<
            "DELETE FROM shigoto_jobs\n"
            "WHERE state IN ('completed', 'discarded', 'cancelled')\n"
            "AND inserted_at < now() - make_interval(days => $1)"
        >>,
    shigoto_db:transaction(Pool, fun() ->
        _ = query(Pool, InsertSQL, [Days]),
        case query(Pool, DeleteSQL, [Days]) of
            #{num_rows := Count} -> {ok, Count};
            {error, _} = Err -> Err
        end
    end).

-doc """
Upsert a cron entry, keyed by `name`.

`last_scheduled_at`, when given, is the minute the entry was last scheduled for.
It only ever moves forward: an upsert without it, or with an earlier minute
than the stored one, keeps the stored one. A stored minute more than 60 minutes
ahead of the database clock is replaced, so a minute stored by a node whose
clock was far ahead does not stop the entry until that time comes.

`args` is stored encrypted when an encryption key is configured, as job args
are (`m:shigoto_crypto`). shigoto never reads the column back; the args a cron
job runs with come from the configured entry.
""".
-spec upsert_cron_entry(atom(), map()) -> ok | {error, term()}.
upsert_cron_entry(Pool, Entry) ->
    SQL =
        <<
            "INSERT INTO shigoto_cron\n"
            "(name, worker, args, schedule, queue, priority, max_attempts, last_scheduled_at)\n"
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)\n"
            "ON CONFLICT (name) DO UPDATE SET\n"
            "worker = EXCLUDED.worker, args = EXCLUDED.args, schedule = EXCLUDED.schedule,\n"
            "queue = EXCLUDED.queue, priority = EXCLUDED.priority, max_attempts = EXCLUDED.max_attempts,\n"
            "last_scheduled_at = CASE\n"
            "  WHEN shigoto_cron.last_scheduled_at > now() + interval '60 minutes'\n"
            "  THEN EXCLUDED.last_scheduled_at\n"
            "  ELSE GREATEST(EXCLUDED.last_scheduled_at, shigoto_cron.last_scheduled_at)\n"
            "END"
        >>,
    Worker = atom_to_binary(maps:get(worker, Entry)),
    EncArgs = shigoto_crypto:seal(encode_json(maps:get(args, Entry, #{})), {cron_args, Worker}),
    case
        query(Pool, SQL, [
            maps:get(name, Entry),
            Worker,
            EncArgs,
            maps:get(schedule, Entry),
            maps:get(queue, Entry, ~"default"),
            maps:get(priority, Entry, 0),
            maps:get(max_attempts, Entry, 3),
            maps:get(last_scheduled_at, Entry, null)
        ])
    of
        #{command := insert} -> ok;
        {error, _} = Err -> Err
    end.

-doc "All stored cron entries, with the minute each was last scheduled for.".
-spec get_due_cron_entries(atom()) -> {ok, [map()]} | {error, term()}.
get_due_cron_entries(Pool) ->
    SQL = ~"SELECT * FROM shigoto_cron",
    case query(Pool, SQL, []) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc """
Whether any cron entry has been scheduled up to the previous minute or later.

A pass that finds the cron lock taken asks this: while a node runs passes, the
previous minute's pass has stored that minute.
""".
-spec cron_progressing(atom()) -> {ok, boolean()} | {error, term()}.
cron_progressing(Pool) ->
    SQL =
        ~"""
        SELECT COALESCE(
          max(last_scheduled_at) >= date_trunc('minute', now()) - interval '1 minute', false
        ) AS progressing
        FROM shigoto_cron
        """,
    case query(Pool, SQL, []) of
        #{rows := [#{progressing := Progressing}]} when is_boolean(Progressing) ->
            {ok, Progressing};
        {error, _} = Err ->
            Err
    end.

-doc """
The database's current minute, as a UTC datetime.

Inside a transaction this is the minute the transaction started in, so every
node that asks agrees, whatever its own clock says.
""".
-spec current_minute(atom()) -> {ok, calendar:datetime()} | {error, term()}.
current_minute(Pool) ->
    case query(Pool, ~"SELECT date_trunc('minute', now()) AS minute", []) of
        #{rows := [#{minute := Minute}]} -> {ok, Minute};
        {error, _} = Err -> Err
    end.

-doc """
Take a transaction-scoped advisory lock without waiting.

`true` when this transaction holds the lock, `false` when another one does. Call
it inside `shigoto_db:transaction/2`: the lock is released when that ends. The
key is this installation's own when an `instance` is configured
(`m:shigoto_lock`).
""".
-spec try_advisory_xact_lock(atom(), integer()) -> boolean() | {error, term()}.
try_advisory_xact_lock(Pool, Key) ->
    shigoto_lock:try_xact(Pool, Key).

%%----------------------------------------------------------------------
%% Internal: the dependents of a job that failed
%%----------------------------------------------------------------------

%% Completes a statement whose `done` rows are the jobs it just moved. Those
%% now discarded or cancelled have failed, and each job waiting on one follows
%% its own `on_dependency_failure`: released to run without it (`run`), or
%% cancelled or discarded in turn, which fails it for its own dependents. One
%% statement walks the whole way down. `DefaultPolicy` is the placeholder of
%% the policy for jobs that name none.
%%
%% The policy is read through to_jsonb so the statement also runs on a schema
%% from before the column existed. A job the statement moved itself is never
%% touched a second time as a dependent: PostgreSQL applies only one of two
%% updates to a row within a statement.
-spec with_dependents(iodata(), binary()) -> binary().
with_dependents(Done, DefaultPolicy) ->
    Tail =
        ~"""
        , failed(id, policy) AS (
          SELECT id, NULL::text FROM done WHERE state IN ('discarded', 'cancelled')
          UNION
          SELECT d.id, COALESCE(to_jsonb(d) ->> 'on_dependency_failure', $default::text)
          FROM failed f
          JOIN shigoto_jobs d ON d.depends_on @> ARRAY[f.id] AND d.depends_on <> '{}'
          WHERE d.state IN ('available', 'retryable')
          AND d.id NOT IN (SELECT id FROM done)
          AND COALESCE(to_jsonb(d) ->> 'on_dependency_failure', $default::text)
            IN ('cancel', 'discard')
        ), cascaded AS (
          UPDATE shigoto_jobs d SET
            state = CASE f.policy WHEN 'cancel' THEN 'cancelled' ELSE 'discarded' END,
            cancelled_at = CASE f.policy WHEN 'cancel' THEN now() ELSE d.cancelled_at END,
            discarded_at = CASE f.policy WHEN 'cancel' THEN d.discarded_at ELSE now() END,
            depends_on = ARRAY(SELECT unnest(d.depends_on) EXCEPT SELECT id FROM failed),
            errors = $errors
          FROM failed f WHERE d.id = f.id AND f.policy IS NOT NULL
          RETURNING d.*
        ), released AS (
          UPDATE shigoto_jobs d SET
            depends_on = ARRAY(SELECT unnest(d.depends_on) EXCEPT SELECT id FROM failed),
            deps_results = d.deps_results || (
              SELECT COALESCE(jsonb_object_agg(p.id::text, p.result), '{}'::jsonb)
              FROM shigoto_jobs p
              WHERE p.id = ANY(d.depends_on) AND p.id IN (SELECT id FROM failed)
            )
          WHERE d.depends_on && ARRAY(SELECT id FROM failed) AND d.depends_on <> '{}'
          AND d.id NOT IN (SELECT id FROM failed)
        )
        SELECT false AS cascaded, * FROM done
        UNION ALL
        SELECT true AS cascaded, * FROM cascaded
        """,
    Entry =
        ~"""
        jsonb_build_object(
          'error', 'dependency_failed',
          'at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'attempt', d.attempt,
          'worker', d.worker
        )
        """,
    Errors = shigoto_error:appended(~"d.errors", Entry),
    iolist_to_binary([
        Done,
        binary:replace(
            binary:replace(Tail, ~"$default", DefaultPolicy, [global]), ~"$errors", Errors
        )
    ]).

-spec default_policy() -> binary().
default_policy() ->
    atom_to_binary(shigoto_config:on_dependency_failure()).

%% The rows such a statement answers: the jobs it moved itself, and the waiting
%% jobs that were cancelled or discarded after them.
-spec moved([map()]) -> {Own :: [map()], Cascaded :: [map()]}.
moved(Rows) ->
    {[Row || #{cascaded := false} = Row <- Rows], [Row || #{cascaded := true} = Row <- Rows]}.

-spec dependents_followed(atom(), [map()]) -> ok.
dependents_followed(Pool, Cascaded) ->
    _ = [followed(Job) || Job <- Cascaded],
    batches_told(Pool, Cascaded).

followed(#{state := ~"discarded"} = Job) ->
    _ = maybe_on_discard(Job, Job),
    shigoto_telemetry:job_discarded(Job);
followed(Job) ->
    shigoto_telemetry:job_cancelled(Job).

%%----------------------------------------------------------------------
%% Internal: fencing
%%----------------------------------------------------------------------

-spec fence(claim()) -> {integer(), integer() | null}.
fence(#{id := JobId, attempt := Attempt}) when is_integer(Attempt) -> {JobId, Attempt};
fence(#{id := JobId}) -> {JobId, null};
fence(JobId) when is_integer(JobId) -> {JobId, null}.

%%----------------------------------------------------------------------
%% Internal: dependency validation
%%----------------------------------------------------------------------

%% The policy a job names for itself, if it names a valid one.
-spec stated_policy(map()) -> {ok, run | cancel | discard | undefined} | {error, term()}.
stated_policy(JobParams) ->
    case maps:get(on_dependency_failure, JobParams, undefined) of
        Policy when Policy =:= run; Policy =:= cancel; Policy =:= discard; Policy =:= undefined ->
            {ok, Policy};
        Other ->
            {error, {invalid_on_dependency_failure, Other}}
    end.

effective_policy(JobParams) ->
    case maps:get(on_dependency_failure, JobParams, undefined) of
        undefined -> shigoto_config:on_dependency_failure();
        Policy -> Policy
    end.

policy_column(JobParams) ->
    case maps:get(on_dependency_failure, JobParams, undefined) of
        undefined -> null;
        Policy -> atom_to_binary(Policy)
    end.

-spec validate_dependencies(atom(), [integer()], run | cancel | discard) ->
    {ok, Pending :: [integer()], Results :: #{binary() => term()}} | {error, term()}.
validate_dependencies(_Pool, [], _Policy) ->
    {ok, [], #{}};
validate_dependencies(Pool, DepIds, Policy) ->
    SQL = ~"SELECT id, state, result FROM shigoto_jobs WHERE id = ANY($1::bigint[])",
    case query(Pool, SQL, [DepIds]) of
        #{rows := Rows} ->
            Jobs = #{Id => Row || #{id := Id} = Row <- Rows},
            case [Id || Id <- DepIds, not is_map_key(Id, Jobs)] of
                [] -> waited_for(DepIds, Jobs, Policy);
                Missing -> {error, {missing_dependencies, Missing}}
            end;
        {error, _} = Err ->
            Err
    end.

%% There is no cycle to look for: a job has no id until it is inserted, so
%% nothing can depend on it yet and an insert cannot close a circle.
waited_for(DepIds, Jobs, Policy) ->
    Finished = [Id || Id <- DepIds, is_finished(maps:get(Id, Jobs))],
    case [Id || Id <- Finished, Policy =/= run, has_failed(maps:get(Id, Jobs))] of
        [] ->
            Results =
                #{
                    integer_to_binary(Id) => decoded_result(maps:get(Id, Jobs))
                 || Id <- Finished
                },
            {ok, lists:usort(DepIds) -- Finished, Results};
        Failed ->
            {error, {dependency_failed, Failed}}
    end.

is_finished(#{state := State}) ->
    lists:member(State, [~"completed", ~"discarded", ~"cancelled"]).

has_failed(#{state := State}) ->
    lists:member(State, [~"discarded", ~"cancelled"]).

decoded_result(#{result := null}) -> null;
decoded_result(#{result := Result}) when is_binary(Result) -> json:decode(Result);
decoded_result(#{result := Result}) -> Result.

%%----------------------------------------------------------------------
%% Internal: unique jobs
%%----------------------------------------------------------------------

apply_worker_defaults(JobParams) ->
    Worker = maps:get(worker, JobParams),
    _ = code:ensure_loaded(Worker),
    Defaults = lists:foldl(
        fun({Callback, Key}, Acc) ->
            case maps:is_key(Key, JobParams) of
                true ->
                    Acc;
                false ->
                    case erlang:function_exported(Worker, Callback, 0) of
                        true -> Acc#{Key => Worker:Callback()};
                        false -> Acc
                    end
            end
        end,
        JobParams,
        [{max_attempts, max_attempts}, {queue, queue}, {priority, priority}]
    ),
    Defaults.

resolve_unique(JobParams, Opts) ->
    case Opts of
        #{unique := UniqueOpts} when is_map(UniqueOpts) ->
            maps:merge(?DEFAULT_UNIQUE, UniqueOpts);
        _ ->
            Worker = maps:get(worker, JobParams),
            case erlang:function_exported(Worker, unique, 0) of
                true -> maps:merge(?DEFAULT_UNIQUE, Worker:unique());
                false -> none
            end
    end.

insert_unique(Pool, JobParams, Opts, UniqueOpts) ->
    Worker = atom_to_binary(maps:get(worker, JobParams), utf8),
    Args = maps:get(args, JobParams, #{}),
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
    %% One key per configured encryption key, the current one first. The job
    %% is stored under the current one and looked for under all of them, so a
    %% job inserted before a key rotation still counts as the duplicate it is.
    [UniqueKey | _] = UniqueKeys = build_unique_keys(UniqueOpts, Worker, Args, Queue),
    LockKeys = [erlang:phash2(Key) || Key <- UniqueKeys],
    shigoto_db:transaction(Pool, fun() ->
        case shigoto_lock:acquire_xact(Pool, LockKeys) of
            ok ->
                case find_existing_job(Pool, UniqueOpts, UniqueKeys) of
                    {ok, Existing} ->
                        maybe_replace(Pool, Existing, JobParams, UniqueOpts);
                    not_found ->
                        do_insert(Pool, JobParams, Opts, UniqueKey);
                    {error, _} = Err ->
                        Err
                end;
            {error, lock_timeout} ->
                {error, {lock_timeout, unique}};
            {error, Reason} ->
                {error, shigoto_db:reduced(Reason)}
        end
    end).

build_unique_keys(#{keys := Keys}, Worker, Args, Queue) ->
    Parts = lists:map(
        fun
            (worker) -> Worker;
            (args) -> encode_json(Args);
            (queue) -> Queue
        end,
        lists:sort(Keys)
    ),
    shigoto_crypto:unique_keys(iolist_to_binary(lists:join(~":", Parts))).

find_existing_job(Pool, #{states := States, period := Period}, UniqueKeys) ->
    StatesClause = states_in_clause(States),
    {SQL, Params} =
        case Period of
            infinity ->
                {
                    iolist_to_binary([
                        ~"SELECT * FROM shigoto_jobs WHERE unique_key = ANY($1::text[]) AND state IN (",
                        StatesClause,
                        ~") ORDER BY id ASC LIMIT 1"
                    ]),
                    [UniqueKeys]
                };
            Secs ->
                {
                    iolist_to_binary([
                        ~"SELECT * FROM shigoto_jobs WHERE unique_key = ANY($1::text[]) AND state IN (",
                        StatesClause,
                        ~") AND inserted_at >= now() - make_interval(secs => $2) ORDER BY id ASC LIMIT 1"
                    ]),
                    [UniqueKeys, Secs]
                }
        end,
    case query(Pool, SQL, Params) of
        #{rows := [Row]} -> {ok, Row};
        #{rows := []} -> not_found;
        {error, _} = Err -> Err
    end.

states_in_clause(States) ->
    Quoted = [<<"'", (atom_to_binary(S))/binary, "'">> || S <- States],
    lists:join(~", ", Quoted).

maybe_replace(Pool, Existing, _JobParams, #{replace := [], debounce := Seconds}) when
    is_integer(Seconds), Seconds > 0
->
    %% Debounce: reset scheduled_at to now() + Seconds
    IBin = ~"2",
    SQL = iolist_to_binary([
        ~"UPDATE shigoto_jobs SET scheduled_at = now() + make_interval(secs => $",
        IBin,
        ~") WHERE id = $1 RETURNING *"
    ]),
    case query(Pool, SQL, [maps:get(id, Existing), Seconds]) of
        #{rows := [Updated]} -> {ok, {conflict, Updated}};
        {error, _} = Err -> Err
    end;
maybe_replace(_Pool, Existing, _JobParams, #{replace := []}) ->
    {ok, {conflict, Existing}};
maybe_replace(Pool, Existing, JobParams, #{replace := Fields, debounce := Debounce}) ->
    {SetParts0, Params0, NextIdx} = lists:foldl(
        fun(Field, {Acc, Ps, I}) ->
            {Col, Val} = replace_field_value(Field, JobParams, Existing),
            IBin = integer_to_binary(I),
            Part = <<Col/binary, " = $", IBin/binary>>,
            {[Part | Acc], Ps ++ [Val], I + 1}
        end,
        {[], [maps:get(id, Existing)], 2},
        Fields
    ),
    %% Append debounce scheduled_at reset if configured
    {SetParts, Params} =
        case is_integer(Debounce) andalso Debounce > 0 of
            true ->
                IBin2 = integer_to_binary(NextIdx),
                Part = <<"scheduled_at = now() + make_interval(secs => $", IBin2/binary, ")">>,
                {[Part | SetParts0], Params0 ++ [Debounce]};
            false ->
                {SetParts0, Params0}
        end,
    SetClause = lists:join(~", ", lists:reverse(SetParts)),
    SQL = iolist_to_binary([
        ~"UPDATE shigoto_jobs SET ",
        SetClause,
        ~" WHERE id = $1 RETURNING *"
    ]),
    case query(Pool, SQL, Params) of
        #{rows := [Updated]} -> {ok, {conflict, Updated}};
        {error, _} = Err -> Err
    end.

%% The new args go into the existing row, so they are encrypted for the worker
%% that row names, which need not be the worker of the job that replaces them.
replace_field_value(args, JobParams, #{worker := Worker}) when is_binary(Worker) ->
    ArgsJson = encode_json(maps:get(args, JobParams, #{})),
    {~"args", shigoto_crypto:seal(ArgsJson, {args, Worker})};
replace_field_value(priority, JobParams, _Existing) ->
    {~"priority", maps:get(priority, JobParams, 0)};
replace_field_value(max_attempts, JobParams, _Existing) ->
    {~"max_attempts", maps:get(max_attempts, JobParams, 3)};
replace_field_value(scheduled_at, JobParams, _Existing) ->
    {~"scheduled_at", maps:get(scheduled_at, JobParams, now_timestamptz())}.

%%----------------------------------------------------------------------
%% Internal: insert
%%----------------------------------------------------------------------

do_insert(Pool, JobParams, Opts, UniqueKey) ->
    Worker = atom_to_binary(maps:get(worker, JobParams), utf8),
    Args = maps:get(args, JobParams, #{}),
    Meta = maps:get(meta, JobParams, #{}),
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
    Priority = maps:get(priority, JobParams, 0),
    MaxAttempts = maps:get(max_attempts, JobParams, 3),
    ScheduledAt = maps:get(scheduled_at, JobParams, now_timestamptz()),
    Tags = resolve_tags(JobParams),
    TagsArr = encode_pg_array(Tags),
    BatchId = maps:get(batch, JobParams, null),
    PartitionKey = maps:get(partition_key, JobParams, null),
    DependsOn = maps:get(depends_on, JobParams, []),
    EncArgs = shigoto_crypto:seal(encode_json(Args), {args, Worker}),
    EncMeta = shigoto_crypto:seal(encode_json(Meta), {meta, Worker}),
    %% The policy column is only named when the job sets one, so a plain insert
    %% is the same statement as before the column existed.
    {PolicyColumn, PolicyValue, PolicyParam} =
        case policy_column(JobParams) of
            null -> {<<>>, <<>>, []};
            Policy -> {~", on_dependency_failure", ~", $14", [Policy]}
        end,
    Insert = [
        <<
            "INSERT INTO shigoto_jobs "
            "(queue, worker, args, meta, priority, max_attempts, scheduled_at, unique_key, tags, batch_id, partition_key, depends_on, deps_results"
        >>,
        PolicyColumn,
        ~") VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb",
        PolicyValue,
        ~") RETURNING *"
    ],
    case
        query(
            Pool,
            counting_its_batches(Insert, BatchId =/= null),
            [
                Queue,
                Worker,
                EncArgs,
                EncMeta,
                Priority,
                MaxAttempts,
                ScheduledAt,
                UniqueKey,
                TagsArr,
                BatchId,
                PartitionKey,
                DependsOn,
                encode_json(maps:get(deps_results, JobParams, #{}))
            ] ++ PolicyParam
        )
    of
        #{rows := [Row]} -> {ok, Row};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal: filters for cancel_by
%%----------------------------------------------------------------------

args_filter_refused(#{args := _}) ->
    case shigoto_crypto:is_enabled() of
        true -> {error, args_filter_unsupported_with_encryption};
        false -> ok
    end;
args_filter_refused(_Filters) ->
    ok.

build_filter_clauses(Filters, StartIdx) ->
    maps:fold(
        fun(Key, Value, {Clauses, Params, Idx}) ->
            {Clause, NewParams, NewIdx} = filter_clause(Key, Value, Idx),
            {[Clause | Clauses], Params ++ NewParams, NewIdx}
        end,
        {[], [], StartIdx},
        Filters
    ).

filter_clause(worker, Worker, Idx) ->
    IBin = integer_to_binary(Idx),
    WorkerBin =
        case Worker of
            W when is_atom(W) -> atom_to_binary(W, utf8);
            W when is_binary(W) -> W
        end,
    {<<"worker = $", IBin/binary>>, [WorkerBin], Idx + 1};
filter_clause(queue, Queue, Idx) ->
    IBin = integer_to_binary(Idx),
    {<<"queue = $", IBin/binary>>, [Queue], Idx + 1};
filter_clause(tags, Tags, Idx) when is_list(Tags) ->
    IBin = integer_to_binary(Idx),
    {<<"tags @> $", IBin/binary>>, [encode_pg_array(Tags)], Idx + 1};
filter_clause(args, ArgsMatch, Idx) when is_map(ArgsMatch) ->
    IBin = integer_to_binary(Idx),
    {<<"args @> $", IBin/binary, "::jsonb">>, [encode_json(ArgsMatch)], Idx + 1};
filter_clause(state, State, Idx) ->
    IBin = integer_to_binary(Idx),
    {<<"state = ANY($", IBin/binary, ")">>, [state_names(State)], Idx + 1}.

state_names(States) when is_list(States) -> [state_name(S) || S <- States];
state_names(State) -> [state_name(State)].

state_name(State) when is_atom(State) -> atom_to_binary(State);
state_name(State) when is_binary(State) -> State.

%%----------------------------------------------------------------------
%% Internal: batch helpers
%%----------------------------------------------------------------------

maybe_batch_discard(Pool, #{state := ~"discarded", batch_id := BatchId}) when
    BatchId =/= null
->
    shigoto_batch:jobs_discarded(Pool, BatchId, 1);
maybe_batch_discard(_Pool, _Job) ->
    ok.

%% on_discard/2 gets the job's args, so they are only decrypted for a row whose
%% worker passes the check, and only when that worker has the callback. A job
%% discarded on a node without its worker module, or whose args do not open,
%% has no callback to run.
maybe_on_discard(OrigJob, #{state := ~"discarded", errors := Errors}) ->
    case shigoto_job:worker(OrigJob) of
        {ok, Worker} ->
            case erlang:function_exported(Worker, on_discard, 2) of
                true -> discarded(Worker, OrigJob, Errors);
                false -> ok
            end;
        {error, _} ->
            ok
    end;
maybe_on_discard(_OrigJob, _Updated) ->
    ok.

discarded(Worker, Job, Errors) ->
    case shigoto_job:opened(Job) of
        {ok, _Worker, #{args := Args}} ->
            try
                Worker:on_discard(Args, decoded_errors(Errors))
            catch
                _:_ -> ok
            end;
        {error, _} ->
            ok
    end.

decoded_errors(Errors) when is_binary(Errors) -> json:decode(Errors);
decoded_errors(Errors) -> Errors.

%%----------------------------------------------------------------------
%% Internal: helpers
%%----------------------------------------------------------------------

resolve_tags(JobParams) ->
    Worker = maps:get(worker, JobParams),
    ExplicitTags = maps:get(tags, JobParams, undefined),
    case ExplicitTags of
        undefined ->
            _ = code:ensure_loaded(Worker),
            case erlang:function_exported(Worker, tags, 0) of
                true -> Worker:tags();
                false -> []
            end;
        Tags when is_list(Tags) ->
            Tags
    end.

-doc "Fetch recent jobs for fanout queues. No locking — all nodes read the same rows.".
-spec fetch_fanout_jobs(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
fetch_fanout_jobs(Pool, Queue, WindowSeconds) ->
    SQL =
        <<
            "SELECT * FROM shigoto_jobs\n"
            "WHERE queue = $1\n"
            "AND state = 'available'\n"
            "AND scheduled_at <= now()\n"
            "AND inserted_at >= now() - make_interval(secs => $2)\n"
            "ORDER BY priority DESC, inserted_at ASC"
        >>,
    case query(Pool, SQL, [Queue, WindowSeconds]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

query(Pool, SQL, Params) ->
    shigoto_db:query(Pool, SQL, Params).

now_timestamptz() ->
    calendar:universal_time().

now_timestamptz_str() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
            [Y, Mo, D, H, Mi, S]
        )
    ).

encode_json(Map) when is_map(Map) ->
    iolist_to_binary(json:encode(Map));
encode_json(Bin) when is_binary(Bin) ->
    Bin.

%% NULL stays NULL: there is nothing to encrypt, and a dependent reads it as
%% the JSON null a job without a result contributes.
sealed_result(_JobId, null) -> null;
sealed_result(JobId, Json) -> shigoto_crypto:seal(Json, {result, JobId}).

encode_result(null) ->
    null;
encode_result(undefined) ->
    null;
encode_result(Result) ->
    iolist_to_binary(json:encode(Result)).

encode_pg_array(Tags) when is_list(Tags) ->
    Tags;
encode_pg_array(_) ->
    [].
