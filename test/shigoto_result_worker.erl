-module(shigoto_result_worker).
-behaviour(shigoto_worker).

-export([perform/1]).

perform(#{~"action" := ~"produce", ~"value" := V}) ->
    {ok, #{~"produced" => V}};
perform(#{~"action" := ~"consume", deps_results := DepsResults}) ->
    [ParentResult] = maps:values(DepsResults),
    {ok, #{~"got" => ParentResult}};
perform(#{~"action" := ~"consume_keyed", ~"parent" := PId, deps_results := DepsResults}) ->
    #{PId := ParentResult} = DepsResults,
    {ok, #{~"got" => ParentResult}};
perform(#{~"action" := ~"consume_count", deps_results := DepsResults}) ->
    {ok, #{~"count" => map_size(DepsResults)}};
perform(#{~"action" := ~"plain_ok"}) ->
    ok.
