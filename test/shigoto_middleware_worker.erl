-module(shigoto_middleware_worker).
-behaviour(shigoto_worker).
-export([perform/1, middleware/0]).

perform(#{<<"test_pid">> := PidBin}) ->
    Pid = list_to_pid(binary_to_list(PidBin)),
    Pid ! {performed, self()},
    ok;
perform(_Args) ->
    ok.

middleware() ->
    [fun tracking_middleware/2].

tracking_middleware(Job, Next) ->
    Args = maps:get(args, Job, #{}),
    case maps:get(<<"test_pid">>, Args, undefined) of
        undefined ->
            ok;
        PidBin ->
            Pid = list_to_pid(binary_to_list(PidBin)),
            Pid ! {middleware_before, self()}
    end,
    Result = Next(),
    case maps:get(<<"test_pid">>, Args, undefined) of
        undefined ->
            ok;
        PidBin2 ->
            Pid2 = list_to_pid(binary_to_list(PidBin2)),
            Pid2 ! {middleware_after, self()}
    end,
    Result.
