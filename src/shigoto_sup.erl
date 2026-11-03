-module(shigoto_sup).
-moduledoc """
Top-level supervisor for Shigoto. Starts the queue supervisor, cron
scheduler, pruner, heartbeat, and optional LISTEN/NOTIFY notifier
plus its due-job stager.

When the schema is not current at boot, `shigoto_migrator` also runs, and the
queue supervisor starts with no queues until the migration succeeds. The
migrator starts after the queue supervisor, so it stops before it at shutdown
and a retry never adds queues to a supervisor that is stopping.
""".
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-doc false.
start_link(Migrated) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Migrated).

migrator(true) ->
    [];
migrator(false) ->
    [
        #{
            id => shigoto_migrator,
            start => {shigoto_migrator, start_link, []},
            restart => transient,
            type => worker
        }
    ].

-doc false.
init(Migrated) ->
    BaseChildren =
        [
            #{
                id => shigoto_executor_sup,
                start => {shigoto_executor_sup, start_link, []},
                type => supervisor
            },
            #{
                id => shigoto_queue_sup,
                start => {shigoto_queue_sup, start_link, [shigoto_config:queues()]},
                type => supervisor
            }
        ] ++
            migrator(Migrated) ++
            [
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
