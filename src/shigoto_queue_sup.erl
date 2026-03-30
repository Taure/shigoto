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
    ShutdownMs = shigoto_config:shutdown_timeout() + 1000,
    FanoutQueues = shigoto_config:fanout_queues(),
    StandardChildren = [
        #{
            id => {shigoto_queue, Queue},
            start => {shigoto_queue, start_link, [Queue, Concurrency]},
            type => worker,
            shutdown => ShutdownMs
        }
     || {Queue, Concurrency} <- Queues
    ],
    FanoutChildren = [
        #{
            id => {shigoto_fanout_queue, Queue},
            start => {shigoto_fanout_queue, start_link, [Queue, Concurrency, Opts]},
            type => worker,
            shutdown => ShutdownMs
        }
     || {Queue, Concurrency, Opts} <- FanoutQueues
    ],
    Children = StandardChildren ++ FanoutChildren,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
