-module(shigoto_repo).
-moduledoc """
All SQL operations for Shigoto jobs. Uses `FOR UPDATE SKIP LOCKED`
for safe multi-node job claiming.
""".

-export([
    insert_job/3,
    insert_all/3,
    placed_all/3,
    claim_jobs/3,
    claim_jobs_fair/3,
    complete_job/2,
    complete_job/3,
    fail_job/4,
    discard_job/2,
    cancel_job/2,
    cancelled_job/2,
    cancel_by/2,
    snooze_job/3,
    put_back_job/4,
    release_job/2,
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
    release_stuck_dependents/1,
    archive_jobs/2,
    fetch_fanout_jobs/3,
    unique_materials/3
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

A job with `batch` for a queue this node has in `fanout_queues` is refused
with `{error, {fanout_job_in_batch, Queue}}`: no node ends a fanout job, so
the batch would never finish.

`on_dependency_failure` says what the job does when a job it waits on is
discarded or cancelled: `run` without it, or be `cancel`led or `discard`ed in
turn. Left out, `shigoto_config:on_dependency_failure/0` decides when the
dependency fails. A job that would be cancelled or discarded for a dependency
that has already failed is not inserted: `{error, {dependency_failed, Ids}}`.
""".
-spec insert_job(atom(), map(), map()) ->
    {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert_job(Pool, JobParams0, Opts) ->
    JobParams1 = shigoto_propagator:stamped(
        apply_worker_defaults(JobParams0), shigoto_propagator:injected()
    ),
    case insertable(JobParams1, Opts) of
        {error, _} = Invalid -> Invalid;
        ok -> insert_validated(Pool, JobParams1, Opts)
    end.

insert_validated(Pool, JobParams1, Opts) ->
    DependsOn = maps:get(depends_on, JobParams1, []),
    case validate_dependencies(Pool, DependsOn, effective_policy(JobParams1)) of
        {ok, Pending, Results} ->
            JobParams = (waiting_for(JobParams1, DependsOn))#{
                depends_on => Pending, deps_results => Results
            },
            case resolve_unique(JobParams, Opts) of
                none ->
                    do_insert(Pool, JobParams, Opts, null);
                UniqueOpts ->
                    insert_unique(Pool, JobParams, Opts, UniqueOpts)
            end;
        {error, _} = Err ->
            Err
    end.

-doc """
Bulk insert multiple jobs. Answers one job per job given, in the order given.

Dependencies are checked as `insert_job/3` checks them, with one query for all
the jobs: a missing dependency, or a failed one a job would not run without,
refuses the whole call.

Jobs that are not unique go in with a single statement. A job whose worker
exports `unique/0`, or every job when `Opts` has a `unique` map, is inserted
the way `insert_job/3` inserts it, and the whole call is then one transaction:
the unique locks of every such job are taken first, and a lock that cannot be
had in `advisory_lock_timeout` answers `{error, {lock_timeout, unique}}` with
nothing inserted. A call may take `unique_lock_limit` locks (1000 unless set):
one that needs more answers `{error, {too_many_unique_locks, Needed, Limit}}`
and inserts nothing. Split such a list; each call is then its own unit. A job that turns out to be a duplicate, of a stored job or of
an earlier one in the same call, is answered as the job that is already there
(replaced or debounced as its `unique` options say), in its place in the list.
`unique => false` in `Opts` inserts every job without looking.
""".
-spec insert_all(atom(), [map()], map()) -> {ok, [map()]} | {error, term()}.
insert_all(Pool, JobParamsList, Opts) ->
    case placed_all(Pool, JobParamsList, Opts) of
        {ok, Placed} -> {ok, [Job || {_Outcome, Job} <- Placed]};
        {error, _} = Refused -> Refused
    end.

-doc false.
-spec placed_all(atom(), [map()], map()) ->
    {ok, [{inserted | conflict, map()}]} | {error, term()}.
placed_all(_Pool, [], _Opts) ->
    {ok, []};
placed_all(Pool, JobParamsList, Opts) ->
    Carrier = shigoto_propagator:injected(),
    Jobs = [shigoto_propagator:stamped(apply_worker_defaults(J), Carrier) || J <- JobParamsList],
    case [Invalid || Job <- Jobs, {error, _} = Invalid <- [insertable(Job, Opts)]] of
        [Invalid | _] ->
            Invalid;
        [] ->
            case with_dependencies(Pool, Jobs) of
                {ok, Validated} ->
                    Resolved = [{Job, resolve_unique(Job, Opts)} || Job <- Validated],
                    case [Job || {Job, none} <- Resolved] of
                        Plain when length(Plain) =:= length(Resolved) ->
                            inserted(insert_all_validated(Pool, Plain, Opts));
                        _Mixed ->
                            placed_with_unique(Pool, Resolved, Opts)
                    end;
                {error, _} = Refused ->
                    Refused
            end
    end.

inserted({ok, Rows}) -> {ok, [{inserted, Row} || Row <- Rows]};
inserted({error, _} = Refused) -> Refused.

%% Every unique lock of the call is taken before anything is written, so a
%% lock that cannot be had costs nothing. After that only a failed statement
%% can stop the call, and the raise undoes what the call wrote. Joined to a
%% transaction the caller opened there is nothing to undo here: PostgreSQL has
%% already failed that transaction.
%%
%% The locks are held to the end of the call, in a lock table the whole server
%% shares, so a call may only take `unique_lock_limit` of them.
placed_with_unique(Pool, Resolved, Opts) ->
    Keyed = [keyed(Job, Unique, Opts) || {Job, Unique} <- Resolved],
    LockKeys = ordsets:from_list([
        erlang:phash2(Key)
     || {_Job, _Unique, Keys} <- Keyed, Key <- Keys
    ]),
    Limit = shigoto_config:unique_lock_limit(),
    case length(LockKeys) of
        Needed when Needed > Limit ->
            {error, {too_many_unique_locks, Needed, Limit}};
        _Allowed ->
            try
                undone_when_refused(Pool, fun() ->
                    case unique_locks(Pool, LockKeys) of
                        ok -> {ok, placed_in_order(Pool, Keyed, Opts)};
                        {error, _} = Refused -> Refused
                    end
                end)
            catch
                throw:{?MODULE, insert_all_failed, {error, Reason}} ->
                    {error, shigoto_db:reduced(Reason)}
            end
    end.

%% A transaction whose function answers `{error, _}` is rolled back and
%% answers that error. Committed, a transaction in which a statement failed is
%% answered with ROLLBACK, and the caller would get `transaction_rolled_back`
%% raised in place of the reason.
-spec undone_when_refused(atom(), fun(() -> Answer)) -> Answer | {error, term()}.
undone_when_refused(Pool, Fun) ->
    try
        shigoto_db:transaction(Pool, fun() ->
            case Fun() of
                {error, Reason} -> throw({?MODULE, refused, shigoto_db:reduced(Reason)});
                Answer -> Answer
            end
        end)
    catch
        throw:{?MODULE, refused, Reason} -> {error, Reason}
    end.

keyed(Job, none, _Opts) -> {Job, none, []};
keyed(Job, Unique, Opts) -> {Job, Unique, unique_keys(Job, Opts, Unique)}.

%% Runs of jobs that are not unique keep their single statement; ids follow
%% the order given.
placed_in_order(_Pool, [], _Opts) ->
    [];
placed_in_order(Pool, [{_, none, []} | _] = Keyed, Opts) ->
    {Run, Rest} = lists:splitwith(fun({_Job, Unique, _Keys}) -> Unique =:= none end, Keyed),
    case insert_all_validated(Pool, [Job || {Job, none, []} <- Run], Opts) of
        {ok, Rows} -> [{inserted, Row} || Row <- Rows] ++ placed_in_order(Pool, Rest, Opts);
        {error, _} = Refused -> throw({?MODULE, insert_all_failed, Refused})
    end;
placed_in_order(Pool, [{Job, Unique, Keys} | Rest], Opts) ->
    case placed_unique(Pool, Job, Opts, Unique, Keys) of
        {ok, {conflict, Existing}} -> [{conflict, Existing} | placed_in_order(Pool, Rest, Opts)];
        {ok, Row} -> [{inserted, Row} | placed_in_order(Pool, Rest, Opts)];
        {error, _} = Refused -> throw({?MODULE, insert_all_failed, Refused})
    end.

%% One read for the dependencies of every job, then each job is checked as a
%% single insert would check it. No job has dependencies: no read.
with_dependencies(Pool, Jobs) ->
    case lists:usort(lists:append([maps:get(depends_on, Job, []) || Job <- Jobs])) of
        [] ->
            {ok, Jobs};
        DepIds ->
            case dependencies(Pool, [Id || Id <- DepIds, is_integer(Id)]) of
                {ok, Found} -> with_dependencies(Jobs, Found, []);
                {error, _} = Err -> Err
            end
    end.

with_dependencies([], _Found, Validated) ->
    {ok, lists:reverse(Validated)};
with_dependencies([Job | Jobs], Found, Validated) ->
    DependsOn = maps:get(depends_on, Job, []),
    case resolved_dependencies(DependsOn, Found, effective_policy(Job)) of
        {ok, Pending, Results} ->
            with_dependencies(Jobs, Found, [
                (waiting_for(Job, DependsOn))#{depends_on => Pending, deps_results => Results}
                | Validated
            ]);
        {error, _} = Refused ->
            Refused
    end.

%% The jobs a job is inserted to wait for are the ones whose results it may be
%% handed (`shigoto_job:opened/1`). With a key they are named in its meta,
%% which is sealed for its worker, so that a result copied into the row of a
%% job that never waited for it is not opened there.
-spec waiting_for(map(), [term()]) -> map().
waiting_for(Job, []) ->
    Job;
waiting_for(Job, DependsOn) ->
    case {shigoto_crypto:is_enabled(), maps:get(meta, Job, #{})} of
        {true, Meta} when is_map(Meta) ->
            Job#{meta => (maps:remove('_shigoto_deps', Meta))#{~"_shigoto_deps" => DependsOn}};
        _NoKeyOrNoObject ->
            Job
    end.

-define(LOCKS_PER_STATEMENT, 64).

-define(BULK_COLUMNS, [
    queue,
    worker,
    args,
    priority,
    max_attempts,
    scheduled_at,
    tags,
    batch_id,
    partition_key,
    depends_on
]).

insert_all_validated(Pool, Jobs, Opts) ->
    %% A column outside the base set is only named when a job sets it, so a
    %% plain insert is the same statement as before the column existed.
    Optional = [
        Column
     || {Column, true} <- [
            {meta, [meta || #{meta := _} <- Jobs] =/= []},
            {deps_results, [Job || Job <- Jobs, maps:get(deps_results, Job, #{}) =/= #{}] =/= []},
            {on_dependency_failure, lists:any(fun(Job) -> policy_column(Job) =/= null end, Jobs)}
        ]
    ],
    Columns = ?BULK_COLUMNS ++ Optional,
    Width = length(Columns),
    Values = [
        bulk_placeholders(Index * Width, Columns)
     || Index <- lists:seq(0, length(Jobs) - 1)
    ],
    Insert = [
        ~"INSERT INTO shigoto_jobs (",
        joined(~", ", [atom_to_binary(Column) || Column <- Columns]),
        ~") VALUES ",
        joined(~", ", Values),
        ~" RETURNING *"
    ],
    Params = lists:append([[bulk_value(Column, Job, Opts) || Column <- Columns] || Job <- Jobs]),
    Batched = [Batch || #{batch := Batch} <- Jobs, Batch =/= null] =/= [],
    case query(Pool, counting_its_batches(Insert, Batched), Params) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-spec bulk_placeholders(non_neg_integer(), [atom()]) -> iodata().
bulk_placeholders(Offset, Columns) ->
    Placeholders = [
        bulk_placeholder(Column, Offset + N)
     || {N, Column} <- lists:enumerate(Columns)
    ],
    [~"(", joined(~", ", Placeholders), ~")"].

bulk_placeholder(deps_results, N) -> [~"$", integer_to_binary(N), ~"::jsonb"];
bulk_placeholder(_Column, N) -> [~"$", integer_to_binary(N)].

bulk_value(queue, Job, Opts) ->
    maps:get(queue, Job, maps:get(queue, Opts, ~"default"));
bulk_value(worker, Job, _Opts) ->
    atom_to_binary(maps:get(worker, Job));
bulk_value(args, Job, _Opts) ->
    sealed(args, Job, encode_json(maps:get(args, Job, #{})));
bulk_value(meta, Job, _Opts) ->
    sealed(meta, Job, encode_json(maps:get(meta, Job, #{})));
bulk_value(priority, Job, _Opts) ->
    maps:get(priority, Job, 0);
bulk_value(max_attempts, Job, _Opts) ->
    maps:get(max_attempts, Job, 3);
bulk_value(scheduled_at, Job, _Opts) ->
    maps:get(scheduled_at, Job, now_timestamptz());
bulk_value(tags, Job, _Opts) ->
    encode_pg_array(resolve_tags(Job));
bulk_value(batch_id, Job, _Opts) ->
    maps:get(batch, Job, null);
bulk_value(partition_key, Job, _Opts) ->
    maps:get(partition_key, Job, null);
bulk_value(depends_on, Job, _Opts) ->
    maps:get(depends_on, Job, []);
bulk_value(deps_results, Job, _Opts) ->
    encode_json(maps:get(deps_results, Job, #{}));
bulk_value(on_dependency_failure, Job, _Opts) ->
    policy_column(Job).

%% The stored form of a job's args or meta: encrypted for its worker when a key
%% is configured, as it is otherwise.
sealed(Column, #{worker := Worker}, Json) when is_atom(Worker) ->
    shigoto_crypto:seal(Json, {Column, atom_to_binary(Worker)}).

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
their `args` and `meta` are still ciphertext. They are decrypted for the run
of the job, once the worker the row names has been checked, and for reading by
`get_job/2`.

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

The job's batch counts it in the same statement, so a completed job is never
missing from its batch's count.

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
        ), counted AS (
          UPDATE shigoto_batches b SET completed_jobs = b.completed_jobs + 1
          FROM done WHERE b.id = done.batch_id
        )
        SELECT batch_id FROM done
        """,
    case query(Pool, SQL, [JobId, ResultJson, Attempt]) of
        #{rows := [#{batch_id := null}]} ->
            ok;
        #{rows := [#{batch_id := BatchId}]} when is_integer(BatchId) ->
            %% The job is completed and counted whatever becomes of the
            %% callback: a batch that could not be settled here is settled by
            %% the next sweep.
            _ = shigoto_batch:settle(Pool, BatchId),
            ok;
        #{rows := []} ->
            {error, lost};
        {error, _} = Err ->
            Err
    end.

-doc """
Record the failure of a claimed job, with a structured error and the backoff
before its next attempt. At `max_attempts` the job is discarded instead.

The error is written without the job's args (see the Security guide), and the
job keeps its 50 newest errors.

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
            ok = shigoto_callbacks:discarded(Updated),
            ok = batches_settled(Pool, [Updated]),
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

%% The rows a discarding or cancelling statement answered: its own jobs and
%% the dependents that went with them. The statement counted them in their
%% batches; a batch that has no job left is settled here.
-spec ended(atom(), [map()]) -> ok.
ended(Pool, Rows) ->
    {Own, Cascaded} = moved(Rows),
    ok = batches_settled(Pool, Own),
    dependents_followed(Pool, Cascaded).

%% The batches of the jobs a statement just discarded or cancelled.
-spec batches_settled(atom(), [map()]) -> ok.
batches_settled(Pool, Rows) ->
    Batches = [
        BatchId
     || #{batch_id := BatchId, state := State} <- Rows,
        is_integer(BatchId),
        State =:= ~"discarded" orelse State =:= ~"cancelled"
    ],
    _ = [
        shigoto_batch:settle(Pool, BatchId)
     || BatchId <- lists:usort(Batches), is_integer(BatchId)
    ],
    ok.

-doc """
Cancel a job that has not finished. Resolves dependencies so dependent jobs
aren't stuck, and counts the job as discarded in its batch, so the batch can
still finish.
""".
-spec cancel_job(atom(), integer()) -> ok | {error, term()}.
cancel_job(Pool, JobId) ->
    case cancelled_job(Pool, JobId) of
        {ok, _Outcome} -> ok;
        {error, _} = Err -> Err
    end.

-doc false.
%% `cancel_job/2`, answering what it did: `{cancelled, Job}` with the row as it is
%% now, or `unchanged` when there is no such job or it had already finished.
-spec cancelled_job(atom(), integer()) -> {ok, {cancelled, map()} | unchanged} | {error, term()}.
cancelled_job(Pool, JobId) ->
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
        #{rows := Rows} ->
            ok = ended(Pool, Rows),
            case moved(Rows) of
                {[Job], _Cascaded} -> {ok, {cancelled, Job}};
                {[], _Cascaded} -> {ok, unchanged}
            end;
        {error, _} = Err ->
            Err
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
    Matching = joined(~" AND ", [~"state IN ('available', 'retryable')" | WhereClauses]),
    SQL = with_dependents(
        [
            ~"WITH RECURSIVE done AS (UPDATE shigoto_jobs SET state = 'cancelled', cancelled_at = now() WHERE ",
            Matching,
            ~" RETURNING *)"
        ],
        <<"$", (integer_to_binary(Next))/binary>>,
        #{own => ids, count_batches => true}
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

-doc false.
%% Snooze a claimed job this node could not run, through no fault of the job:
%% a resilience gate did not answer, or the worker is not known here. As for
%% `snooze_job/3` the attempt is given back. `Reason` goes into `errors` as a
%% `shigoto_error:put_back/3` entry, which is what the executor counts to stop
%% putting the job back.
-spec put_back_job(atom(), map(), pos_integer(), term()) -> ok | {error, lost | term()}.
put_back_job(Pool, Job, Seconds, Reason) ->
    {JobId, Attempt} = fence(Job),
    Entry = encode_json(shigoto_error:put_back(Job, Reason, Seconds)),
    SQL = iolist_to_binary([
        ~"""
        UPDATE shigoto_jobs SET state = 'available',
          scheduled_at = now() + make_interval(secs => $2),
          max_attempts = max_attempts + 1,
          errors =
        """,
        ~" ",
        shigoto_error:appended(~"errors", ~"$4::jsonb"),
        ~"""

        WHERE id = $1 AND state = 'executing' AND ($3::integer IS NULL OR attempt = $3)
        RETURNING id
        """
    ]),
    case query(Pool, SQL, [JobId, Seconds, Attempt, Entry]) of
        #{rows := [_]} -> ok;
        #{rows := []} -> {error, lost};
        {error, _} = Err -> Err
    end.

-doc false.
%% Give a claimed job back without anything having come of the run: the node is
%% stopping and the run was stopped with it. The job is `available` again at
%% once and keeps its place, and `max_attempts` goes up by one, as for a snooze,
%% so the interrupted run does not use up an attempt.
%%
%% Like `complete_job/3`, the write only applies while the claim still holds, and
%% answers `{error, lost}` otherwise.
-spec release_job(atom(), claim()) -> ok | {error, lost | term()}.
release_job(Pool, Claim) ->
    {JobId, Attempt} = fence(Claim),
    SQL =
        ~"""
        UPDATE shigoto_jobs SET state = 'available',
          heartbeat_at = NULL,
          max_attempts = max_attempts + 1
        WHERE id = $1 AND state = 'executing' AND ($2::integer IS NULL OR attempt = $2)
        RETURNING id
        """,
    case query(Pool, SQL, [JobId, Attempt]) of
        #{rows := [_]} -> ok;
        #{rows := []} -> {error, lost};
        {error, _} = Err -> Err
    end.

-doc """
Retry a discarded or cancelled job by resetting to available.

A job in a batch is taken out of the batch's discarded count, and is counted
again when it ends. A batch that has already run its callback does not run it
a second time.

A job that ended while it waited on other jobs still waits on them: retried, it
runs once they have completed, and follows its `on_dependency_failure` for one
that is still discarded or cancelled.
""".
-spec retry_job(atom(), integer()) -> ok | {error, term()}.
retry_job(Pool, JobId) ->
    case query(Pool, retrying(~"id = $1 AND state IN ('discarded', 'cancelled')"), [JobId]) of
        #{rows := [_]} -> ok;
        {error, _} = Err -> Err
    end.

%% A discarded or cancelled job was counted in its batch as discarded. Back in
%% the queue it is no longer that, and it will be counted again when it ends.
%% Left counted, the batch would be complete one job early.
-spec retrying(iodata()) -> binary().
retrying(Where) ->
    iolist_to_binary([
        ~"WITH retried AS (UPDATE shigoto_jobs SET state = 'available', scheduled_at = now() WHERE ",
        Where,
        ~"""
         RETURNING batch_id
        ), uncounted AS (
          UPDATE shigoto_batches b SET discarded_jobs = GREATEST(b.discarded_jobs - batched.jobs, 0)
          FROM (
            SELECT batch_id, count(*) AS jobs FROM retried
            WHERE batch_id IS NOT NULL GROUP BY batch_id
          ) batched
          WHERE b.id = batched.batch_id
        )
        SELECT count(*) AS retried FROM retried
        """
    ]).

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
                    joined(~" AND ", WhereClauses)
                ])
        end,
    case query(Pool, retrying(WhereSQL), Params) of
        #{rows := [#{retried := Count}]} when is_integer(Count) -> {ok, Count};
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
    ok = shigoto_callbacks:discarded(Job),
    ok = batches_settled(Pool, [Job]),
    _ = shigoto_telemetry:job_discarded(Job),
    ok;
rescued(_Pool, Job) ->
    _ = shigoto_telemetry:job_rescued(Job),
    ok.

-doc false.
%% Record a heartbeat for the claims this node is running, each `{JobId, Attempt}`.
%%
%% Answers the claims that still hold. One that is missing was rescued and claimed
%% again, or cancelled: its row is no longer `executing` under that attempt, and it
%% gets no heartbeat.
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

-doc false.
%% Release the jobs that wait on a job that has already ended.
%%
%% A finished job releases its dependents in the statement that finishes it, and
%% that statement only sees the dependents committed before it began. A job
%% inserted with `depends_on` just as its dependency finishes can be missed: the
%% insert saw the dependency still running, and the dependency's last statement
%% did not see the insert. This finds what such a race left behind, and jobs
%% waiting on a job that no longer exists, and does for them what the dependency
%% would have done: a completed (or missing) dependency is removed and its result
%% handed over; a discarded or cancelled one is followed by each waiting job's
%% `on_dependency_failure`. Each node runs it every `rescue_interval`.
%%
%% Answers how many dependencies it resolved.
-spec release_stuck_dependents(atom()) -> {ok, non_neg_integer()} | {error, term()}.
release_stuck_dependents(Pool) ->
    SQL =
        ~"""
        SELECT DISTINCT dep.id AS id, p.state AS state
        FROM shigoto_jobs d
        CROSS JOIN LATERAL unnest(d.depends_on) AS dep(id)
        LEFT JOIN shigoto_jobs p ON p.id = dep.id
        WHERE d.depends_on <> '{}' AND d.state IN ('available', 'retryable')
        AND (p.id IS NULL OR p.state IN ('completed', 'discarded', 'cancelled'))
        LIMIT 500
        """,
    case query(Pool, SQL, []) of
        #{rows := []} ->
            {ok, 0};
        #{rows := Rows} ->
            Failed = [
                Id
             || #{id := Id, state := State} <- Rows,
                State =:= ~"discarded" orelse State =:= ~"cancelled"
            ],
            Finished = [Id || #{id := Id} <- Rows, not lists:member(Id, Failed)],
            _ = [resolve_dependencies(Pool, Id) || Id <- Finished],
            case failed_dependencies_followed(Pool, Failed) of
                ok -> {ok, length(Rows)};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

failed_dependencies_followed(_Pool, []) ->
    ok;
failed_dependencies_followed(Pool, Failed) ->
    SQL = with_dependents(
        ~"""
        WITH RECURSIVE done AS (
          SELECT * FROM shigoto_jobs
          WHERE id = ANY($1::bigint[]) AND state IN ('discarded', 'cancelled')
        )
        """,
        ~"$2",
        #{own => ids, count_batches => false}
    ),
    case query(Pool, SQL, [Failed, default_policy()]) of
        #{rows := Rows} ->
            {_Own, Cascaded} = moved(Rows),
            dependents_followed(Pool, Cascaded);
        {error, _} = Err ->
            Err
    end.

-doc "Update job progress (0-100).".
-spec update_progress(atom(), integer(), 0..100) -> ok | {error, term()}.
update_progress(Pool, JobId, Progress) ->
    SQL = ~"UPDATE shigoto_jobs SET progress = $2 WHERE id = $1",
    case query(Pool, SQL, [JobId, Progress]) of
        #{} -> ok;
        {error, _} = Err -> Err
    end.

-doc """
Get a job by ID, with its encrypted columns decrypted for reading. A column
that does not open is replaced by the reason.
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
            _ -> iolist_to_binary(joined(~" AND ", AllClauses))
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

-doc """
Move the completed, discarded and cancelled jobs older than `Days` days to the
archive table. One statement deletes them and inserts what it deleted, so a
job is never deleted without having been copied. Answers how many it moved.
""".
-spec archive_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
archive_jobs(Pool, Days) ->
    SQL =
        ~"""
        WITH moved AS (
          DELETE FROM shigoto_jobs
          WHERE state IN ('completed', 'discarded', 'cancelled')
          AND inserted_at < now() - make_interval(days => $1)
          RETURNING *
        ), archived AS (
          INSERT INTO shigoto_jobs_archive
          (id, queue, worker, args, state, priority, attempt, max_attempts,
           scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,
           inserted_at, errors, meta, unique_key, tags, progress, batch_id,
           heartbeat_at, partition_key, depends_on, result, deps_results)
          SELECT id, queue, worker, args, state, priority, attempt, max_attempts,
           scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,
           inserted_at, errors, meta, unique_key, tags, progress, batch_id,
           heartbeat_at, partition_key, depends_on, result, deps_results
          FROM moved
          ON CONFLICT (id) DO NOTHING
        )
        SELECT count(*) AS moved FROM moved
        """,
    case query(Pool, SQL, [Days]) of
        #{rows := [#{moved := Count}]} when is_integer(Count) -> {ok, Count};
        {error, _} = Err -> Err
    end.

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
        #{} -> ok;
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
key is this installation's own when an `instance` is configured (see the
Security guide).
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
%%
%% `failed` picks the waiting jobs from the statement's snapshot. `cascaded`
%% names their state again because another statement may have ended one of
%% them meanwhile: an UPDATE that waited for a row lock re-checks only its own
%% WHERE clause against the new row.
%%
%% Only a job that is released to run stops waiting on the failed job. One
%% that is cancelled or discarded for it, or was ended some other way while it
%% waited, keeps the id in `depends_on`: retried, it waits on that job again,
%% and the sweep applies its policy again if the job is still failed.
%%
%% In the same statement each batch counts its jobs that ended: the `done`
%% rows now discarded or cancelled (`count_batches`, off for a statement whose
%% `done` rows had ended before it ran) and every cascaded one. `own => ids`
%% answers the `done` rows with only `id`, `state` and `batch_id` set, for a
%% statement that may move any number of jobs.
-spec with_dependents(iodata(), binary()) -> binary().
with_dependents(Done, DefaultPolicy) ->
    with_dependents(Done, DefaultPolicy, #{own => rows, count_batches => true}).

-spec with_dependents(iodata(), binary(), #{own := rows | ids, count_batches := boolean()}) ->
    binary().
with_dependents(Done, DefaultPolicy, #{own := Own, count_batches := CountOwn}) ->
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
            errors = $errors
          FROM failed f WHERE d.id = f.id AND f.policy IS NOT NULL
          AND d.state IN ('available', 'retryable')
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
          AND d.state IN ('available', 'retryable')
          AND d.id NOT IN (SELECT id FROM failed)
        ), batch_counts AS (
          UPDATE shigoto_batches b SET discarded_jobs = b.discarded_jobs + ended.jobs
          FROM (
            SELECT batch_id, count(*) AS jobs FROM (
              SELECT batch_id FROM done WHERE $count_own AND state IN ('discarded', 'cancelled')
              UNION ALL
              SELECT batch_id FROM cascaded
            ) each_ended
            WHERE batch_id IS NOT NULL GROUP BY batch_id
          ) ended
          WHERE b.id = ended.batch_id
        )
        SELECT false AS cascaded, $own FROM done
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
    Replaced = [
        {~"$default", DefaultPolicy},
        {~"$errors", Errors},
        {~"$count_own", atom_to_binary(CountOwn)},
        {~"$own", own_columns(Own)}
    ],
    iolist_to_binary([Done, replaced(Tail, Replaced)]).

replaced(SQL, []) ->
    SQL;
replaced(SQL, [{Name, Value} | Rest]) ->
    replaced(binary:replace(SQL, Name, Value, [global]), Rest).

own_columns(rows) ->
    ~"*";
own_columns(ids) ->
    ~"""
    (jsonb_populate_record(
      NULL::shigoto_jobs,
      jsonb_build_object('id', id, 'state', state, 'batch_id', batch_id)
    )).*
    """.

%% `lists:join/2` for the pieces of a statement.
-spec joined(binary(), [iodata()]) -> [iodata()].
joined(_Separator, []) -> [];
joined(_Separator, [Part]) -> [Part];
joined(Separator, [Part | Parts]) -> [Part, Separator | joined(Separator, Parts)].

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
    batches_settled(Pool, Cascaded).

followed(#{state := ~"discarded"} = Job) ->
    ok = shigoto_callbacks:discarded(Job),
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

%% What an insert refuses without asking the database.
-spec insertable(map(), map()) -> ok | {error, term()}.
insertable(JobParams, Opts) ->
    case stated_policy(JobParams) of
        {error, _} = Invalid -> Invalid;
        {ok, _Policy} -> outside_a_batch_if_fanout(JobParams, Opts)
    end.

%% No node ends a fanout job, so a batch would wait for it for ever.
outside_a_batch_if_fanout(JobParams, Opts) ->
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
    case maps:get(batch, JobParams, null) =/= null andalso is_fanout(Queue) of
        true -> {error, {fanout_job_in_batch, Queue}};
        false -> ok
    end.

is_fanout(Queue) ->
    lists:keymember(Queue, 1, shigoto_config:fanout_queues()).

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
    case dependencies(Pool, DepIds) of
        {ok, Found} -> resolved_dependencies(DepIds, Found, Policy);
        {error, _} = Err -> Err
    end.

-spec dependencies(atom(), [integer()]) -> {ok, #{integer() => map()}} | {error, term()}.
dependencies(Pool, DepIds) ->
    SQL = ~"SELECT id, state, result FROM shigoto_jobs WHERE id = ANY($1::bigint[])",
    case query(Pool, SQL, [DepIds]) of
        #{rows := Rows} -> {ok, #{Id => Row || #{id := Id} = Row <- Rows}};
        {error, _} = Err -> Err
    end.

%% There is no cycle to look for: a job has no id until it is inserted, so
%% nothing can depend on it yet and an insert cannot close a circle.
-spec resolved_dependencies([integer()], #{integer() => map()}, run | cancel | discard) ->
    {ok, Pending :: [integer()], Results :: #{binary() => term()}} | {error, term()}.
resolved_dependencies([], _Found, _Policy) ->
    {ok, [], #{}};
resolved_dependencies(DepIds, Found, Policy) ->
    case [Id || Id <- DepIds, not is_map_key(Id, Found)] of
        [] -> waited_for(DepIds, Found, Policy);
        Missing -> {error, {missing_dependencies, Missing}}
    end.

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
    worker_defaults([max_attempts, queue, priority], Worker, JobParams).

%% What the job does not set itself, from the worker's callback of that name.
-spec worker_defaults([atom()], module(), map()) -> map().
worker_defaults([], _Worker, JobParams) ->
    JobParams;
worker_defaults([Key | Keys], Worker, JobParams) ->
    case is_map_key(Key, JobParams) orelse not erlang:function_exported(Worker, Key, 0) of
        true -> worker_defaults(Keys, Worker, JobParams);
        false -> worker_defaults(Keys, Worker, JobParams#{Key => Worker:Key()})
    end.

resolve_unique(JobParams, Opts) ->
    case Opts of
        #{unique := UniqueOpts} when is_map(UniqueOpts) ->
            maps:merge(?DEFAULT_UNIQUE, UniqueOpts);
        #{unique := false} ->
            none;
        _ ->
            Worker = maps:get(worker, JobParams),
            case erlang:function_exported(Worker, unique, 0) of
                true -> maps:merge(?DEFAULT_UNIQUE, Worker:unique());
                false -> none
            end
    end.

insert_unique(Pool, JobParams, Opts, UniqueOpts) ->
    UniqueKeys = unique_keys(JobParams, Opts, UniqueOpts),
    undone_when_refused(Pool, fun() ->
        case unique_locks(Pool, [erlang:phash2(Key) || Key <- UniqueKeys]) of
            ok -> placed_unique(Pool, JobParams, Opts, UniqueOpts, UniqueKeys);
            {error, _} = Refused -> Refused
        end
    end).

%% One key per configured encryption key, the current one first. The job is
%% stored under the current one and looked for under all of them, so a job
%% inserted before a key rotation still counts as the duplicate it is.
-spec unique_keys(map(), map(), map()) -> [binary(), ...].
unique_keys(JobParams, Opts, UniqueOpts) ->
    Worker = atom_to_binary(maps:get(worker, JobParams), utf8),
    Args = maps:get(args, JobParams, #{}),
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
    build_unique_keys(UniqueOpts, Worker, Args, Queue).

%% Taken in ascending order, a statement's worth at a time, so two calls that
%% want the same locks never each hold one the other waits for.
-spec unique_locks(atom(), [integer()]) -> ok | {error, term()}.
unique_locks(Pool, LockKeys) ->
    Deadline = erlang:monotonic_time(millisecond) + shigoto_config:advisory_lock_timeout(),
    unique_locks(Pool, ordsets:from_list(LockKeys), Deadline).

-spec unique_locks(atom(), [integer()], integer()) -> ok | {error, term()}.
unique_locks(_Pool, [], _Deadline) ->
    ok;
unique_locks(Pool, [Key | Keys], Deadline) ->
    {Now, Later} = statement_of(Keys, ?LOCKS_PER_STATEMENT - 1, [Key]),
    case shigoto_lock:acquire_xact(Pool, Now, time_left(Deadline)) of
        ok -> unique_locks(Pool, Later, Deadline);
        {error, lock_timeout} -> {error, {lock_timeout, unique}};
        {error, Reason} -> {error, shigoto_db:reduced(Reason)}
    end.

%% The keys one statement takes, and the keys after them.
-spec statement_of([integer()], non_neg_integer(), [integer(), ...]) ->
    {[integer(), ...], [integer()]}.
statement_of([Key | Later], Room, Now) when Room > 0 ->
    statement_of(Later, Room - 1, [Key | Now]);
statement_of(Later, _Room, Now) ->
    {Now, Later}.

-spec time_left(integer()) -> non_neg_integer().
time_left(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> Left;
        _Over -> 0
    end.

%% With the job's unique locks held.
placed_unique(Pool, JobParams, Opts, UniqueOpts, [UniqueKey | _] = UniqueKeys) ->
    case find_existing_job(Pool, UniqueOpts, UniqueKeys) of
        {ok, Existing} ->
            case maybe_replace(Pool, Existing, JobParams, UniqueOpts) of
                gone -> do_insert(Pool, JobParams, Opts, UniqueKey);
                Answer -> Answer
            end;
        not_found ->
            do_insert(Pool, JobParams, Opts, UniqueKey);
        {error, _} = Err ->
            Err
    end.

build_unique_keys(#{keys := Keys}, Worker, Args, Queue) ->
    shigoto_crypto:unique_keys(unique_material(Keys, Worker, encode_json(Args), Queue)).

-spec unique_material([worker | args | queue], binary(), binary(), binary()) -> binary().
unique_material(Keys, Worker, ArgsJson, Queue) ->
    Parts = [unique_part(Key, Worker, ArgsJson, Queue) || Key <- lists:sort(Keys)],
    iolist_to_binary(joined(~":", Parts)).

-spec unique_part(term(), binary(), binary(), binary()) -> binary().
unique_part(worker, Worker, _ArgsJson, _Queue) -> Worker;
unique_part(args, _Worker, ArgsJson, _Queue) -> ArgsJson;
unique_part(queue, _Worker, _ArgsJson, Queue) -> Queue.

-doc false.
%% Everything a job's `unique_key` could have been made from: one material per
%% choice of unique `keys`. `ArgsJson` is the job's args as they were encoded at
%% insert, or `undefined` when they cannot be read, which leaves out the choices
%% that include them. `shigoto:reencrypt/0,1` uses it to move a stored key to the
%% current encryption key.
-spec unique_materials(binary(), binary() | undefined, binary()) -> [binary()].
unique_materials(Worker, ArgsJson, Queue) ->
    [
        unique_material(Keys, Worker, args_part(ArgsJson), Queue)
     || Keys <- [
            [worker, args],
            [worker, args, queue],
            [args],
            [args, queue],
            [worker],
            [queue],
            [worker, queue]
        ],
        ArgsJson =/= undefined orelse not lists:member(args, Keys)
    ].

args_part(undefined) -> <<>>;
args_part(ArgsJson) -> ArgsJson.

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

-spec states_in_clause([atom()]) -> iodata().
states_in_clause(States) ->
    Quoted = [<<"'", (atom_to_binary(S))/binary, "'">> || S <- States],
    joined(~", ", Quoted).

%% The existing job was found without a lock on its row. It may have left the
%% unique states since (claimed and finished, cancelled), and a write to it
%% then would be lost: the caller would be told its job is waiting when the
%% job has already run without the new values. `gone` says so, and the new job
%% is inserted instead.
-spec maybe_replace(atom(), map(), map(), map()) ->
    {ok, {conflict, map()}} | gone | {error, term()}.
maybe_replace(Pool, Existing, _JobParams, #{replace := [], debounce := Seconds} = UniqueOpts) when
    is_integer(Seconds), Seconds > 0
->
    rewritten(
        Pool, Existing, [~"scheduled_at = now() + make_interval(secs => $2)"], [Seconds], UniqueOpts
    );
maybe_replace(_Pool, Existing, _JobParams, #{replace := []}) ->
    {ok, {conflict, Existing}};
maybe_replace(Pool, Existing, JobParams, #{replace := Fields, debounce := Debounce} = UniqueOpts) ->
    Replaced = [replace_field_value(Field, JobParams, Existing) || Field <- Fields],
    Sets0 = assignments(Replaced, 2),
    Params0 = [Value || {_Column, Value} <- Replaced],
    {Sets, Params} =
        case is_integer(Debounce) andalso Debounce > 0 of
            true ->
                Next = integer_to_binary(length(Replaced) + 2),
                Reset = <<"scheduled_at = now() + make_interval(secs => $", Next/binary, ")">>,
                {Sets0 ++ [Reset], Params0 ++ [Debounce]};
            false ->
                {Sets0, Params0}
        end,
    rewritten(Pool, Existing, Sets, Params, UniqueOpts).

-spec rewritten(atom(), map(), [binary()], [term()], map()) ->
    {ok, {conflict, map()}} | gone | {error, term()}.
rewritten(Pool, #{id := Id}, Sets, Params, #{states := States}) ->
    SQL = iolist_to_binary([
        ~"UPDATE shigoto_jobs SET ",
        joined(~", ", Sets),
        ~" WHERE id = $1 AND state IN (",
        states_in_clause(States),
        ~") RETURNING *"
    ]),
    case query(Pool, SQL, [Id | Params]) of
        #{rows := [Updated]} -> {ok, {conflict, Updated}};
        #{rows := []} -> gone;
        {error, _} = Err -> Err
    end.

%% The new args go into the existing row, so they are encrypted for the worker
%% that row names, which need not be the worker of the job that replaces them.
-spec assignments([{binary(), term()}], pos_integer()) -> [binary()].
assignments([], _Index) ->
    [];
assignments([{Column, _Value} | Rest], Index) ->
    [<<Column/binary, " = $", (integer_to_binary(Index))/binary>> | assignments(Rest, Index + 1)].

-spec replace_field_value(atom(), map(), map()) -> {binary(), term()}.
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

-spec build_filter_clauses(map(), pos_integer()) -> {[binary()], [term()], pos_integer()}.
build_filter_clauses(Filters, StartIdx) ->
    filter_clauses(maps:to_list(Filters), {[], [], StartIdx}).

-spec filter_clauses([{term(), term()}], {[binary()], [term()], pos_integer()}) ->
    {[binary()], [term()], pos_integer()}.
filter_clauses([], Built) ->
    Built;
filter_clauses([{Key, Value} | Filters], {Clauses, Params, Idx}) ->
    {Clause, NewParams, NewIdx} = filter_clause(Key, Value, Idx),
    filter_clauses(Filters, {[Clause | Clauses], Params ++ NewParams, NewIdx}).

-spec filter_clause(term(), term(), pos_integer()) -> {binary(), [term()], pos_integer()}.
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
