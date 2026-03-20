-module(shigoto_discard_worker).
-behaviour(shigoto_worker).
-export([perform/1, max_attempts/0, on_discard/2]).

perform(_Args) -> {error, always_fails}.

max_attempts() -> 1.

on_discard(Args, _Errors) ->
    case maps:get(<<"notify_pid">>, Args, undefined) of
        undefined ->
            ok;
        PidBin ->
            Pid = list_to_pid(binary_to_list(PidBin)),
            Pid ! {discarded, Args}
    end,
    ok.
