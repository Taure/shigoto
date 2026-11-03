-module(shigoto_boot_SUITE).
-behaviour(ct_suite).
-moduledoc "The application holds its queues back while the schema cannot be migrated.".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([queues_wait_for_the_migration/1]).

-define(POOL, shigoto_test_pool).

all() ->
    [queues_wait_for_the_migration].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    ok = application:load(shigoto),
    application:set_env(shigoto, pool, ?POOL),
    application:set_env(shigoto, queues, [{~"boot_probe", 1}]),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(shigoto),
    application:unset_env(shigoto, queues),
    shigoto_migration:down(?POOL),
    ok.

queues_wait_for_the_migration(_Config) ->
    #{} = shigoto_db:query(?POOL, ~"COMMENT ON TABLE shigoto_jobs IS NULL", []),
    Reader = read_the_archive(),
    try
        {ok, _} = application:ensure_all_started(shigoto),
        ?assertEqual(undefined, whereis(shigoto_queue_sup)),
        ?assert(is_pid(whereis(shigoto_migrator)))
    after
        Reader ! stop
    end,
    shigoto_migrator ! retry,
    ok = wait_for(fun() -> is_pid(whereis(shigoto_queue_sup)) end, 50),
    ?assertMatch(
        [{{shigoto_queue, ~"boot_probe"}, _, _, _}], supervisor:which_children(shigoto_queue_sup)
    ),
    ok = wait_for(fun() -> whereis(shigoto_migrator) =:= undefined end, 50),
    ?assertMatch(
        #{rows := [#{version := ~"shigoto 6"}]},
        shigoto_db:query(?POOL, ~"SELECT obj_description('shigoto_jobs'::regclass) AS version", [])
    ).

read_the_archive() ->
    Self = self(),
    Reader = spawn(fun() ->
        shigoto_db:transaction(?POOL, fun() ->
            #{} = shigoto_db:query(?POOL, ~"SELECT count(*) FROM shigoto_jobs_archive", []),
            Self ! reading,
            receive
                stop -> ok
            end
        end)
    end),
    receive
        reading -> Reader
    after 5000 -> ct:fail(reader_did_not_start)
    end.

wait_for(_Check, 0) ->
    ct:fail(condition_not_met);
wait_for(Check, Tries) ->
    case Check() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_for(Check, Tries - 1)
    end.
