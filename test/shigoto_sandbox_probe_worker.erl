-module(shigoto_sandbox_probe_worker).
-behaviour(shigoto_worker).

-export([perform/1]).

perform(_Args) ->
    #{rows := [#{n := N}]} = shigoto_db:query(
        shigoto_kura_test_repo, ~"SELECT count(*) AS n FROM shigoto_jobs", []
    ),
    {ok, N}.
