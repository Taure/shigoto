-module(shigoto_timeout_worker).
-behaviour(shigoto_worker).

-export([perform/1, timeout/0]).

timeout() -> 500.

perform(_Args) ->
    timer:sleep(5000),
    ok.
