-module(shigoto_executor).
-moduledoc """
Runs one claimed job: the resilience gates, the middleware chain and the
worker's `perform/1`, then records the outcome.

One process per running job, started by the executor supervisor for a queue,
which it tells when it is done. `execute_sync/3` runs the same code in the
calling process, for `shigoto:drain_queue/1,2`, with one difference: it does not
report the outcome to the worker's circuit breaker, so a test that drains
failing jobs does not open the breaker for the jobs after it.

`perform/1` runs in a process linked to the executor, so neither outlives the
other. `stop/2` ends a run early: `shigoto:cancel/1,2` uses it for the jobs
running on this node, and the heartbeat for the runs whose claim it finds gone
(a cancel on another node, or a rescue). The worker process gets `shutdown`,
and `kill` five seconds later if it traps exits and has not gone. Nothing is
written for a stopped run.

A job from a fanout queue is run without a claim, by every node. Its row is not
this node's to change, so the executor writes nothing for it: the outcome goes
to telemetry only and the row stays `available` for the other nodes.

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

-export([start_link/3, start_link/4, execute_sync/3, run_perform/4, running/1, stop/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    job :: map(),
    pool :: atom(),
    queue_pid :: pid(),
    run :: run()
}).

-doc """
How a job is being run: `claimed` by a queue, `drained` in the calling process,
or `fanout`, where every node runs it and none owns the row.
""".
-type run() :: claimed | drained | fanout.

%% Who is waiting for perform/1: an executor process, which links to the worker
%% and can be told to stop it; the caller of a drain; or a testing helper,
%% which is handed an exception as an error instead of having it raised.
-type caller() :: {executor, Supervisor :: pid() | undefined} | drain | helper.

-type outcome() ::
    {completed, term()}
    | {snooze, pos_integer()}
    | {snoozed, pos_integer()}
    | {failed, Stored :: term(), Reported :: term()}
    | {stopped, term()}.

-doc false.
start_link(Job, Pool, QueuePid) ->
    start_link(Job, Pool, QueuePid, claimed).

-doc false.
-spec start_link(map(), atom(), pid(), claimed | fanout) -> gen_server:start_ret().
start_link(Job, Pool, QueuePid, Run) ->
    gen_server:start_link(?MODULE, {Job, Pool, QueuePid, Run}, []).

-doc """
Execute a claimed job in the calling process (for `shigoto:drain_queue/1,2`).

Answers what the job did when that was recorded: `ok`, `{snooze, Seconds}` or
`{error, Reason}`. When the outcome could not be recorded it answers why
instead: `{error, lost}` when the claim no longer held, or the database error.
""".
-spec execute_sync(map(), atom(), timeout()) -> ok | {snooze, pos_integer()} | {error, term()}.
execute_sync(Job, Pool, Timeout) ->
    executed(Job, Pool, Timeout, drained).

-doc "The executor processes running a job on this node.".
-spec running(integer()) -> [pid()].
running(JobId) ->
    case ets:whereis(shigoto_executors) of
        undefined -> [];
        _Table -> [Pid || {_Claim, Pid} <- executors_of(JobId), is_pid(Pid)]
    end.

executors_of(JobId) ->
    ets:match_object(shigoto_executors, {{JobId, '_'}, '_'}).

-doc """
Stop a run before it finishes: its worker process is shut down and nothing is
written for it. `Why` is `cancelled`, or `lost` when the run's claim no longer
holds. A run that has already finished is not affected.
""".
-spec stop(pid(), cancelled | lost) -> ok.
stop(Executor, Why) ->
    Executor ! {stop_job, Why},
    ok.

-doc false.
init({Job, Pool, QueuePid, Run}) ->
    process_flag(trap_exit, true),
    ok = shigoto_db:ignore_sandbox(),
    ets:insert(shigoto_executors, {registered_as(Job, Run), self()}),
    gen_server:cast(self(), execute),
    {ok, #state{job = Job, pool = Pool, queue_pid = QueuePid, run = Run}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(execute, #state{job = Job, pool = Pool, queue_pid = QueuePid, run = Run} = State) ->
    _ = executed(Job, Pool, worker_timeout, Run),
    gen_server:cast(QueuePid, {job_finished, maps:get(id, Job), self()}),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{job = Job, run = Run}) ->
    ets:delete(shigoto_executors, registered_as(Job, Run)),
    ok.

%% A job that is rescued and claimed again while its first run is still going
%% has two executors for a while; the attempt tells them apart. A fanout run
%% holds no claim, which also keeps it out of the heartbeat.
registered_as(Job, claimed) ->
    {maps:get(id, Job), maps:get(attempt, Job, 0)};
registered_as(Job, fanout) ->
    {maps:get(id, Job), fanout}.

%%----------------------------------------------------------------------
%% Internal: run, then record
%%----------------------------------------------------------------------

-spec executed(map(), atom(), timeout() | worker_timeout, run()) ->
    ok | {snooze, pos_integer()} | {error, term()}.
executed(Job, Pool, Timeout, Run) ->
    case worker_of(Job) of
        {ok, Worker} -> performed_by(Worker, Job, Pool, Timeout, Run);
        {error, Reason} -> unrunnable(Reason, Job, Pool, Run)
    end.

%% The job names a module this node cannot run: one that does not exist here,
%% or has no perform/1. It fails like any other attempt, so it is retried (a
%% node on a newer release may have the worker) and then discarded, instead of
%% crashing the executor and leaving the row to be rescued over and over.
unrunnable(Reason, Job, Pool, Run) ->
    ?LOG_ERROR(#{
        msg => ~"shigoto_job_unknown_worker",
        job_id => maps:get(id, Job, undefined),
        worker => maps:get(worker, Job, undefined),
        queue => maps:get(queue, Job, undefined),
        attempt => maps:get(attempt, Job, undefined)
    }),
    concluded(Run, {failed, Reason, Reason}, Job, Pool, undefined, 0).

performed_by(Worker, Job, Pool, Timeout, Run) ->
    set_logger_metadata(Job, Worker),
    T0 = erlang:monotonic_time(native),
    try
        Outcome = outcome(Job, Worker, Timeout, caller(Run)),
        Duration = erlang:monotonic_time(native) - T0,
        Answer = concluded(Run, Outcome, Job, Pool, Worker, Duration),
        ok = gates_told(Outcome, Job, Worker, Duration, Run),
        Answer
    after
        shigoto_resilience:release_bulkhead(Worker),
        clear_logger_metadata()
    end.

caller(drained) -> drain;
caller(_Queued) -> {executor, supervisor()}.

%% The executor supervisor, whose exit signal at shutdown has to reach the
%% worker. gen_server finds its parent the same way.
-spec supervisor() -> pid() | undefined.
supervisor() ->
    case get('$ancestors') of
        [Pid | _] when is_pid(Pid) -> Pid;
        [Name | _] when is_atom(Name) -> registered_process(Name);
        _ -> undefined
    end.

registered_process(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

-spec outcome(map(), module(), timeout() | worker_timeout, caller()) -> outcome().
outcome(Job, Worker, Timeout, Caller) ->
    try
        returned(
            run_with_resilience(
                Job, Worker, resolve_args(Job), timeout_of(Timeout, Worker), Caller
            )
        )
    catch
        throw:{?MODULE, stopped, Why} -> {stopped, Why};
        Class:Reason:Stack -> {failed, {Class, Reason, Stack}, {Class, Reason}}
    end.

%% Called inside the try, so a perform/1 that returns something else fails the
%% job with function_clause instead of taking the executor down.
returned(ok) -> {completed, null};
returned({ok, Result}) -> {completed, Result};
returned({snooze, Seconds}) -> {snooze, Seconds};
returned({snoozed, Seconds}) -> {snoozed, Seconds};
returned({error, Reason}) -> {failed, Reason, Reason}.

timeout_of(worker_timeout, Worker) -> resolve_timeout(Worker);
timeout_of(Timeout, _Worker) -> Timeout.

-spec concluded(run(), outcome(), map(), atom(), module() | undefined, integer()) ->
    ok | {snooze, pos_integer()} | {error, term()}.
concluded(_Run, {stopped, Why}, Job, _Pool, _Worker, _Duration) ->
    ?LOG_NOTICE(#{
        msg => ~"shigoto_job_stopped",
        why => Why,
        job_id => maps:get(id, Job, undefined),
        attempt => maps:get(attempt, Job, undefined)
    }),
    _ = stop_reported(Why, Job),
    {error, {stopped, Why}};
concluded(fanout, Outcome, Job, _Pool, _Worker, Duration) ->
    announced(Outcome, Job, Duration);
concluded(_Claimed, Outcome, Job, Pool, Worker, Duration) ->
    recorded(Outcome, Job, Pool, Worker, Duration).

stop_reported(lost, Job) -> shigoto_telemetry:job_lost(Job, stopped);
stop_reported(_Why, _Job) -> ok.

-spec announced(outcome(), map(), integer()) -> ok | {snooze, pos_integer()} | {error, term()}.
announced({completed, _Result}, Job, Duration) ->
    _ = shigoto_telemetry:job_completed(Job, Duration),
    ok;
announced({failed, _Stored, Reported}, Job, Duration) ->
    _ = shigoto_telemetry:job_failed(Job, Reported, Duration),
    {error, Reported};
announced({snooze, Seconds}, Job, _Duration) ->
    _ = shigoto_telemetry:job_snoozed(Job, ~"snooze"),
    {snooze, Seconds};
announced({snoozed, Seconds}, Job, _Duration) ->
    _ = shigoto_telemetry:job_snoozed(Job, ~"snooze"),
    {snooze, Seconds}.

-spec recorded(outcome(), map(), atom(), module() | undefined, integer()) ->
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
-spec gates_told(outcome(), map(), module(), integer(), run()) -> ok.
gates_told({completed, _Result}, Job, Worker, Duration, Run) ->
    _ = shigoto_resilience:complete_load(Job, milliseconds(Duration)),
    breaker_told(Run, Worker, ok);
gates_told({failed, _Stored, _Reported}, Job, Worker, Duration, Run) ->
    _ = shigoto_resilience:complete_load(Job, milliseconds(Duration)),
    breaker_told(Run, Worker, {error, job_failed});
gates_told({stopped, _Why}, Job, _Worker, Duration, _Run) ->
    _ = shigoto_resilience:complete_load(Job, milliseconds(Duration)),
    ok;
gates_told(_Snoozed, _Job, _Worker, _Duration, _Run) ->
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

run_with_resilience(Job, Worker, Args, Timeout, Caller) ->
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
                                                Job, Worker, Args, Timeout, Caller
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
    run_middleware_chain(Job, Worker, Args, Timeout, helper).

run_middleware_chain(Job, Worker, Args, Timeout, Caller) ->
    %% Pass decoded args in the job map so middleware sees maps, not binaries.
    %% For dependent jobs, expose the predecessors' results under deps_results.
    PerformArgs = inject_deps_results(Args, Job),
    JobWithArgs = Job#{args => PerformArgs},
    PerformFn = fun(_JobArg) ->
        performed(apply_with_timeout(Worker, perform, [PerformArgs], Timeout, Caller), Caller)
    end,
    shigoto_middleware:run(JobWithArgs, Worker, PerformFn).

%% perform/1 runs in a process of its own. For the executor an exception there
%% is raised again here, so middleware and the executor see it as if perform/1
%% had run inline, with the worker's stacktrace. The testing helpers get it as
%% the exit reason the worker process would have died with. A stopped run
%% unwinds the middleware chain with a throw the executor catches.
performed({returned, Result}, _Caller) ->
    Result;
performed({stopped, Why}, _Caller) ->
    throw({?MODULE, stopped, Why});
performed({raised, error, Reason, Stack}, helper) ->
    {error, {Reason, Stack}};
performed({raised, throw, Thrown, Stack}, helper) ->
    {error, {{nocatch, Thrown}, Stack}};
performed({raised, exit, Reason, _Stack}, helper) ->
    {error, Reason};
performed({raised, Class, Reason, Stack}, _Caller) ->
    erlang:raise(Class, Reason, Stack).

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

breaker_told(drained, _Worker, _Result) ->
    ok;
breaker_told(_Queued, Worker, Result) ->
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

compute_backoff(undefined, Job, _Error) ->
    default_backoff(maps:get(attempt, Job, 1));
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

-spec worker_of(map()) -> {ok, module()} | {error, {unknown_worker, binary()}}.
worker_of(#{worker := Worker}) when is_atom(Worker) ->
    runnable(Worker);
worker_of(#{worker := Name}) when is_binary(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Worker -> runnable(Worker)
    catch
        error:badarg -> {error, {unknown_worker, Name}}
    end.

runnable(Worker) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, perform, 1) of
        true -> {ok, Worker};
        false -> {error, {unknown_worker, atom_to_binary(Worker)}}
    end.

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

-spec apply_with_timeout(module(), atom(), [term()], timeout(), caller()) ->
    {returned, term()}
    | {raised, error | exit | throw, term(), list()}
    | {stopped, term()}.
apply_with_timeout(Module, Function, Args, Timeout, {executor, Supervisor}) ->
    receive
        {stop_job, Why} -> {stopped, Why}
    after 0 ->
        {Pid, Ref} = spawn_worker(Module, Function, Args, [link, monitor]),
        Applied =
            receive
                {Pid, Result} ->
                    erlang:demonitor(Ref, [flush]),
                    Result;
                {'DOWN', Ref, process, Pid, Reason} ->
                    {returned, {error, Reason}};
                {stop_job, Why} ->
                    ok = stop_worker(Pid, Ref),
                    {stopped, Why};
                {'EXIT', Supervisor, Reason} ->
                    ok = stop_worker(Pid, Ref),
                    {stopped, Reason}
            after Timeout ->
                ok = stop_worker(Pid, Ref),
                {returned, {error, timeout}}
            end,
        ok = unlinked(Pid),
        Applied
    end;
apply_with_timeout(Module, Function, Args, Timeout, _Caller) ->
    {Pid, Ref} = spawn_worker(Module, Function, Args, [monitor]),
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            {returned, {error, Reason}}
    after Timeout ->
        ok = stop_worker(Pid, Ref),
        {returned, {error, timeout}}
    end.

spawn_worker(Module, Function, Args, Options) ->
    Self = self(),
    Metadata = logger:get_process_metadata(),
    IgnoresSandbox = shigoto_db:ignores_sandbox(),
    spawn_opt(
        fun() ->
            ok = inherit_sandbox_scope(IgnoresSandbox),
            inherit_logger_metadata(Metadata),
            Self ! {self(), applied(Module, Function, Args)}
        end,
        Options
    ).

applied(Module, Function, Args) ->
    try
        {returned, apply(Module, Function, Args)}
    catch
        Class:Reason:Stack -> {raised, Class, Reason, Stack}
    end.

inherit_sandbox_scope(true) -> shigoto_db:ignore_sandbox();
inherit_sandbox_scope(false) -> ok.

%% Shutdown first, so a worker that traps exits can clean up; kill if it has
%% not gone five seconds later.
-spec stop_worker(pid(), reference()) -> ok.
stop_worker(Pid, Ref) ->
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 5000 ->
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 1000 -> ok
        end,
        erlang:demonitor(Ref, [flush]),
        ok
    end.

%% The executor traps exits, so the worker's own exit arrives as a message.
unlinked(Pid) ->
    unlink(Pid),
    receive
        {'EXIT', Pid, _Reason} -> ok
    after 0 -> ok
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
