-module(shigoto_test_worker).
-behaviour(shigoto_worker).

-export([perform/1]).

perform(#{<<"action">> := <<"succeed">>}) ->
    ok;
perform(#{<<"action">> := <<"fail">>}) ->
    {error, deliberate_failure};
perform(#{<<"action">> := <<"crash">>}) ->
    error(deliberate_crash);
perform(#{<<"action">> := <<"slow">>}) ->
    timer:sleep(10000),
    ok;
perform(_Args) ->
    ok.
