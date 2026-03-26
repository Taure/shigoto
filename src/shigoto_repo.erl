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
    fail_job/4,
    discard_job/2,
    cancel_job/2,
    cancel_by/2,
    snooze_job/3,
    retry_job/2,
    retry_by/2,
    rescue_stale_jobs/2,
    prune_jobs/2,
    upsert_cron_entry/2,
    get_due_cron_entries/1,
    update_progress/3,
    get_job/2,
    resolve_dependencies/2,
    archive_jobs/2
]).

-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

-define(DEFAULT_UNIQUE, #{
    keys => [worker, args],
    states => [available, executing, retryable],
    period => infinity,
    replace => [],
    debounce => undefined
}).

-doc "Insert a new job. Respects worker defaults and unique constraints. Validates dependency cycles.".
-spec insert_job(atom(), map(), map()) ->
    {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert_job(Pool, JobParams0, Opts) ->
    JobParams = apply_worker_defaults(JobParams0),
    DependsOn = maps:get(depends_on, JobParams, []),
    case validate_dependencies(Pool, DependsOn) of
        ok ->
            case resolve_unique(JobParams, Opts) of
                none ->
                    do_insert(Pool, JobParams, Opts, null);
                UniqueOpts ->
                    insert_unique(Pool, JobParams, Opts, UniqueOpts)
            end;
        {error, _} = Err ->
            Err
    end.

-doc "Bulk insert multiple jobs in a single SQL statement. Returns inserted jobs.".
-spec insert_all(atom(), [map()], map()) -> {ok, [map()]} | {error, term()}.
insert_all(_Pool, [], _Opts) ->
    {ok, []};
insert_all(Pool, JobParamsList, Opts) ->
    Jobs = [apply_worker_defaults(J) || J <- JobParamsList],
    ParamsPerJob = 10,
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
                    ],
            {[Clause | Clauses], NewParams, Idx + ParamsPerJob}
        end,
        {[], [], 1},
        Jobs
    ),
    ValuesSQL = lists:join(~", ", ValueClauses),
    SQL = iolist_to_binary([
        <<
            "INSERT INTO shigoto_jobs "
            "(queue, worker, args, priority, max_attempts, scheduled_at, tags, batch_id, partition_key, depends_on) VALUES "
        >>,
        ValuesSQL,
        ~" RETURNING *"
    ]),
    case query(Pool, SQL, AllParams) of
        #{rows := Rows} ->
            BatchIds = [maps:get(batch, J, null) || J <- Jobs],
            update_batch_counts(Pool, BatchIds),
            {ok, Rows};
        {error, _} = Err ->
            Err
    end.

-doc "Claim up to N available jobs from a queue using FOR UPDATE SKIP LOCKED.".
-spec claim_jobs(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs(Pool, Queue, Limit) ->
    %% Jobs with unresolved dependencies (depends_on != '{}') are skipped.
    %% Fair partitioned claiming is handled by interleaving partition keys
    %% via a subquery with ROW_NUMBER, wrapped in an outer FOR UPDATE SKIP LOCKED.
    SQL =
        <<
            "UPDATE shigoto_jobs SET\n"
            "state = 'executing',\n"
            "attempted_at = now(),\n"
            "attempt = attempt + 1\n"
            "WHERE id IN (\n"
            "  SELECT id FROM shigoto_jobs\n"
            "  WHERE queue = $1\n"
            "  AND state = 'available'\n"
            "  AND scheduled_at <= now()\n"
            "  AND depends_on = '{}'\n"
            "  ORDER BY priority DESC, scheduled_at ASC\n"
            "  LIMIT $2\n"
            "  FOR UPDATE SKIP LOCKED\n"
            ") RETURNING *"
        >>,
    case query(Pool, SQL, [Queue, Limit]) of
        #{rows := Rows} ->
            DecryptedRows = [decrypt_job_args(R) || R <- Rows],
            {ok, DecryptedRows};
        {error, _} = Err ->
            Err
    end.

-doc "Claim jobs with fair partition interleaving. One job per partition first, then fill.".
-spec claim_jobs_fair(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs_fair(Pool, Queue, Limit) ->
    %% Two-phase: first get fair-ordered IDs via window function, then lock and update.
    %% The CTE selects IDs in fair order, outer query locks them.
    SQL =
        <<
            "WITH ranked AS (\n"
            "  SELECT id,\n"
            "    ROW_NUMBER() OVER (\n"
            "      PARTITION BY COALESCE(partition_key, 'null_' || id::text)\n"
            "      ORDER BY priority DESC, scheduled_at ASC\n"
            "    ) as rn\n"
            "  FROM shigoto_jobs\n"
            "  WHERE queue = $1 AND state = 'available' AND scheduled_at <= now()\n"
            "  AND depends_on = '{}'\n"
            "),\n"
            "to_claim AS (\n"
            "  SELECT id FROM ranked ORDER BY rn, id LIMIT $2\n"
            ")\n"
            "UPDATE shigoto_jobs SET\n"
            "state = 'executing', attempted_at = now(), attempt = attempt + 1\n"
            "WHERE id IN (SELECT id FROM to_claim)\n"
            "AND state = 'available'\n"
            "RETURNING *"
        >>,
    case query(Pool, SQL, [Queue, Limit]) of
        #{rows := Rows} ->
            DecryptedRows = [decrypt_job_args(R) || R <- Rows],
            {ok, DecryptedRows};
        {error, _} = Err ->
            Err
    end.

-doc "Mark a job as completed.".
-spec complete_job(atom(), integer()) -> ok | {error, term()}.
complete_job(Pool, JobId) ->
    SQL =
        ~"UPDATE shigoto_jobs SET state = 'completed', completed_at = now() WHERE id = $1 RETURNING batch_id",
    _ = resolve_dependencies(Pool, JobId),
    case query(Pool, SQL, [JobId]) of
        #{rows := [#{batch_id := BatchId}]} when BatchId =/= null ->
            shigoto_batch:job_completed(Pool, BatchId);
        #{command := update} ->
            ok;
        {error, _} = Err ->
            Err
    end.

-doc "Record a job failure with structured error and configurable backoff.".
-spec fail_job(atom(), map(), term(), pos_integer()) -> ok | {error, term()}.
fail_job(Pool, Job, Reason, BackoffSeconds) ->
    JobId = maps:get(id, Job),
    ErrorJson = encode_json(build_structured_error(Job, Reason)),
    SQL =
        <<
            "UPDATE shigoto_jobs SET\n"
            "state = CASE WHEN attempt >= max_attempts THEN 'discarded' ELSE 'retryable' END,\n"
            "discarded_at = CASE WHEN attempt >= max_attempts THEN now() ELSE NULL END,\n"
            "scheduled_at = CASE WHEN attempt >= max_attempts THEN scheduled_at\n"
            "  ELSE now() + make_interval(secs => $3) END,\n"
            "errors = errors || $2::jsonb\n"
            "WHERE id = $1\n"
            "RETURNING *"
        >>,
    case query(Pool, SQL, [JobId, ErrorJson, BackoffSeconds]) of
        #{rows := [#{state := ~"discarded"} = Updated]} ->
            _ = resolve_dependencies(Pool, JobId),
            _ = maybe_on_discard(Job, Updated),
            _ = maybe_batch_discard(Pool, Updated),
            ok;
        #{rows := [_Updated]} ->
            ok;
        {error, _} = Err ->
            Err
    end.

-doc "Mark a job as discarded. Resolves dependencies so dependent jobs aren't stuck.".
-spec discard_job(atom(), integer()) -> ok | {error, term()}.
discard_job(Pool, JobId) ->
    SQL = ~"UPDATE shigoto_jobs SET state = 'discarded', discarded_at = now() WHERE id = $1",
    _ = resolve_dependencies(Pool, JobId),
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Cancel a job. Resolves dependencies so dependent jobs aren't stuck.".
-spec cancel_job(atom(), integer()) -> ok | {error, term()}.
cancel_job(Pool, JobId) ->
    SQL =
        <<
            "UPDATE shigoto_jobs SET state = 'cancelled', cancelled_at = now() "
            "WHERE id = $1 AND state IN ('available', 'retryable', 'executing')"
        >>,
    _ = resolve_dependencies(Pool, JobId),
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Cancel jobs matching a pattern. Supports worker, queue, tags filters.".
-spec cancel_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
cancel_by(Pool, Filters) ->
    {WhereClauses, Params, _} = build_filter_clauses(Filters, 1),
    WhereSQL =
        case WhereClauses of
            [] ->
                ~"state IN ('available', 'retryable')";
            _ ->
                iolist_to_binary([
                    ~"state IN ('available', 'retryable') AND ",
                    lists:join(~" AND ", WhereClauses)
                ])
        end,
    SQL = iolist_to_binary([
        ~"UPDATE shigoto_jobs SET state = 'cancelled', cancelled_at = now() WHERE ",
        WhereSQL
    ]),
    case query(Pool, SQL, Params) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Snooze a job — reschedule for later without counting as a failure.".
-spec snooze_job(atom(), integer(), pos_integer()) -> ok | {error, term()}.
snooze_job(Pool, JobId, Seconds) ->
    SQL =
        <<
            "UPDATE shigoto_jobs SET state = 'available',\n"
            "scheduled_at = now() + make_interval(secs => $2)\n"
            "WHERE id = $1"
        >>,
    case query(Pool, SQL, [JobId, Seconds]) of
        #{command := update} -> ok;
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

-doc "Retry all jobs matching a filter. Supports worker, queue, state, tags.".
-spec retry_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
retry_by(Pool, Filters) ->
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

-doc "Rescue stale executing jobs. Uses heartbeat if available, otherwise attempted_at.".
-spec rescue_stale_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
rescue_stale_jobs(Pool, StaleSeconds) ->
    SQL =
        <<
            "UPDATE shigoto_jobs SET state = 'available'\n"
            "WHERE state = 'executing'\n"
            "AND (\n"
            "  (heartbeat_at IS NOT NULL AND heartbeat_at < now() - make_interval(secs => $1))\n"
            "  OR\n"
            "  (heartbeat_at IS NULL AND attempted_at < now() - make_interval(secs => $1))\n"
            ")"
        >>,
    case query(Pool, SQL, [StaleSeconds]) of
        #{num_rows := Count} -> {ok, Count};
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

-doc "Resolve dependencies: remove completed job ID from all depends_on arrays.".
-spec resolve_dependencies(atom(), integer()) -> {ok, non_neg_integer()} | {error, term()}.
resolve_dependencies(Pool, CompletedJobId) ->
    SQL =
        ~"UPDATE shigoto_jobs SET depends_on = array_remove(depends_on, $1) WHERE $1 = ANY(depends_on)",
    case query(Pool, SQL, [CompletedJobId]) of
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

-doc "Get a job by ID.".
-spec get_job(atom(), integer()) -> {ok, map()} | {error, not_found | term()}.
get_job(Pool, JobId) ->
    SQL = ~"SELECT * FROM shigoto_jobs WHERE id = $1",
    case query(Pool, SQL, [JobId]) of
        #{rows := [Row]} -> {ok, decrypt_job_args(Row)};
        #{rows := []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

-doc "Archive completed/discarded/cancelled jobs older than given days. Moves to archive table then deletes.".
-spec archive_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
archive_jobs(Pool, Days) ->
    InsertSQL =
        <<
            "INSERT INTO shigoto_jobs_archive\n"
            "(id, queue, worker, args, state, priority, attempt, max_attempts,\n"
            " scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,\n"
            " inserted_at, errors, meta, unique_key, tags, progress, batch_id,\n"
            " heartbeat_at, partition_key, depends_on)\n"
            "SELECT id, queue, worker, args, state, priority, attempt, max_attempts,\n"
            " scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,\n"
            " inserted_at, errors, meta, unique_key, tags, progress, batch_id,\n"
            " heartbeat_at, partition_key, depends_on\n"
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
    pgo:transaction(
        fun() ->
            _ = query(Pool, InsertSQL, [Days]),
            case query(Pool, DeleteSQL, [Days]) of
                #{num_rows := Count} -> {ok, Count};
                {error, _} = Err -> Err
            end
        end,
        #{pool => Pool}
    ).

-doc "Upsert a cron entry.".
-spec upsert_cron_entry(atom(), map()) -> ok | {error, term()}.
upsert_cron_entry(Pool, Entry) ->
    SQL =
        <<
            "INSERT INTO shigoto_cron (name, worker, args, schedule, queue, priority, max_attempts)\n"
            "VALUES ($1, $2, $3, $4, $5, $6, $7)\n"
            "ON CONFLICT (name) DO UPDATE SET\n"
            "worker = EXCLUDED.worker, args = EXCLUDED.args, schedule = EXCLUDED.schedule,\n"
            "queue = EXCLUDED.queue, priority = EXCLUDED.priority, max_attempts = EXCLUDED.max_attempts"
        >>,
    ArgsJson = encode_json(maps:get(args, Entry, #{})),
    case
        query(Pool, SQL, [
            maps:get(name, Entry),
            atom_to_binary(maps:get(worker, Entry), utf8),
            ArgsJson,
            maps:get(schedule, Entry),
            maps:get(queue, Entry, ~"default"),
            maps:get(priority, Entry, 0),
            maps:get(max_attempts, Entry, 3)
        ])
    of
        #{command := insert} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Get cron entries that are due for scheduling.".
-spec get_due_cron_entries(atom()) -> {ok, [map()]} | {error, term()}.
get_due_cron_entries(Pool) ->
    SQL = ~"SELECT * FROM shigoto_cron",
    case query(Pool, SQL, []) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal: dependency validation
%%----------------------------------------------------------------------

validate_dependencies(_Pool, []) ->
    ok;
validate_dependencies(Pool, DepIds) ->
    %% Check that all dependency IDs exist
    Placeholders = lists:join(~", ", [
        <<"$", (integer_to_binary(I))/binary>>
     || I <- lists:seq(1, length(DepIds))
    ]),
    SQL = iolist_to_binary([
        ~"SELECT id, depends_on FROM shigoto_jobs WHERE id IN (",
        Placeholders,
        ~")"
    ]),
    case query(Pool, SQL, DepIds) of
        #{rows := Rows} ->
            FoundIds = [maps:get(id, R) || R <- Rows],
            Missing = DepIds -- FoundIds,
            case Missing of
                [] ->
                    %% Check for cycles: if any dep transitively depends on us,
                    %% we'd create a cycle. Since the new job doesn't have an ID yet,
                    %% we check if any dep depends on any other dep (mutual deps).
                    check_transitive_cycles(Rows, DepIds);
                _ ->
                    {error, {missing_dependencies, Missing}}
            end;
        {error, _} = Err ->
            Err
    end.

check_transitive_cycles(Rows, DepIds) ->
    DepSet = sets:from_list(DepIds),
    HasCycle = lists:any(
        fun
            (#{depends_on := TransDeps}) when is_list(TransDeps) ->
                lists:any(fun(D) -> sets:is_element(D, DepSet) end, TransDeps);
            (_) ->
                false
        end,
        Rows
    ),
    case HasCycle of
        true -> {error, dependency_cycle};
        false -> ok
    end.

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
    case maps:find(unique, Opts) of
        {ok, UniqueOpts} when is_map(UniqueOpts) ->
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
    UniqueKey = build_unique_key(UniqueOpts, Worker, Args, Queue),
    LockKey = erlang:phash2(UniqueKey),
    pgo:transaction(
        fun() ->
            _ = query(Pool, ~"SELECT pg_advisory_xact_lock($1)::text", [LockKey]),
            case find_existing_job(Pool, UniqueOpts, UniqueKey) of
                {ok, Existing} ->
                    maybe_replace(Pool, Existing, JobParams, UniqueOpts);
                not_found ->
                    do_insert(Pool, JobParams, Opts, UniqueKey)
            end
        end,
        #{pool => Pool}
    ).

build_unique_key(#{keys := Keys}, Worker, Args, Queue) ->
    Parts = lists:map(
        fun
            (worker) -> Worker;
            (args) -> encode_json(Args);
            (queue) -> Queue
        end,
        lists:sort(Keys)
    ),
    iolist_to_binary(lists:join(~":", Parts)).

find_existing_job(Pool, #{states := States, period := Period}, UniqueKey) ->
    StatesClause = states_in_clause(States),
    {SQL, Params} =
        case Period of
            infinity ->
                {
                    iolist_to_binary([
                        ~"SELECT * FROM shigoto_jobs WHERE unique_key = $1 AND state IN (",
                        StatesClause,
                        ~") ORDER BY id ASC LIMIT 1"
                    ]),
                    [UniqueKey]
                };
            Secs ->
                {
                    iolist_to_binary([
                        ~"SELECT * FROM shigoto_jobs WHERE unique_key = $1 AND state IN (",
                        StatesClause,
                        ~") AND inserted_at >= now() - make_interval(secs => $2) ORDER BY id ASC LIMIT 1"
                    ]),
                    [UniqueKey, Secs]
                }
        end,
    case query(Pool, SQL, Params) of
        #{rows := [Row]} -> {ok, Row};
        #{rows := []} -> not_found
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
            {Col, Val} = replace_field_value(Field, JobParams),
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

replace_field_value(args, JobParams) ->
    {~"args", encode_json(maps:get(args, JobParams, #{}))};
replace_field_value(priority, JobParams) ->
    {~"priority", maps:get(priority, JobParams, 0)};
replace_field_value(max_attempts, JobParams) ->
    {~"max_attempts", maps:get(max_attempts, JobParams, 3)};
replace_field_value(scheduled_at, JobParams) ->
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
    ArgsJson = encode_json(Args),
    EncArgs = shigoto_crypto:encrypt(ArgsJson),
    MetaJson = encode_json(Meta),
    EncMeta = shigoto_crypto:encrypt(MetaJson),
    SQL =
        <<
            "INSERT INTO shigoto_jobs\n"
            "(queue, worker, args, meta, priority, max_attempts, scheduled_at, unique_key, tags, batch_id, partition_key, depends_on)\n"
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)\n"
            "RETURNING *"
        >>,
    case
        query(Pool, SQL, [
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
            DependsOn
        ])
    of
        #{rows := [Row]} ->
            _ = maybe_increment_batch(Pool, BatchId),
            {ok, Row};
        {error, _} = Err ->
            Err
    end.

%%----------------------------------------------------------------------
%% Internal: filters for cancel_by
%%----------------------------------------------------------------------

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
    {<<"args @> $", IBin/binary, "::jsonb">>, [encode_json(ArgsMatch)], Idx + 1}.

%%----------------------------------------------------------------------
%% Internal: structured errors
%%----------------------------------------------------------------------

build_structured_error(Job, Reason) ->
    Worker = maps:get(worker, Job, undefined),
    Attempt = maps:get(attempt, Job, 0),
    {ErrorBin, StackBin} = format_structured_reason(Reason),
    Error = #{
        ~"error" => ErrorBin,
        ~"at" => now_timestamptz_str(),
        ~"attempt" => Attempt,
        ~"worker" => format_worker(Worker)
    },
    case StackBin of
        <<>> -> Error;
        _ -> Error#{~"stacktrace" => StackBin}
    end.

format_structured_reason({Class, Reason, Stacktrace}) when is_list(Stacktrace) ->
    ErrorBin = iolist_to_binary(io_lib:format("~0p:~0p", [Class, Reason])),
    StackBin = iolist_to_binary(io_lib:format("~0p", [Stacktrace])),
    {ErrorBin, StackBin};
format_structured_reason({Class, Reason}) ->
    ErrorBin = iolist_to_binary(io_lib:format("~0p:~0p", [Class, Reason])),
    {ErrorBin, <<>>};
format_structured_reason(Reason) ->
    ErrorBin = iolist_to_binary(io_lib:format("~0p", [Reason])),
    {ErrorBin, <<>>}.

format_worker(W) when is_atom(W) -> atom_to_binary(W, utf8);
format_worker(W) when is_binary(W) -> W;
format_worker(_) -> ~"unknown".

%%----------------------------------------------------------------------
%% Internal: batch helpers
%%----------------------------------------------------------------------

maybe_increment_batch(_Pool, null) -> ok;
maybe_increment_batch(Pool, BatchId) -> shigoto_batch:increment_total(Pool, BatchId).

maybe_batch_discard(Pool, #{state := ~"discarded", batch_id := BatchId}) when
    BatchId =/= null
->
    shigoto_batch:job_discarded(Pool, BatchId);
maybe_batch_discard(_Pool, _Job) ->
    ok.

maybe_on_discard(OrigJob, #{state := ~"discarded", errors := Errors}) ->
    Worker = resolve_worker_atom(OrigJob),
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, on_discard, 2) of
        true ->
            Args = decode_args(maps:get(args, OrigJob, #{})),
            DecodedErrors =
                case is_binary(Errors) of
                    true -> json:decode(Errors);
                    false -> Errors
                end,
            try
                Worker:on_discard(Args, DecodedErrors)
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end;
maybe_on_discard(_OrigJob, _Updated) ->
    ok.

resolve_worker_atom(#{worker := W}) when is_atom(W) -> W;
resolve_worker_atom(#{worker := W}) when is_binary(W) -> binary_to_existing_atom(W, utf8).

update_batch_counts(Pool, BatchIds) ->
    UniqueBatchIds = lists:usort([B || B <- BatchIds, B =/= null]),
    lists:foreach(
        fun(BatchId) ->
            Count = length([B || B <- BatchIds, B =:= BatchId]),
            SQL = ~"UPDATE shigoto_batches SET total_jobs = total_jobs + $2 WHERE id = $1",
            _ = query(Pool, SQL, [BatchId, Count])
        end,
        UniqueBatchIds
    ).

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

decode_args(Args) when is_map(Args) -> Args;
decode_args(Args) when is_binary(Args) ->
    try
        json:decode(Args)
    catch
        _:_ -> #{}
    end;
decode_args(_) ->
    #{}.

decrypt_job_args(Job0) ->
    Job1 =
        case Job0 of
            #{args := Args} when is_binary(Args) ->
                Job0#{args => shigoto_crypto:decrypt(Args)};
            _ ->
                Job0
        end,
    case Job1 of
        #{meta := Meta} when is_binary(Meta) ->
            Job1#{meta => shigoto_crypto:decrypt(Meta)};
        _ ->
            Job1
    end.

query(Pool, SQL, Params) ->
    pgo:query(SQL, Params, #{pool => Pool, decode_opts => ?DECODE_OPTS}).

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

encode_pg_array(Tags) when is_list(Tags) ->
    Tags;
encode_pg_array(_) ->
    [].
