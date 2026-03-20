-module(shigoto_resilience).
-moduledoc """
Seki-based resilience integration for Shigoto workers.

Provides per-worker rate limiting, circuit breaking, bulkhead (concurrency
limiting), and system-level load shedding. All primitives are lazily
initialized on first use based on worker callbacks.

## Rate Limiting

Workers that export `rate_limit/0` get per-worker rate limiting via seki.
Jobs that hit the rate limit are snoozed (not retried), preserving attempt count.

## Circuit Breaking

When a worker fails repeatedly, its circuit breaker opens and subsequent
jobs are snoozed until the breaker transitions to half-open. This prevents
burning through retries against a known-broken dependency.

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
    check_load/1,
    complete_load/2,
    ensure_worker_primitives/1,
    setup_load_shedder/0
]).

-define(INIT_TABLE, shigoto_resilience_init).

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
                        {allow, _} -> ok;
                        {deny, #{retry_after := Ms}} -> {snooze, max(1, Ms div 1000)}
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
                        ok -> ok;
                        {error, bulkhead_full} -> {snooze, 5}
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

-doc "Check circuit breaker for a worker. Returns ok or {snooze, 10}.".
-spec check_circuit(module(), map()) -> ok | {snooze, pos_integer()}.
check_circuit(Worker, _Job = #{}) ->
    case is_seki_running() of
        false ->
            ok;
        true ->
            BreakerName = breaker_name(Worker),
            case seki:state(BreakerName) of
                closed -> ok;
                half_open -> ok;
                open -> {snooze, 10}
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
                ok -> ok;
                {error, shed} -> {snooze, 5}
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
    seki:new_breaker(Name, #{
        window_type => count,
        window_size => 20,
        failure_threshold => 50,
        wait_duration => 30000,
        half_open_requests => 3
    }).

limiter_name(Worker) ->
    binary_to_atom(<<"shigoto_rl_", (atom_to_binary(Worker))/binary>>).

bulkhead_name(Worker) ->
    binary_to_atom(<<"shigoto_bh_", (atom_to_binary(Worker))/binary>>).

breaker_name(Worker) ->
    binary_to_atom(<<"shigoto_cb_", (atom_to_binary(Worker))/binary>>).

priority_to_seki(P) when P >= 10 -> 0;
priority_to_seki(P) when P >= 5 -> 1;
priority_to_seki(P) when P >= 0 -> 2;
priority_to_seki(_) -> 3.

is_seki_running() ->
    whereis(seki_sup) =/= undefined.
