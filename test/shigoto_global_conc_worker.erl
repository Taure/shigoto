-module(shigoto_global_conc_worker).
-behaviour(shigoto_worker).

-export([perform/1, global_concurrency/0]).

perform(_Args) ->
    ok.

global_concurrency() ->
    1.
