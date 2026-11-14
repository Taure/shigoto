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

Before any of that it checks the settings that are dangerous to get wrong
(`shigoto_config:check/0`): an encryption key that is not 32 bytes or is
listed twice, an unknown `encryption_write_format`, a malformed `instance` or
`workers`. The application does not start with one of those, and the reason
names the setting, never a key. Once per boot it logs
`shigoto_plaintext_jobs_accepted` while a key is configured and
`require_encrypted` is not set, and `shigoto_shutdown_cut_short` when
`kernel`'s `shutdown_timeout` is shorter than shigoto needs to stop
(`shigoto_config:shutdown_budget/0`).

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
    case shigoto_config:check() of
        ok ->
            warn_if_testing_mode(),
            warn_about_encryption(),
            warn_if_shutdown_is_cut_short(),
            _ = shigoto_config:on_dependency_failure(),
            _ = shigoto_db:kura_available(),
            ok = shigoto_db:ignore_sandbox(),
            shigoto_sup:start_link(shigoto_migrator:boot(shigoto_config:pool()));
        {error, Reason} ->
            {error, Reason}
    end.

%% Once per boot, and only with a key configured: plaintext rows still being
%% accepted.
warn_about_encryption() ->
    case shigoto_crypto:is_enabled() of
        false -> ok;
        true -> warn_if_plaintext_accepted(shigoto_config:require_encrypted())
    end.

warn_if_plaintext_accepted(true) ->
    ok;
warn_if_plaintext_accepted(false) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_plaintext_jobs_accepted",
        warning =>
            ~"a job row with plaintext args is run although an encryption key is configured, so someone who can write to the jobs table can enqueue a job without the key",
        action =>
            ~"once shigoto:reencrypt/0 reports no plaintext left, set {require_encrypted, true}"
    }).

%% The node gives an application `kernel`'s `shutdown_timeout` to stop
%% (`infinity` unless set) and kills it after that.
warn_if_shutdown_is_cut_short() ->
    Budget = shigoto_config:shutdown_budget(),
    case application:get_env(kernel, shutdown_timeout) of
        {ok, Allowed} when is_integer(Allowed), Allowed < Budget ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_shutdown_cut_short",
                kernel_shutdown_timeout => Allowed,
                needed => Budget,
                warning =>
                    ~"the node kills shigoto before its queues have waited shutdown_timeout for their jobs: a job cut off that way is not given back, and one on its last attempt is discarded by the rescue",
                action =>
                    ~"raise kernel's shutdown_timeout to at least `needed`, or lower shigoto's shutdown_timeout"
            });
        _ ->
            ok
    end.

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
