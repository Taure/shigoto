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
names the setting, never a key. With a key configured it logs, once per boot,
`shigoto_encryption_write_format_v1` while `encryption_write_format` is set to
`v1`, and `shigoto_plaintext_jobs_accepted` while `require_encrypted` is not
set.

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
            _ = shigoto_config:on_dependency_failure(),
            _ = shigoto_db:kura_available(),
            ok = shigoto_db:ignore_sandbox(),
            shigoto_sup:start_link(shigoto_migrator:boot(shigoto_config:pool()));
        {error, Reason} ->
            {error, Reason}
    end.

%% Once per boot, and only with a key configured: `v1` set for a rolling
%% upgrade and not yet removed, and plaintext rows still being accepted.
warn_about_encryption() ->
    case shigoto_crypto:is_enabled() of
        false ->
            ok;
        true ->
            warn_if_v1(shigoto_config:encryption_write_format()),
            warn_if_plaintext_accepted(shigoto_config:require_encrypted())
    end.

warn_if_v1(v2) ->
    ok;
warn_if_v1(v1) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_encryption_write_format_v1",
        warning =>
            ~"v1 ciphertext is not bound to its row: someone who can write to the jobs table can move it to another job or column and have it decrypted there. Job results and batch callback args are not encrypted in v1.",
        action =>
            ~"once every node runs this release, remove {encryption_write_format, v1} and run shigoto:reencrypt/0"
    }).

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
