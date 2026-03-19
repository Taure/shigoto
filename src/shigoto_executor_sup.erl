-module(shigoto_executor_sup).
-moduledoc ~"""
Dynamic supervisor for job executor processes.
""".
-behaviour(supervisor).

-export([start_link/0, start_executor/3]).
-export([init/1]).

-doc false.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Start a new executor process for a job.".
-spec start_executor(map(), module(), pid()) -> {ok, pid()} | {error, term()}.
start_executor(Job, RepoMod, QueuePid) ->
    supervisor:start_child(?MODULE, [Job, RepoMod, QueuePid]).

-doc false.
init([]) ->
    _ =
        case ets:whereis(shigoto_executors) of
            undefined ->
                ets:new(shigoto_executors, [named_table, public, {read_concurrency, true}]);
            _ ->
                ok
        end,
    ChildSpec = #{
        id => shigoto_executor,
        start => {shigoto_executor, start_link, []},
        restart => temporary,
        type => worker
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [ChildSpec]}}.
