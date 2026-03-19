-module(shigoto_executor).
-moduledoc ~"""
Executes a single job. Started by the executor supervisor, reports
back to the queue process when done.
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
    try
        case apply_with_timeout(Worker, perform, [Args], Timeout) of
            ok ->
                _ = shigoto_repo:complete_job(Pool, JobId),
                _ = shigoto_telemetry:job_completed(Job),
                ok;
            {snooze, Seconds} ->
                _ = shigoto_repo:snooze_job(Pool, JobId, Seconds),
                {snooze, Seconds};
            {error, FailReason} ->
                _ = shigoto_repo:fail_job(Pool, JobId, FailReason),
                _ = shigoto_telemetry:job_failed(Job, FailReason),
                {error, FailReason}
        end
    catch
        Class:CatchReason:_Stack ->
            _ = shigoto_repo:fail_job(Pool, JobId, {Class, CatchReason}),
            _ = shigoto_telemetry:job_failed(Job, {Class, CatchReason}),
            {error, {Class, CatchReason}}
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
    try
        case apply_with_timeout(Worker, perform, [Args], Timeout) of
            ok ->
                _ = shigoto_repo:complete_job(Pool, JobId),
                _ = shigoto_telemetry:job_completed(Job),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State};
            {snooze, Seconds} ->
                _ = shigoto_repo:snooze_job(Pool, JobId, Seconds),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State};
            {error, Reason} ->
                _ = shigoto_repo:fail_job(Pool, JobId, Reason),
                _ = shigoto_telemetry:job_failed(Job, Reason),
                gen_server:cast(QueuePid, {job_finished, JobId, self()}),
                {stop, normal, State}
        end
    catch
        Class:CatchReason:_Stack ->
            _ = shigoto_repo:fail_job(Pool, JobId, {Class, CatchReason}),
            _ = shigoto_telemetry:job_failed(Job, {Class, CatchReason}),
            gen_server:cast(QueuePid, {job_finished, JobId, self()}),
            {stop, normal, State}
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
%% Internal
%%----------------------------------------------------------------------

-define(DEFAULT_TIMEOUT, 300000).

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
