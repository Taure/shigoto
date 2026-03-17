-module(shigoto_executor).
-moduledoc ~"""
Executes a single job. Started by the executor supervisor, reports
back to the queue process when done.
""".
-behaviour(gen_server).

-export([start_link/3, execute_sync/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    job :: map(),
    repo :: module(),
    queue_pid :: pid()
}).

-doc false.
start_link(Job, RepoMod, QueuePid) ->
    gen_server:start_link(?MODULE, {Job, RepoMod, QueuePid}, []).

-doc "Execute a job synchronously (for drain_queue).".
-spec execute_sync(map(), module(), timeout()) -> ok | {error, term()}.
execute_sync(Job, RepoMod, Timeout) ->
    Worker = resolve_worker(Job),
    Args = resolve_args(Job),
    JobId = maps:get(id, Job),
    try
        case apply_with_timeout(Worker, perform, [Args], Timeout) of
            ok ->
                shigoto_repo:complete_job(RepoMod, JobId),
                shigoto_telemetry:job_completed(Job),
                ok;
            {error, FailReason} ->
                shigoto_repo:fail_job(RepoMod, JobId, FailReason),
                shigoto_telemetry:job_failed(Job, FailReason),
                {error, FailReason}
        end
    catch
        Class:CatchReason:_Stack ->
            shigoto_repo:fail_job(RepoMod, JobId, {Class, CatchReason}),
            shigoto_telemetry:job_failed(Job, {Class, CatchReason}),
            {error, {Class, CatchReason}}
    end.

-doc false.
init({Job, RepoMod, QueuePid}) ->
    gen_server:cast(self(), execute),
    {ok, #state{job = Job, repo = RepoMod, queue_pid = QueuePid}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(execute, #state{job = Job, repo = RepoMod, queue_pid = QueuePid} = State) ->
    Worker = resolve_worker(Job),
    Args = resolve_args(Job),
    JobId = maps:get(id, Job),
    try Worker:perform(Args) of
        ok ->
            shigoto_repo:complete_job(RepoMod, JobId),
            shigoto_telemetry:job_completed(Job),
            gen_server:cast(QueuePid, {job_finished, JobId}),
            {stop, normal, State};
        {error, Reason} ->
            shigoto_repo:fail_job(RepoMod, JobId, Reason),
            shigoto_telemetry:job_failed(Job, Reason),
            gen_server:cast(QueuePid, {job_finished, JobId}),
            {stop, normal, State}
    catch
        Class:Reason:_Stack ->
            shigoto_repo:fail_job(RepoMod, JobId, {Class, Reason}),
            shigoto_telemetry:job_failed(Job, {Class, Reason}),
            gen_server:cast(QueuePid, {job_finished, JobId}),
            {stop, normal, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

resolve_worker(#{worker := Worker}) when is_atom(Worker) ->
    Worker;
resolve_worker(#{worker := Worker}) when is_binary(Worker) ->
    binary_to_existing_atom(Worker, utf8).

resolve_args(#{args := Args}) when is_map(Args) ->
    Args;
resolve_args(#{args := Args}) when is_binary(Args) ->
    try json:decode(Args)
    catch _:_ -> #{}
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
