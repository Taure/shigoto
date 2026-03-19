-module(shigoto_unique_queue_worker).
-behaviour(shigoto_worker).

-export([perform/1, unique/0]).

unique() ->
    #{keys => [worker, queue], states => [available]}.

perform(_Args) ->
    ok.
