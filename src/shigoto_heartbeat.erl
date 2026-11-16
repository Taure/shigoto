-module(shigoto_heartbeat).
-moduledoc """
Heartbeat for executing jobs. Every `heartbeat_interval` it updates
`heartbeat_at` for the jobs this node is running, which is what keeps the
stale-job rescue (`shigoto_repo:rescue_stale_jobs/2`) away from them. A job is
stale once it has gone twice the heartbeat interval without one (60 seconds by
default); claiming a job counts as its first.

A heartbeat is written under the claim the job is running under, so a run whose
job has since been rescued and claimed again, or cancelled, does not keep the
row alive. Such a run is stopped: this is how a
`shigoto:cancel/1,2` made on another node reaches a job running here, within
one heartbeat interval.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    ok = shigoto_db:ignore_sandbox(),
    Interval = shigoto_config:heartbeat_interval(),
    erlang:send_after(Interval, self(), heartbeat),
    {ok, #{interval => Interval}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(heartbeat, #{interval := Interval} = State) ->
    update_heartbeats(),
    erlang:send_after(Interval, self(), heartbeat),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

update_heartbeats() ->
    case ets:whereis(shigoto_executors) of
        undefined ->
            ok;
        _Table ->
            Running = ets:tab2list(shigoto_executors),
            Alive = [{Claim, Pid} || {Claim, Pid} <- Running, is_pid(Pid), is_process_alive(Pid)],
            ok = forget(Running -- Alive),
            %% A fanout run holds no claim: its key is {JobId, fanout}.
            Claimed = [
                {{JobId, Attempt}, Pid}
             || {{JobId, Attempt}, Pid} <- Alive, is_integer(JobId), is_integer(Attempt)
            ],
            Claims = [Claim || {Claim, _Pid} <- Claimed],
            case shigoto_repo:heartbeat(shigoto_config:pool(), Claims) of
                {ok, Held} -> stop_lost(Claimed, Claims -- Held);
                {error, _} -> ok
            end
    end.

%% A claim the heartbeat did not find was cancelled on another node, or
%% rescued. Nothing this run does can be recorded any more, so it is stopped.
-spec stop_lost([{{integer(), integer()}, pid()}], [{integer(), integer()}]) -> ok.
stop_lost(Claimed, Lost) ->
    _ = [shigoto_executor:stop(Pid, lost) || {Claim, Pid} <- Claimed, lists:member(Claim, Lost)],
    ok.

%% An executor that was killed never took its own entry out. Left in, its job
%% would be kept alive by heartbeats nobody is running it for.
forget(Dead) ->
    _ = [ets:delete_object(shigoto_executors, Entry) || {_Claim, _Pid} = Entry <- Dead],
    ok.
