-module(shigoto_app).
-moduledoc ~"""
OTP application callback for Shigoto.
""".
-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    ok = shigoto_migration:up(shigoto_config:pool()),
    shigoto_sup:start_link().

-doc false.
stop(_State) ->
    ok.
