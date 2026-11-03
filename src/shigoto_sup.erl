-module(shigoto_sup).
-moduledoc """
Top-level supervisor for Shigoto. Starts the queue supervisor, cron
scheduler, pruner, heartbeat, and optional LISTEN/NOTIFY notifier
plus its due-job stager.

When the schema is not current at boot, `shigoto_migrator` takes the queue
supervisor's place and starts it once the migration succeeds.
""".
-behaviour(supervisor).

-export([start_link/1, start_queues/0]).
-export([init/1]).

-doc false.
start_link(Migrated) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Migrated).

-doc false.
-spec start_queues() -> ok.
start_queues() ->
    case supervisor:start_child(?MODULE, queue_sup()) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

queue_sup() ->
    #{
        id => shigoto_queue_sup,
        start => {shigoto_queue_sup, start_link, [shigoto_config:queues()]},
        type => supervisor
    }.

queues_or_migrator(true) ->
    queue_sup();
queues_or_migrator(false) ->
    #{
        id => shigoto_migrator,
        start => {shigoto_migrator, start_link, []},
        restart => transient,
        type => worker
    }.

-doc false.
init(Migrated) ->
    BaseChildren = [
        #{
            id => shigoto_executor_sup,
            start => {shigoto_executor_sup, start_link, []},
            type => supervisor
        },
        queues_or_migrator(Migrated),
        #{
            id => shigoto_cron,
            start => {shigoto_cron, start_link, []},
            type => worker
        },
        #{
            id => shigoto_pruner,
            start => {shigoto_pruner, start_link, []},
            type => worker
        },
        #{
            id => shigoto_heartbeat,
            start => {shigoto_heartbeat, start_link, []},
            type => worker
        }
    ],
    Children0 =
        case shigoto_config:notifier_config() of
            undefined ->
                BaseChildren;
            _ ->
                BaseChildren ++
                    [
                        #{
                            id => shigoto_notifier,
                            start => {shigoto_notifier, start_link, []},
                            type => worker
                        },
                        #{
                            id => shigoto_stager,
                            start => {shigoto_stager, start_link, []},
                            type => worker
                        }
                    ]
        end,
    %% Set up load shedder if configured
    _ = shigoto_resilience:setup_load_shedder(),
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children0}}.
