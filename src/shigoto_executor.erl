-module(shigoto_executor).
-moduledoc """
Executes a single job through the middleware chain with seki resilience.
Started by the executor supervisor, reports back to the queue process when done.
""".
-behaviour(gen_server).

-export([start_link/3, execute_sync/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    job :: map(),
    pool :: atom(),
    queue_pid :: pid()
}).

-doc false.
start_link(Job, Pool, QueuePid) ->
    gen_server:start_link(?MODULE, {Job, Pool, QueuePid}, []).

-doc "Execute a job synchronously (for drain_queue).".
-spec execute_sync(map(), atom(), timeout()) -> ok | {snooze, pos_integer()} | {error, term()}.
execute_sync(Job, Pool, Timeout) ->
    Worker = resolve_worker(Job),
    Args = resolve_args(Job),
    JobId = maps:get(id, Job),
    set_logger_metadata(Job, Worker),
    T0 = erlang:monotonic_time(native),
    try
        case run_with_resilience(Job, Worker, Args, Timeout) of
            ok ->
                Duration = erlang:monotonic_time(native) - T0,
                _ = shigoto_repo:complete_job(Pool, JobId),
                _ = shigoto_telemetry:job_completed(Job, Duration),
                ok;
            {snooze, Seconds} ->
                _ = shigoto_repo:snooze_job(Pool, JobId, Seconds),
                {snooze, Seconds};
            {error, FailReason} ->
                Duration = erlang:monotonic_time(native) - T0,
                BackoffSecs = compute_backoff(Worker, Job, FailReason),
                _ = shigoto_repo:fail_job(Pool, Job, FailReason, BackoffSecs),
                _ = shigoto_telemetry:job_failed(Job, FailReason, Duration),
                {error, FailReason}
        end
    catch
        Class:CatchReason:Stack ->
            Duration2 = erlang:monotonic_time(native) - T0,
            Err = {Class, CatchReason, Stack},
            BackoffSecs2 = compute_backoff(Worker, Job, Err),
            _ = shigoto_repo:fail_job(Pool, Job, Err, BackoffSecs2),
            _ = shigoto_telemetry:job_failed(Job, {Class, CatchReason}, Duration2),
            {error, {Class, CatchReason}}
    after
        clear_logger_metadata()
    end.

-doc false.
init({Job, Pool, QueuePid}) ->
    JobId = maps:get(id, Job),
    ets:insert(shigoto_executors, {JobId, self()}),
    gen_server:cast(self(), execute),
    {ok, #state{job = Job, pool = Pool, queue_pid = QueuePid}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(execute, #state{job = Job, pool = Pool, queue_pid = QueuePid} = State) ->
    Worker = resolve_worker(Job),
    Args = resolve_args(Job),
    JobId = maps:get(id, Job),
    Timeout = resolve_timeout(Worker),
    set_logger_metadata(Job, Worker),
    T0 = erlang:monotonic_time(native),
    try
        case run_with_resilience(Job, Worker, Args, Timeout) of
            ok ->
                Duration = erlang:monotonic_time(native) - T0,
                _ = shigoto_repo:complete_job(Pool, JobId),
                _ = shigoto_telemetry:job_completed(Job, Duration),
                _ = shigoto_resilience:complete_load(
                    Job, erlang:convert_time_unit(Duration, native, millisecond)
                ),
                notify_breaker_success(Worker),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State};
            {snooze, Seconds} ->
                _ = shigoto_repo:snooze_job(Pool, JobId, Seconds),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State};
            {error, Reason} ->
                Duration = erlang:monotonic_time(native) - T0,
                BackoffSecs = compute_backoff(Worker, Job, Reason),
                _ = shigoto_repo:fail_job(Pool, Job, Reason, BackoffSecs),
                _ = shigoto_telemetry:job_failed(Job, Reason, Duration),
                _ = shigoto_resilience:complete_load(
                    Job, erlang:convert_time_unit(Duration, native, millisecond)
                ),
                notify_breaker_failure(Worker),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State}
        end
    catch
        Class:CatchReason:Stack ->
            Duration2 = erlang:monotonic_time(native) - T0,
            Err = {Class, CatchReason, Stack},
            BackoffSecs2 = compute_backoff(Worker, Job, Err),
            _ = shigoto_repo:fail_job(Pool, Job, Err, BackoffSecs2),
            _ = shigoto_telemetry:job_failed(Job, {Class, CatchReason}, Duration2),
            _ = shigoto_resilience:complete_load(
                Job, erlang:convert_time_unit(Duration2, native, millisecond)
            ),
            notify_breaker_failure(Worker),
            gen_server:cast(QueuePid, {job_finished, JobId, self()}),
            {stop, normal, State}
    after
        shigoto_resilience:release_bulkhead(Worker),
        clear_logger_metadata()
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{job = Job}) ->
    ets:delete(shigoto_executors, maps:get(id, Job)),
    ok.

%%----------------------------------------------------------------------
%% Internal: resilience + middleware
%%----------------------------------------------------------------------

run_with_resilience(Job, Worker, Args, Timeout) ->
    shigoto_resilience:ensure_worker_primitives(Worker),
    case shigoto_resilience:check_load(Job) of
        {snooze, _} = Snooze ->
            Snooze;
        ok ->
            case shigoto_resilience:check_rate_limit(Worker, Job) of
                {snooze, _} = Snooze ->
                    Snooze;
                ok ->
                    case shigoto_resilience:check_bulkhead(Worker, Job) of
                        {snooze, _} = Snooze ->
                            Snooze;
                        ok ->
                            case shigoto_resilience:check_circuit(Worker, Job) of
                                {snooze, _} = Snooze -> Snooze;
                                ok -> run_middleware_chain(Job, Worker, Args, Timeout)
                            end
                    end
            end
    end.

run_middleware_chain(Job, Worker, Args, Timeout) ->
    %% Pass decoded args in the job map so middleware sees maps, not binaries
    JobWithArgs = Job#{args => Args},
    PerformFn = fun(_JobArg) ->
        apply_with_timeout(Worker, perform, [Args], Timeout)
    end,
    shigoto_middleware:run(JobWithArgs, Worker, PerformFn).

notify_breaker_success(Worker) ->
    case whereis(seki_sup) of
        undefined ->
            ok;
        _ ->
            BreakerName = binary_to_atom(<<"shigoto_cb_", (atom_to_binary(Worker))/binary>>),
            catch seki:call(BreakerName, fun() -> ok end),
            ok
    end.

notify_breaker_failure(Worker) ->
    case whereis(seki_sup) of
        undefined ->
            ok;
        _ ->
            BreakerName = binary_to_atom(<<"shigoto_cb_", (atom_to_binary(Worker))/binary>>),
            catch seki:call(BreakerName, fun() -> {error, job_failed} end),
            ok
    end.

%%----------------------------------------------------------------------
%% Internal: backoff
%%----------------------------------------------------------------------

-define(DEFAULT_TIMEOUT, 300000).
-define(MAX_BACKOFF, 1800).

compute_backoff(Worker, Job, Error) ->
    _ = code:ensure_loaded(Worker),
    Attempt = maps:get(attempt, Job, 1),
    case erlang:function_exported(Worker, backoff, 2) of
        true ->
            try
                Worker:backoff(Attempt, Error)
            catch
                _:_ -> default_backoff(Attempt)
            end;
        false ->
            default_backoff(Attempt)
    end.

default_backoff(Attempt) ->
    Delay = round(math:pow(Attempt, 4)) + rand:uniform(30),
    min(Delay, ?MAX_BACKOFF).

%%----------------------------------------------------------------------
%% Internal: resolution
%%----------------------------------------------------------------------

resolve_timeout(Worker) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, timeout, 0) of
        true -> Worker:timeout();
        false -> ?DEFAULT_TIMEOUT
    end.

resolve_worker(#{worker := Worker}) when is_atom(Worker) ->
    Worker;
resolve_worker(#{worker := Worker}) when is_binary(Worker) ->
    binary_to_existing_atom(Worker, utf8).

resolve_args(#{args := Args}) when is_map(Args) ->
    Args;
resolve_args(#{args := Args}) when is_binary(Args) ->
    try
        json:decode(Args)
    catch
        _:_ -> #{}
    end;
resolve_args(_) ->
    #{}.

apply_with_timeout(Module, Function, Args, Timeout) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = apply(Module, Function, Args),
        Self ! {self(), Result}
    end),
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        erlang:demonitor(Ref, [flush]),
        exit(Pid, kill),
        {error, timeout}
    end.

%%----------------------------------------------------------------------
%% Internal: logger metadata
%%----------------------------------------------------------------------

set_logger_metadata(Job, Worker) ->
    logger:update_process_metadata(#{
        shigoto_job_id => maps:get(id, Job, undefined),
        shigoto_worker => Worker,
        shigoto_queue => maps:get(queue, Job, undefined),
        shigoto_attempt => maps:get(attempt, Job, 0)
    }).

clear_logger_metadata() ->
    logger:update_process_metadata(#{
        shigoto_job_id => undefined,
        shigoto_worker => undefined,
        shigoto_queue => undefined,
        shigoto_attempt => undefined
    }).
