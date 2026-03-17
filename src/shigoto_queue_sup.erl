-module(shigoto_queue_sup).
-moduledoc ~"""
Supervisor for per-queue polling processes.
""".
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-doc false.
start_link(Queues) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Queues).

-doc false.
init(Queues) ->
    Children = [
        #{
            id => {shigoto_queue, Queue},
            start => {shigoto_queue, start_link, [Queue, Concurrency]},
            type => worker
        }
     || {Queue, Concurrency} <- Queues
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
