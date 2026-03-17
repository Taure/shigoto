-module(shigoto_app).
-moduledoc ~"""
OTP application callback for Shigoto.
""".
-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_StartType, _StartArgs) ->
    shigoto_sup:start_link().

-doc false.
stop(_State) ->
    ok.
