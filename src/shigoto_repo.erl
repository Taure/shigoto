-module(shigoto_repo).
-moduledoc ~"""
All SQL operations for Shigoto jobs. Uses `FOR UPDATE SKIP LOCKED`
for safe multi-node job claiming.
""".

-export([
    insert_job/3,
    claim_jobs/3,
    complete_job/2,
    fail_job/3,
    discard_job/2,
    cancel_job/2,
    snooze_job/3,
    retry_job/2,
    rescue_stale_jobs/2,
    prune_jobs/2,
    upsert_cron_entry/2,
    get_due_cron_entries/1
]).

-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

-define(DEFAULT_UNIQUE, #{
    keys => [worker, args],
    states => [available, executing, retryable],
    period => infinity,
    replace => []
}).

-doc "Insert a new job. Respects worker defaults and unique constraints.".
-spec insert_job(atom(), map(), map()) ->
    {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert_job(Pool, JobParams0, Opts) ->
    JobParams = apply_worker_defaults(JobParams0),
    case resolve_unique(JobParams, Opts) of
        none ->
            do_insert(Pool, JobParams, Opts, null);
        UniqueOpts ->
            insert_unique(Pool, JobParams, Opts, UniqueOpts)
    end.

-doc "Claim up to N available jobs from a queue using FOR UPDATE SKIP LOCKED.".
-spec claim_jobs(atom(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs(Pool, Queue, Limit) ->
    SQL =
        ~"""
        UPDATE shigoto_jobs SET
        state = 'executing',
        attempted_at = now(),
        attempt = attempt + 1
        WHERE id IN (
          SELECT id FROM shigoto_jobs
          WHERE queue = $1
          AND state = 'available'
          AND scheduled_at <= now()
          ORDER BY priority DESC, scheduled_at ASC
          LIMIT $2
          FOR UPDATE SKIP LOCKED
        ) RETURNING *
        """,
    case query(Pool, SQL, [Queue, Limit]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Mark a job as completed.".
-spec complete_job(atom(), integer()) -> ok | {error, term()}.
complete_job(Pool, JobId) ->
    SQL = ~"UPDATE shigoto_jobs SET state = 'completed', completed_at = now() WHERE id = $1",
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Record a job failure and schedule retry with exponential backoff.".
-spec fail_job(atom(), integer(), term()) -> ok | {error, term()}.
fail_job(Pool, JobId, Reason) ->
    ErrorJson = encode_json(#{
        ~"error" => iolist_to_binary(io_lib:format("~p", [Reason])),
        ~"at" => now_timestamptz_str()
    }),
    SQL =
        ~"""
        UPDATE shigoto_jobs SET
        state = CASE WHEN attempt >= max_attempts THEN 'discarded' ELSE 'retryable' END,
        discarded_at = CASE WHEN attempt >= max_attempts THEN now() ELSE NULL END,
        scheduled_at = CASE WHEN attempt >= max_attempts THEN scheduled_at
          ELSE now() + make_interval(secs => LEAST(POWER(attempt, 4) + (random() * 30)::int, 1800)) END,
        errors = errors || $2::jsonb
        WHERE id = $1
        """,
    case query(Pool, SQL, [JobId, ErrorJson]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Mark a job as discarded.".
-spec discard_job(atom(), integer()) -> ok | {error, term()}.
discard_job(Pool, JobId) ->
    SQL = ~"UPDATE shigoto_jobs SET state = 'discarded', discarded_at = now() WHERE id = $1",
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Cancel a job.".
-spec cancel_job(atom(), integer()) -> ok | {error, term()}.
cancel_job(Pool, JobId) ->
    SQL =
        ~"UPDATE shigoto_jobs SET state = 'cancelled' WHERE id = $1 AND state IN ('available', 'retryable', 'executing')",
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Snooze a job — reschedule for later without counting as a failure.".
-spec snooze_job(atom(), integer(), pos_integer()) -> ok | {error, term()}.
snooze_job(Pool, JobId, Seconds) ->
    SQL =
        ~"""
        UPDATE shigoto_jobs SET state = 'available',
        scheduled_at = now() + make_interval(secs => $2)
        WHERE id = $1
        """,
    case query(Pool, SQL, [JobId, Seconds]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Retry a discarded or cancelled job by resetting to available.".
-spec retry_job(atom(), integer()) -> ok | {error, term()}.
retry_job(Pool, JobId) ->
    SQL =
        ~"""
        UPDATE shigoto_jobs SET state = 'available', scheduled_at = now()
        WHERE id = $1 AND state IN ('discarded', 'cancelled')
        """,
    case query(Pool, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Rescue stale executing jobs older than given seconds.".
-spec rescue_stale_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
rescue_stale_jobs(Pool, StaleSeconds) ->
    SQL =
        ~"""
        UPDATE shigoto_jobs SET state = 'available'
        WHERE state = 'executing'
        AND attempted_at < now() - make_interval(secs => $1)
        """,
    case query(Pool, SQL, [StaleSeconds]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Delete completed/discarded jobs older than given days.".
-spec prune_jobs(atom(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
prune_jobs(Pool, Days) ->
    SQL =
        ~"""
        DELETE FROM shigoto_jobs
        WHERE state IN ('completed', 'discarded', 'cancelled')
        AND inserted_at < now() - make_interval(days => $1)
        """,
    case query(Pool, SQL, [Days]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Upsert a cron entry.".
-spec upsert_cron_entry(atom(), map()) -> ok | {error, term()}.
upsert_cron_entry(Pool, Entry) ->
    SQL =
        ~"""
        INSERT INTO shigoto_cron (name, worker, args, schedule, queue, priority, max_attempts)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (name) DO UPDATE SET
        worker = EXCLUDED.worker, args = EXCLUDED.args, schedule = EXCLUDED.schedule,
        queue = EXCLUDED.queue, priority = EXCLUDED.priority, max_attempts = EXCLUDED.max_attempts
        """,
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
            %% Advisory lock serializes concurrent inserts with the same key.
            %% Cast to text because pg_advisory_xact_lock returns void which pgo can't decode.
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

maybe_replace(_Pool, Existing, _JobParams, #{replace := []}) ->
    {ok, {conflict, Existing}};
maybe_replace(Pool, Existing, JobParams, #{replace := Fields}) ->
    {SetParts, Params, _} = lists:foldl(
        fun(Field, {Acc, Ps, I}) ->
            {Col, Val} = replace_field_value(Field, JobParams),
            IBin = integer_to_binary(I),
            Part = <<Col/binary, " = $", IBin/binary>>,
            {[Part | Acc], Ps ++ [Val], I + 1}
        end,
        {[], [maps:get(id, Existing)], 2},
        Fields
    ),
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
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, ~"default")),
    Priority = maps:get(priority, JobParams, 0),
    MaxAttempts = maps:get(max_attempts, JobParams, 3),
    ScheduledAt = maps:get(scheduled_at, JobParams, now_timestamptz()),
    SQL =
        ~"""
        INSERT INTO shigoto_jobs
        (queue, worker, args, priority, max_attempts, scheduled_at, unique_key)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING *
        """,
    ArgsJson = encode_json(Args),
    case
        query(Pool, SQL, [Queue, Worker, ArgsJson, Priority, MaxAttempts, ScheduledAt, UniqueKey])
    of
        #{rows := [Row]} -> {ok, Row};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal: helpers
%%----------------------------------------------------------------------

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
