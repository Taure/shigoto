-module(shigoto_global_conc2_worker).
-behaviour(shigoto_worker).

-export([perform/1, global_concurrency/0]).

perform(_Args) ->
    ok.

global_concurrency() ->
    2.
