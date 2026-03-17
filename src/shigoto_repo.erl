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
    retry_job/2,
    rescue_stale_jobs/2,
    prune_jobs/2,
    upsert_cron_entry/2,
    get_due_cron_entries/1
]).

-doc "Insert a new job.".
-spec insert_job(module(), map(), map()) -> {ok, map()} | {error, term()}.
insert_job(RepoMod, JobParams, Opts) ->
    Worker = atom_to_binary(maps:get(worker, JobParams), utf8),
    Args = maps:get(args, JobParams, #{}),
    Queue = maps:get(queue, JobParams, maps:get(queue, Opts, <<"default">>)),
    Priority = maps:get(priority, JobParams, 0),
    MaxAttempts = maps:get(max_attempts, JobParams, 3),
    ScheduledAt = maps:get(scheduled_at, JobParams, now_timestamptz()),
    SQL = <<
        "INSERT INTO shigoto_jobs "
        "(queue, worker, args, priority, max_attempts, scheduled_at) "
        "VALUES ($1, $2, $3, $4, $5, $6) "
        "RETURNING *"
    >>,
    ArgsJson = encode_json(Args),
    case
        kura_repo_worker:pgo_query(RepoMod, SQL, [
            Queue, Worker, ArgsJson, Priority, MaxAttempts, ScheduledAt
        ])
    of
        #{rows := [Row]} -> {ok, Row};
        {error, _} = Err -> Err
    end.

-doc "Claim up to N available jobs from a queue using FOR UPDATE SKIP LOCKED.".
-spec claim_jobs(module(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
claim_jobs(RepoMod, Queue, Limit) ->
    SQL = <<
        "UPDATE shigoto_jobs SET "
        "state = 'executing', "
        "attempted_at = now(), "
        "attempt = attempt + 1 "
        "WHERE id IN ("
        "  SELECT id FROM shigoto_jobs "
        "  WHERE queue = $1 "
        "  AND state = 'available' "
        "  AND scheduled_at <= now() "
        "  ORDER BY priority DESC, scheduled_at ASC "
        "  LIMIT $2 "
        "  FOR UPDATE SKIP LOCKED"
        ") RETURNING *"
    >>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [Queue, Limit]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Mark a job as completed.".
-spec complete_job(module(), integer()) -> ok | {error, term()}.
complete_job(RepoMod, JobId) ->
    SQL = <<"UPDATE shigoto_jobs SET state = 'completed', completed_at = now() WHERE id = $1">>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Record a job failure and schedule retry with exponential backoff.".
-spec fail_job(module(), integer(), term()) -> ok | {error, term()}.
fail_job(RepoMod, JobId, Reason) ->
    ErrorJson = encode_json(#{
        <<"error">> => iolist_to_binary(io_lib:format("~p", [Reason])),
        <<"at">> => now_timestamptz_str()
    }),
    SQL = <<
        "UPDATE shigoto_jobs SET "
        "state = CASE WHEN attempt >= max_attempts THEN 'discarded' ELSE 'retryable' END, "
        "discarded_at = CASE WHEN attempt >= max_attempts THEN now() ELSE NULL END, "
        "scheduled_at = CASE WHEN attempt >= max_attempts THEN scheduled_at "
        "  ELSE now() + make_interval(secs => LEAST(POWER(attempt, 4) + (random() * 30)::int, 1800)) END, "
        "errors = errors || $2::jsonb "
        "WHERE id = $1"
    >>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [JobId, ErrorJson]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Mark a job as discarded.".
-spec discard_job(module(), integer()) -> ok | {error, term()}.
discard_job(RepoMod, JobId) ->
    SQL = <<"UPDATE shigoto_jobs SET state = 'discarded', discarded_at = now() WHERE id = $1">>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Cancel a job.".
-spec cancel_job(module(), integer()) -> ok | {error, term()}.
cancel_job(RepoMod, JobId) ->
    SQL =
        <<"UPDATE shigoto_jobs SET state = 'cancelled' WHERE id = $1 AND state IN ('available', 'retryable')">>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Retry a discarded or cancelled job by resetting to available.".
-spec retry_job(module(), integer()) -> ok | {error, term()}.
retry_job(RepoMod, JobId) ->
    SQL = <<
        "UPDATE shigoto_jobs SET state = 'available', scheduled_at = now() "
        "WHERE id = $1 AND state IN ('discarded', 'cancelled')"
    >>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [JobId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Rescue stale executing jobs older than given seconds.".
-spec rescue_stale_jobs(module(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
rescue_stale_jobs(RepoMod, StaleSeconds) ->
    SQL = <<
        "UPDATE shigoto_jobs SET state = 'available' "
        "WHERE state = 'executing' "
        "AND attempted_at < now() - make_interval(secs => $1)"
    >>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [StaleSeconds]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Delete completed/discarded jobs older than given days.".
-spec prune_jobs(module(), pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
prune_jobs(RepoMod, Days) ->
    SQL = <<
        "DELETE FROM shigoto_jobs "
        "WHERE state IN ('completed', 'discarded', 'cancelled') "
        "AND inserted_at < now() - make_interval(days => $1)"
    >>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, [Days]) of
        #{num_rows := Count} -> {ok, Count};
        {error, _} = Err -> Err
    end.

-doc "Upsert a cron entry.".
-spec upsert_cron_entry(module(), map()) -> ok | {error, term()}.
upsert_cron_entry(RepoMod, Entry) ->
    SQL = <<
        "INSERT INTO shigoto_cron (name, worker, args, schedule, queue, priority, max_attempts) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7) "
        "ON CONFLICT (name) DO UPDATE SET "
        "worker = EXCLUDED.worker, args = EXCLUDED.args, schedule = EXCLUDED.schedule, "
        "queue = EXCLUDED.queue, priority = EXCLUDED.priority, max_attempts = EXCLUDED.max_attempts"
    >>,
    ArgsJson = encode_json(maps:get(args, Entry, #{})),
    case
        kura_repo_worker:pgo_query(RepoMod, SQL, [
            maps:get(name, Entry),
            atom_to_binary(maps:get(worker, Entry), utf8),
            ArgsJson,
            maps:get(schedule, Entry),
            maps:get(queue, Entry, <<"default">>),
            maps:get(priority, Entry, 0),
            maps:get(max_attempts, Entry, 3)
        ])
    of
        #{command := insert} -> ok;
        {error, _} = Err -> Err
    end.

-doc "Get cron entries that are due for scheduling.".
-spec get_due_cron_entries(module()) -> {ok, [map()]} | {error, term()}.
get_due_cron_entries(RepoMod) ->
    SQL = <<"SELECT * FROM shigoto_cron">>,
    case kura_repo_worker:pgo_query(RepoMod, SQL, []) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

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
