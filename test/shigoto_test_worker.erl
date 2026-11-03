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
perform(#{<<"action">> := <<"report_metadata">>, <<"to">> := To}) ->
    binary_to_existing_atom(To) ! {logger_metadata, logger:get_process_metadata()},
    ok;
perform(_Args) ->
    ok.
