-module(shigoto_app).
-moduledoc ~"""
OTP application callback for Shigoto.

`start/2` migrates the schema (`shigoto_migrator:boot/1`) before it starts the
supervision tree, so it blocks the release's boot while it does. Worst case:

- about 45 seconds when the database is unreachable (5 attempts, with up to 20
  seconds of jittered sleeps between them), after which the application starts
  with its queues held back;
- plus however long another node holds the migration advisory lock, since
  nodes that boot together migrate one at a time.

An error a retry cannot fix (SQLSTATE class 42, such as
`42501 insufficient_privilege`) skips the sleeps. On Kubernetes, give the pod a
`startupProbe` (for example `failureThreshold: 30`, `periodSeconds: 5`) so the
liveness probe does not restart it during this window.
""".
-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    warn_if_testing_mode(),
    _ = shigoto_db:kura_available(),
    ok = shigoto_db:ignore_sandbox(),
    shigoto_sup:start_link(shigoto_migrator:boot(shigoto_config:pool())).

warn_if_testing_mode() ->
    case shigoto_config:testing_mode() of
        disabled ->
            ok;
        Mode ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_testing_mode_armed_at_boot",
                mode => Mode,
                warning =>
                    ~"inserts do not persist to the database; this must NOT be a production node"
            }),
            shigoto_telemetry:testing_mode_armed(Mode)
    end.

-doc false.
stop(_State) ->
    ok.
