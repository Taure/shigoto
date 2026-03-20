-module(shigoto_heartbeat).
-moduledoc """
Heartbeat system for executing jobs. Periodically updates `heartbeat_at`
for all in-flight jobs on this node, enabling faster stale job detection.

Without heartbeat, stale jobs are detected after 5 minutes. With heartbeat,
a job is considered stale if its heartbeat is older than 2x the heartbeat
interval (default: 60 seconds).
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
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
        _ ->
            JobIds = [Id || {Id, _Pid} <- ets:tab2list(shigoto_executors)],
            case JobIds of
                [] ->
                    ok;
                _ ->
                    Pool = shigoto_config:pool(),
                    Placeholders = placeholders(length(JobIds)),
                    SQL = iolist_to_binary([
                        <<"UPDATE shigoto_jobs SET heartbeat_at = now() WHERE id IN (">>,
                        Placeholders,
                        <<")">>
                    ]),
                    _ = pgo:query(SQL, JobIds, #{pool => Pool, decode_opts => ?DECODE_OPTS}),
                    ok
            end
    end.

placeholders(N) ->
    lists:join(<<", ">>, [
        iolist_to_binary([<<"$">>, integer_to_binary(I)])
     || I <- lists:seq(1, N)
    ]).
