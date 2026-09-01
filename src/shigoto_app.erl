-module(shigoto_app).
-moduledoc ~"""
OTP application callback for Shigoto.
""".
-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    warn_if_testing_mode(),
    warn_if_unkeyed_digests_accepted(),
    ok = shigoto_migration:up(shigoto_config:pool()),
    shigoto_sup:start_link().

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

warn_if_unkeyed_digests_accepted() ->
    case shigoto_config:accept_unkeyed_unique_digests() andalso shigoto_crypto:is_enabled() of
        false ->
            ok;
        true ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_unkeyed_unique_digests_accepted",
                warning =>
                    ~"unique_key lookups match the unkeyed digest, which is forgeable without the encryption key; intended for one drain cycle when adopting encryption, not as a standing setting"
            })
    end.

-doc false.
stop(_State) ->
    ok.
