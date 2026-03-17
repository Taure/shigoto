-module(shigoto_sup).
-moduledoc ~"""
Top-level supervisor for Shigoto. Starts the queue supervisor, cron
scheduler, pruner, and optional LISTEN/NOTIFY notifier.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-doc false.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    Queues = shigoto_config:queues(),
    Children = [
        #{
            id => shigoto_executor_sup,
            start => {shigoto_executor_sup, start_link, []},
            type => supervisor
        },
        #{
            id => shigoto_queue_sup,
            start => {shigoto_queue_sup, start_link, [Queues]},
            type => supervisor
        },
        #{
            id => shigoto_cron,
            start => {shigoto_cron, start_link, []},
            type => worker
        },
        #{
            id => shigoto_pruner,
            start => {shigoto_pruner, start_link, []},
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
