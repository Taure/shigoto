-module(shigoto_snooze_worker).
-behaviour(shigoto_worker).

-export([perform/1]).

perform(_Args) ->
    {snooze, 60}.
