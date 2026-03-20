-module(shigoto_backoff_worker).
-behaviour(shigoto_worker).
-export([perform/1, backoff/2]).

perform(#{<<"action">> := <<"fail">>}) -> {error, deliberate};
perform(_Args) -> ok.

backoff(Attempt, _Error) ->
    %% Linear backoff: 10s per attempt, max 60s
    min(Attempt * 10, 60).
