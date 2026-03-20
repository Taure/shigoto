-module(shigoto_batch_callback_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(Args) ->
    case maps:get(<<"test_pid">>, Args, undefined) of
        undefined ->
            ok;
        PidBin ->
            Pid = list_to_pid(binary_to_list(PidBin)),
            Pid ! {batch_callback, Args}
    end,
    ok.
