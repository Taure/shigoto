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
    _ = shigoto_db:kura_available(),
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
