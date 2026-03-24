-module(shigoto_discard_worker).
-behaviour(shigoto_worker).
-export([perform/1, max_attempts/0, on_discard/2]).

perform(_Args) -> {error, always_fails}.

max_attempts() -> 1.

on_discard(Args, _Errors) ->
    case whereis(shigoto_discard_test) of
        undefined -> ok;
        Pid -> Pid ! {discarded, Args}
    end,
    ok.
