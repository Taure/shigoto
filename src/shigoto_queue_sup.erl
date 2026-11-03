-module(shigoto_queue_sup).
-moduledoc ~"""
Supervisor for per-queue polling processes.

It always runs. While `shigoto_migrator` holds the queues back it starts with
no children, and the migrator adds the configured queues (built by
`child_specs/1`, as at a normal boot) once the schema is current.
""".
-behaviour(supervisor).

-export([start_link/1, child_specs/1, queue_spec/2]).
-export([init/1]).

-doc false.
start_link(Queues) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Queues).

-doc false.
-spec child_specs([{binary(), pos_integer()}]) -> [supervisor:child_spec()].
child_specs(Queues) ->
    ShutdownMs = shutdown_ms(),
    StandardChildren = [queue_spec(Queue, Concurrency) || {Queue, Concurrency} <- Queues],
    FanoutChildren = [
        #{
            id => {shigoto_fanout_queue, Queue},
            start => {shigoto_fanout_queue, start_link, [Queue, Concurrency, Opts]},
            type => worker,
            shutdown => ShutdownMs
        }
     || {Queue, Concurrency, Opts} <- shigoto_config:fanout_queues()
    ],
    StandardChildren ++ FanoutChildren.

-doc false.
-spec queue_spec(binary(), pos_integer()) -> supervisor:child_spec().
queue_spec(Queue, Concurrency) ->
    #{
        id => {shigoto_queue, Queue},
        start => {shigoto_queue, start_link, [Queue, Concurrency]},
        type => worker,
        shutdown => shutdown_ms()
    }.

shutdown_ms() ->
    shigoto_config:shutdown_timeout() + 1000.

-doc false.
init(Queues) ->
    Children =
        case shigoto_migrator:pending() of
            true -> [];
            false -> child_specs(Queues)
        end,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
