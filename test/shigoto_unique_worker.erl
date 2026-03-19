-module(shigoto_unique_worker).
-behaviour(shigoto_worker).

-export([perform/1, unique/0]).

unique() ->
    #{period => 300, keys => [worker, args], states => [available, executing, retryable]}.

perform(_Args) ->
    ok.
