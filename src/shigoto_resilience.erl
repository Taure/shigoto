-module(shigoto_resilience).
-moduledoc """
Seki-based resilience integration for Shigoto workers.

Provides per-worker rate limiting, circuit breaking, bulkhead (concurrency
limiting), and system-level load shedding. All primitives are lazily
initialized on first use based on worker callbacks.

## Rate Limiting

Workers that export `rate_limit/0` get per-worker rate limiting via seki.
Jobs that hit the rate limit are snoozed (rescheduled for later) rather than failed.

## Circuit Breaking

When a worker fails repeatedly, its circuit breaker opens and subsequent
jobs are snoozed until the breaker transitions to half-open, keeping work
off a known-broken dependency.

## Bulkhead

Workers that export `concurrency/0` get a global concurrency limit across
all queues. This is separate from per-queue concurrency.

## Load Shedding

System-level CoDel-based load shedding can be enabled via config. Low-priority
jobs are shed first when the system is overloaded.
""".

-export([
    check_rate_limit/2,
    check_bulkhead/2,
    release_bulkhead/1,
    check_circuit/2,
    check_global_concurrency/2,
    check_load/1,
    complete_load/2,
    ensure_worker_primitives/1,
    setup_load_shedder/0
]).

-include_lib("kernel/include/logger.hrl").

-define(INIT_TABLE, shigoto_resilience_init).
-define(GLOBAL_CONCURRENCY_SNOOZE, 5).

-doc "Ensure seki primitives exist for a worker. Lazy and idempotent.".
-spec ensure_worker_primitives(module()) -> ok.
ensure_worker_primitives(Worker) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            case ets:whereis(?INIT_TABLE) of
                undefined ->
                    _ = ets:new(?INIT_TABLE, [named_table, public, set, {read_concurrency, true}]),
                    do_ensure(Worker);
                _ ->
                    case ets:lookup(?INIT_TABLE, Worker) of
                        [{_, true}] -> ok;
                        [] -> do_ensure(Worker)
                    end
            end
    end.

-doc "Check per-worker rate limit. Returns ok or {snooze, Seconds}.".
-spec check_rate_limit(module(), map()) -> ok | {snooze, pos_integer()}.
check_rate_limit(Worker, _Job = #{}) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            _ = code:ensure_loaded(Worker),
            case erlang:function_exported(Worker, rate_limit, 0) of
                false ->
                    ok;
                true ->
                    LimiterName = limiter_name(Worker),
                    case seki:check(LimiterName, Worker) of
                        {allow, _} ->
                            ok;
                        {deny, #{retry_after := Ms}} ->
                            shigoto_telemetry:resilience_rate_limited(Worker, Ms),
                            {snooze, max(1, Ms div 1000)}
                    end
            end
    end.

-doc "Check per-worker bulkhead. Returns ok or {snooze, 5}.".
-spec check_bulkhead(module(), map()) -> ok | {snooze, pos_integer()}.
check_bulkhead(Worker, _Job = #{}) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            _ = code:ensure_loaded(Worker),
            case erlang:function_exported(Worker, concurrency, 0) of
                false ->
                    ok;
                true ->
                    BulkheadName = bulkhead_name(Worker),
                    case seki_bulkhead:acquire(BulkheadName) of
                        ok ->
                            ok;
                        {error, bulkhead_full} ->
                            shigoto_telemetry:resilience_bulkhead_full(Worker),
                            {snooze, 5}
                    end
            end
    end.

-doc "Release bulkhead slot for a worker.".
-spec release_bulkhead(module()) -> ok.
release_bulkhead(Worker) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            _ = code:ensure_loaded(Worker),
            case erlang:function_exported(Worker, concurrency, 0) of
                false -> ok;
                true -> seki_bulkhead:release(bulkhead_name(Worker))
            end
    end.

-doc """
Check the per-worker global concurrency limit across all nodes via PostgreSQL.

The check-and-admit is serialised per worker with a PostgreSQL transaction-scoped
advisory lock, so two nodes can never both admit a job past the cap. It counts
*other* jobs of the worker already `executing` (excluding the job being checked,
which claiming has already marked `executing`), so a job at exactly the limit is
not spuriously snoozed. When the limit is reached the job's slot is freed back to
`available` inside the same locked transaction, so the next serialised checker
observes the reduced count. That makes a burst of concurrently claimed jobs snooze
one at a time until exactly `global_concurrency/0` remain running, instead of all
snoozing together and livelocking.

Returns `ok` or `{snooze, Seconds}`. Fails open (`ok`) on any database error, so a
transient DB problem never turns the check into a job failure.
""".
-spec check_global_concurrency(module(), map()) -> ok | {snooze, pos_integer()}.
check_global_concurrency(Worker, Job = #{}) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, global_concurrency, 0) of
        false ->
            ok;
        true ->
            MaxGlobal = Worker:global_concurrency(),
            Pool = shigoto_config:pool(),
            WorkerBin = atom_to_binary(Worker, utf8),
            JobId = maps:get(id, Job),
            LockKey = erlang:phash2({global_concurrency, WorkerBin}),
            admit_global(Pool, WorkerBin, JobId, MaxGlobal, LockKey)
    end.

-doc "Check circuit breaker for a worker. Returns ok or {snooze, 10}.".
-spec check_circuit(module(), map()) -> ok | {snooze, pos_integer()}.
check_circuit(Worker, _Job = #{}) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            BreakerName = breaker_name(Worker),
            case seki:state(BreakerName) of
                closed ->
                    ok;
                half_open ->
                    ok;
                open ->
                    shigoto_telemetry:resilience_circuit_open(Worker),
                    {snooze, 10}
            end
    end.

-doc "Execute through circuit breaker, returning the result.".
-spec check_load(map()) -> ok | {snooze, pos_integer()}.
check_load(Job) ->
    case shigoto_config:load_shedding() of
        undefined ->
            ok;
        _ ->
            Priority = maps:get(priority, Job, 0),
            SekiPriority = priority_to_seki(Priority),
            case seki_shed:admit(shigoto_load_shedder, SekiPriority) of
                ok ->
                    ok;
                {error, shed} ->
                    shigoto_telemetry:resilience_load_shed(Priority),
                    {snooze, 5}
            end
    end.

-doc "Report load shedder completion.".
-spec complete_load(map(), non_neg_integer()) -> ok.
complete_load(_Job = #{}, DurationMs) ->
    case shigoto_config:load_shedding() of
        undefined ->
            ok;
        _ ->
            case is_seki_running() of
                false -> ok;
                true -> seki_shed:complete(shigoto_load_shedder, DurationMs)
            end
    end.

-doc "Set up system-level load shedder if configured.".
-spec setup_load_shedder() -> ok.
setup_load_shedder() ->
    case shigoto_config:load_shedding() of
        undefined ->
            ok;
        Opts when is_map(Opts) ->
            {ok, _} = seki:new_shed(shigoto_load_shedder, Opts),
            ok
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

admit_global(Pool, WorkerBin, JobId, MaxGlobal, LockKey) ->
    try
        pgo:transaction(
            fun() ->
                _ = pgo:query(~"SELECT pg_advisory_xact_lock($1)::text", [LockKey], #{pool => Pool}),
                CountSQL =
                    ~"SELECT count(*) AS count FROM shigoto_jobs WHERE worker = $1 AND state = 'executing' AND id <> $2",
                case
                    pgo:query(CountSQL, [WorkerBin, JobId], #{
                        pool => Pool, decode_opts => [return_rows_as_maps, column_name_as_atom]
                    })
                of
                    #{rows := [#{count := Others}]} when Others >= MaxGlobal ->
                        _ = shigoto_repo:snooze_job(Pool, JobId, ?GLOBAL_CONCURRENCY_SNOOZE),
                        {snooze, ?GLOBAL_CONCURRENCY_SNOOZE};
                    _ ->
                        ok
                end
            end,
            #{pool => Pool}
        )
    of
        {snooze, _} = Snooze -> Snooze;
        _ -> ok
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING(#{
                msg => ~"global concurrency check failed, admitting job",
                worker => WorkerBin,
                job_id => JobId,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            ok
    end.

do_ensure(Worker) ->
    _ = code:ensure_loaded(Worker),
    _ = maybe_create_limiter(Worker),
    _ = maybe_create_bulkhead(Worker),
    _ = maybe_create_breaker(Worker),
    ets:insert(?INIT_TABLE, {Worker, true}),
    ok.

maybe_create_limiter(Worker) ->
    case erlang:function_exported(Worker, rate_limit, 0) of
        false ->
            ok;
        true ->
            Opts = Worker:rate_limit(),
            Name = limiter_name(Worker),
            seki:new_limiter(Name, Opts)
    end.

maybe_create_bulkhead(Worker) ->
    case erlang:function_exported(Worker, concurrency, 0) of
        false ->
            ok;
        true ->
            MaxConcurrent = Worker:concurrency(),
            Name = bulkhead_name(Worker),
            seki:new_bulkhead(Name, #{max_concurrent => MaxConcurrent})
    end.

maybe_create_breaker(Worker) ->
    Name = breaker_name(Worker),
    Defaults = #{
        window_type => count,
        window_size => 20,
        failure_threshold => 50,
        wait_duration => 30000,
        half_open_requests => 3
    },
    Opts =
        case erlang:function_exported(Worker, circuit_breaker, 0) of
            true ->
                WorkerOpts = Worker:circuit_breaker(),
                maps:merge(Defaults, WorkerOpts#{window_type => count});
            false ->
                Defaults
        end,
    seki:new_breaker(Name, Opts).

%% Atom creation is safe: bounded by the number of worker modules (loaded at compile time).
%% Each worker creates at most 3 atoms, once, on first use.
limiter_name(Worker) ->
    % elp:ignore W0023
    binary_to_atom(<<"shigoto_rl_", (atom_to_binary(Worker))/binary>>).

bulkhead_name(Worker) ->
    % elp:ignore W0023
    binary_to_atom(<<"shigoto_bh_", (atom_to_binary(Worker))/binary>>).

breaker_name(Worker) ->
    % elp:ignore W0023
    binary_to_atom(<<"shigoto_cb_", (atom_to_binary(Worker))/binary>>).

priority_to_seki(P) when P >= 10 -> 0;
priority_to_seki(P) when P >= 5 -> 1;
priority_to_seki(P) when P >= 0 -> 2;
priority_to_seki(_) -> 3.

is_seki_running() ->
    whereis(seki_sup) =/= undefined.
