-module(shigoto_executor).
-moduledoc """
Runs one claimed job: the resilience gates, the middleware chain and the
worker's `perform/1`, then records the outcome.

One process per running job, started by the executor supervisor for a queue,
which it tells when it is done. `execute_sync/3` runs the same code in the
calling process, for `shigoto:drain_queue/1,2`, with one difference: it does not
report the outcome to the worker's circuit breaker, so a test that drains
failing jobs does not open the breaker for the jobs after it.

The outcome is written under the claim the job was started with (see
`t:shigoto_repo:claim/0`). When that claim no longer holds, because the job was
rescued and claimed again or cancelled while this run was going, the write
changes nothing: the executor logs `shigoto_job_transition_lost`, emits
`[shigoto, job, lost]` and reports no completion or failure of its own. A write
that fails for any other reason is logged as `shigoto_job_transition_failed`
with `[shigoto, job, transition_failed]`; the row stays `executing` and the
stale-job rescue returns it to the queue.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/3, execute_sync/3, run_perform/4, running/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    job :: map(),
    pool :: atom(),
    queue_pid :: pid()
}).

-type outcome() ::
    {completed, term()}
    | {snooze, pos_integer()}
    | {snoozed, pos_integer()}
    | {failed, Stored :: term(), Reported :: term()}.

-doc false.
start_link(Job, Pool, QueuePid) ->
    gen_server:start_link(?MODULE, {Job, Pool, QueuePid}, []).

-doc """
Execute a claimed job in the calling process (for `shigoto:drain_queue/1,2`).

Answers what the job did when that was recorded: `ok`, `{snooze, Seconds}` or
`{error, Reason}`. When the outcome could not be recorded it answers why
instead: `{error, lost}` when the claim no longer held, or the database error.
""".
-spec execute_sync(map(), atom(), timeout()) -> ok | {snooze, pos_integer()} | {error, term()}.
execute_sync(Job, Pool, Timeout) ->
    executed(Job, Pool, Timeout, leave_breaker).

-doc "The executor processes running a job on this node.".
-spec running(integer()) -> [pid()].
running(JobId) ->
    case ets:whereis(shigoto_executors) of
        undefined -> [];
        _Table -> ets:select(shigoto_executors, [{{{JobId, '_'}, '$1'}, [], ['$1']}])
    end.

-doc false.
init({Job, Pool, QueuePid}) ->
    ok = shigoto_db:ignore_sandbox(),
    ets:insert(shigoto_executors, {registered_as(Job), self()}),
    gen_server:cast(self(), execute),
    {ok, #state{job = Job, pool = Pool, queue_pid = QueuePid}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(execute, #state{job = Job, pool = Pool, queue_pid = QueuePid} = State) ->
    _ = executed(Job, Pool, worker_timeout, tell_breaker),
    gen_server:cast(QueuePid, {job_finished, maps:get(id, Job), self()}),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{job = Job}) ->
    ets:delete(shigoto_executors, registered_as(Job)),
    ok.

%% A job that is rescued and claimed again while its first run is still going
%% has two executors for a while; the attempt tells them apart.
registered_as(Job) ->
    {maps:get(id, Job), maps:get(attempt, Job, 0)}.

%%----------------------------------------------------------------------
%% Internal: run, then record
%%----------------------------------------------------------------------

-spec executed(map(), atom(), timeout() | worker_timeout, tell_breaker | leave_breaker) ->
    ok | {snooze, pos_integer()} | {error, term()}.
executed(Job, Pool, Timeout, Breaker) ->
    Worker = resolve_worker(Job),
    set_logger_metadata(Job, Worker),
    T0 = erlang:monotonic_time(native),
    try
        Outcome = outcome(Job, Worker, Timeout),
        Duration = erlang:monotonic_time(native) - T0,
        Answer = recorded(Outcome, Job, Pool, Worker, Duration),
        ok = gates_told(Outcome, Job, Worker, Duration, Breaker),
        Answer
    after
        shigoto_resilience:release_bulkhead(Worker),
        clear_logger_metadata()
    end.

-spec outcome(map(), module(), timeout() | worker_timeout) -> outcome().
outcome(Job, Worker, Timeout) ->
    try run_with_resilience(Job, Worker, resolve_args(Job), timeout_of(Timeout, Worker)) of
        ok -> {completed, null};
        {ok, Result} -> {completed, Result};
        {snooze, Seconds} -> {snooze, Seconds};
        {snoozed, Seconds} -> {snoozed, Seconds};
        {error, Reason} -> {failed, Reason, Reason};
        Other -> {failed, {bad_return_value, Other}, {bad_return_value, Other}}
    catch
        Class:Reason:Stack -> {failed, {Class, Reason, Stack}, {Class, Reason}}
    end.

timeout_of(worker_timeout, Worker) -> resolve_timeout(Worker);
timeout_of(Timeout, _Worker) -> Timeout.

-spec recorded(outcome(), map(), atom(), module(), integer()) ->
    ok | {snooze, pos_integer()} | {error, term()}.
recorded({completed, Result}, Job, Pool, _Worker, Duration) ->
    case shigoto_repo:complete_job(Pool, Job, Result) of
        ok ->
            _ = shigoto_telemetry:job_completed(Job, Duration),
            ok;
        {error, Reason} ->
            unrecorded(completed, Job, Reason)
    end;
recorded({snooze, Seconds}, Job, Pool, _Worker, _Duration) ->
    case shigoto_repo:snooze_job(Pool, Job, Seconds) of
        ok ->
            _ = shigoto_telemetry:job_snoozed(Job, ~"snooze"),
            {snooze, Seconds};
        {error, Reason} ->
            unrecorded(snoozed, Job, Reason)
    end;
recorded({snoozed, Seconds}, Job, _Pool, _Worker, _Duration) ->
    _ = shigoto_telemetry:job_snoozed(Job, ~"snooze"),
    {snooze, Seconds};
recorded({failed, Stored, Reported}, Job, Pool, Worker, Duration) ->
    Backoff = compute_backoff(Worker, Job, Stored),
    case shigoto_repo:fail_job(Pool, Job, Stored, Backoff) of
        ok ->
            _ = shigoto_telemetry:job_failed(Job, Reported, Duration),
            _ = maybe_emit_discarded(Job),
            {error, Reported};
        {error, Reason} ->
            unrecorded(failed, Job, Reason)
    end.

%% The load shedder and the circuit breaker hear how the run went, whether or
%% not its outcome could be written.
-spec gates_told(outcome(), map(), module(), integer(), tell_breaker | leave_breaker) -> ok.
gates_told({completed, _Result}, Job, Worker, Duration, Breaker) ->
    _ = shigoto_resilience:complete_load(Job, milliseconds(Duration)),
    breaker_told(Breaker, Worker, ok);
gates_told({failed, _Stored, _Reported}, Job, Worker, Duration, Breaker) ->
    _ = shigoto_resilience:complete_load(Job, milliseconds(Duration)),
    breaker_told(Breaker, Worker, {error, job_failed});
gates_told(_Snoozed, _Job, _Worker, _Duration, _Breaker) ->
    ok.

milliseconds(Duration) ->
    erlang:convert_time_unit(Duration, native, millisecond).

%% The outcome was not written. `lost` is the fence doing its job; anything
%% else is a write that failed.
-spec unrecorded(completed | snoozed | failed, map(), term()) -> {error, term()}.
unrecorded(Transition, Job, lost) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_job_transition_lost",
        transition => Transition,
        job_id => maps:get(id, Job, undefined),
        attempt => maps:get(attempt, Job, undefined),
        note =>
            ~"the job was rescued, claimed again or cancelled during this run; nothing was written"
    }),
    _ = shigoto_telemetry:job_lost(Job, Transition),
    {error, lost};
unrecorded(Transition, Job, Reason) ->
    Reduced = shigoto_db:reduced(Reason),
    ?LOG_ERROR(#{
        msg => ~"shigoto_job_transition_failed",
        transition => Transition,
        job_id => maps:get(id, Job, undefined),
        attempt => maps:get(attempt, Job, undefined),
        reason => Reduced,
        note => ~"the row stays executing until the stale-job rescue returns it to the queue"
    }),
    _ = shigoto_telemetry:job_transition_failed(Job, Transition, Reduced),
    {error, Reduced}.

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
                    case shigoto_resilience:check_global_concurrency(Worker, Job) of
                        {snooze, Seconds} ->
                            %% This gate has already put the job back itself.
                            {snoozed, Seconds};
                        ok ->
                            case shigoto_resilience:check_bulkhead(Worker, Job) of
                                {snooze, _} = Snooze ->
                                    Snooze;
                                ok ->
                                    case shigoto_resilience:check_circuit(Worker, Job) of
                                        {snooze, _} = Snooze ->
                                            Snooze;
                                        ok ->
                                            run_middleware_chain(
                                                Job, Worker, Args, Timeout, reraise
                                            )
                                    end
                            end
                    end
            end
    end.

-doc """
Run a worker through the exact perform path production uses: `deps_results`
injection + the middleware chain + `perform/1` under `Timeout`. Returns the raw
worker result (`ok | {ok, Result} | {error, _} | {snooze, _}`), and
`{error, _}` when `perform/1` raises.

Shared by the queue executor, `execute_sync/3`, and `shigoto:perform_job/2,3`.
It performs NO persistence, telemetry, retry, or resilience gating — those are the
caller's responsibility. Used by the testing helpers to run a worker with no DB.
""".
-spec run_perform(map(), module(), map(), timeout()) ->
    ok | {ok, term()} | {error, term()} | {snooze, pos_integer()}.
run_perform(Job, Worker, Args, Timeout) ->
    run_middleware_chain(Job, Worker, Args, Timeout, as_error).

run_middleware_chain(Job, Worker, Args, Timeout, WhenRaised) ->
    %% Pass decoded args in the job map so middleware sees maps, not binaries.
    %% For dependent jobs, expose the predecessors' results under deps_results.
    PerformArgs = inject_deps_results(Args, Job),
    JobWithArgs = Job#{args => PerformArgs},
    PerformFn = fun(_JobArg) ->
        performed(apply_with_timeout(Worker, perform, [PerformArgs], Timeout), WhenRaised)
    end,
    shigoto_middleware:run(JobWithArgs, Worker, PerformFn).

%% perform/1 runs in a process of its own. For the executor an exception there
%% is raised again here, so middleware and the executor see it as if perform/1
%% had run inline, with the worker's stacktrace. The testing helpers get it as
%% the exit reason the worker process would have died with.
performed({returned, Result}, _WhenRaised) ->
    Result;
performed({raised, Class, Reason, Stack}, reraise) ->
    erlang:raise(Class, Reason, Stack);
performed({raised, error, Reason, Stack}, as_error) ->
    {error, {Reason, Stack}};
performed({raised, throw, Thrown, Stack}, as_error) ->
    {error, {{nocatch, Thrown}, Stack}};
performed({raised, exit, Reason, _Stack}, as_error) ->
    {error, Reason}.

inject_deps_results(Args, Job) when is_map(Args) ->
    case resolve_deps_results(Job) of
        DepsResults when map_size(DepsResults) > 0 ->
            Args#{deps_results => DepsResults};
        _ ->
            Args
    end;
inject_deps_results(Args, _Job) ->
    Args.

resolve_deps_results(Job) ->
    case maps:get(deps_results, Job, undefined) of
        Bin when is_binary(Bin) -> decode_deps_results(Bin);
        Map when is_map(Map) -> keys_to_ids(Map);
        _ -> #{}
    end.

decode_deps_results(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) -> keys_to_ids(Map);
        _ -> #{}
    catch
        _:_ -> #{}
    end.

keys_to_ids(Map) ->
    maps:from_list([{to_id(K), V} || K := V <- Map]).

to_id(K) when is_binary(K) ->
    try
        binary_to_integer(K)
    catch
        _:_ -> K
    end;
to_id(K) ->
    K.

breaker_told(leave_breaker, _Worker, _Result) ->
    ok;
breaker_told(tell_breaker, Worker, Result) ->
    case whereis(seki_sup) of
        undefined ->
            ok;
        _ ->
            try seki:call(breaker_name(Worker), fun() -> Result end) of
                _ -> ok
            catch
                _:_ -> ok
            end
    end.

breaker_name(Worker) ->
    binary_to_existing_atom(<<"shigoto_cb_", (atom_to_binary(Worker))/binary>>).

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

maybe_emit_discarded(#{attempt := Attempt, max_attempts := MaxAttempts} = Job) when
    Attempt >= MaxAttempts
->
    shigoto_telemetry:job_discarded(Job);
maybe_emit_discarded(_) ->
    ok.

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

-spec apply_with_timeout(module(), atom(), [term()], timeout()) ->
    {returned, term()} | {raised, error | exit | throw, term(), list()}.
apply_with_timeout(Module, Function, Args, Timeout) ->
    Self = self(),
    Metadata = logger:get_process_metadata(),
    IgnoresSandbox = shigoto_db:ignores_sandbox(),
    {Pid, Ref} = spawn_monitor(fun() ->
        ok = inherit_sandbox_scope(IgnoresSandbox),
        inherit_logger_metadata(Metadata),
        Self ! {self(), applied(Module, Function, Args)}
    end),
    receive
        {Pid, Applied} ->
            erlang:demonitor(Ref, [flush]),
            Applied;
        {'DOWN', Ref, process, Pid, Reason} ->
            {returned, {error, Reason}}
    after Timeout ->
        {returned, graceful_kill(Pid, Ref)}
    end.

applied(Module, Function, Args) ->
    try
        {returned, apply(Module, Function, Args)}
    catch
        Class:Reason:Stack -> {raised, Class, Reason, Stack}
    end.

inherit_sandbox_scope(true) -> shigoto_db:ignore_sandbox();
inherit_sandbox_scope(false) -> ok.

graceful_kill(Pid, Ref) ->
    %% Try graceful shutdown first (gives worker a chance to clean up)
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} ->
            {error, timeout}
    after 5000 ->
        %% Worker didn't respond to shutdown — force kill
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 1000 -> ok
        end,
        erlang:demonitor(Ref, [flush]),
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

inherit_logger_metadata(undefined) -> ok;
inherit_logger_metadata(Metadata) -> logger:set_process_metadata(Metadata).

clear_logger_metadata() ->
    logger:update_process_metadata(#{
        shigoto_job_id => undefined,
        shigoto_worker => undefined,
        shigoto_queue => undefined,
        shigoto_attempt => undefined
    }).
