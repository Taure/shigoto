-module(shigoto_executor_sup).
-moduledoc ~"""
Dynamic supervisor for job executor processes.
""".
-behaviour(supervisor).

-export([start_link/0, start_executor/3, start_fanout_executor/3]).
-export([init/1]).

-doc false.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Start a new executor process for a claimed job.".
-spec start_executor(map(), atom(), pid()) -> {ok, pid()} | {error, term()}.
start_executor(Job, Pool, QueuePid) ->
    started(supervisor:start_child(?MODULE, [Job, Pool, QueuePid, claimed])).

-doc """
Start an executor for a job read from a fanout queue. The job is not claimed,
so the executor runs it and leaves its row alone.
""".
-spec start_fanout_executor(map(), atom(), pid()) -> {ok, pid()} | {error, term()}.
start_fanout_executor(Job, Pool, QueuePid) ->
    started(supervisor:start_child(?MODULE, [Job, Pool, QueuePid, fanout])).

-spec started(supervisor:startchild_ret()) -> {ok, pid()} | {error, term()}.
started({ok, Pid}) when is_pid(Pid) -> {ok, Pid};
started({ok, Pid, _Info}) when is_pid(Pid) -> {ok, Pid};
started({ok, _NoProcess}) -> {error, not_started};
started({ok, _NoProcess, _Info}) -> {error, not_started};
started({error, _} = Error) -> Error.

-doc false.
init([]) ->
    _ =
        case ets:whereis(shigoto_executors) of
            undefined ->
                ets:new(shigoto_executors, [named_table, public, {read_concurrency, true}]);
            _ ->
                ok
        end,
    ok = shigoto_resilience:new_table(),
    ChildSpec = #{
        id => shigoto_executor,
        start => {shigoto_executor, start_link, []},
        restart => temporary,
        type => worker
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [ChildSpec]}}.
