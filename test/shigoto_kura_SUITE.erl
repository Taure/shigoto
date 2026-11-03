-module(shigoto_kura_SUITE).
-moduledoc """
Shigoto and kura sharing a transaction on one minato pool.

`kura_driver_minato` is what a kura repo calls for `Repo:transaction/1` and
every statement in it, so calling it on the shigoto test pool is what a repo
whose pool shigoto shares would do.
""".
-behaviour(ct_suite).
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    insert_in_a_rolled_back_kura_transaction_is_undone/1,
    insert_in_a_kura_transaction_commits_with_it/1,
    unique_insert_in_a_kura_transaction_joins_it/1,
    kura_write_in_a_rolled_back_shigoto_transaction_is_undone/1,
    kura_write_in_a_shigoto_transaction_commits_with_it/1,
    shigoto_transaction_with_a_pool_keeps_its_own_connection/1
]).

-define(POOL, shigoto_test_pool).

all() ->
    [
        insert_in_a_rolled_back_kura_transaction_is_undone,
        insert_in_a_kura_transaction_commits_with_it,
        unique_insert_in_a_kura_transaction_joins_it,
        kura_write_in_a_rolled_back_shigoto_transaction_is_undone,
        kura_write_in_a_shigoto_transaction_commits_with_it,
        shigoto_transaction_with_a_pool_keeps_its_own_connection
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    #{} = shigoto_db:query(
        ?POOL, ~"CREATE TABLE IF NOT EXISTS shigoto_kura_probe (id integer)", []
    ),
    Config.

end_per_suite(_Config) ->
    _ = shigoto_db:query(?POOL, ~"DROP TABLE IF EXISTS shigoto_kura_probe", []),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:unset_env(shigoto, repo),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_kura_probe", []),
    ok.

%%----------------------------------------------------------------------
%% Enqueue inside a kura transaction
%%----------------------------------------------------------------------

insert_in_a_rolled_back_kura_transaction_is_undone(_Config) ->
    ?assertError(
        boom,
        kura_transaction(fun() ->
            ok = kura_write(1),
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, {count_jobs(), count_probes()}).

insert_in_a_kura_transaction_commits_with_it(_Config) ->
    kura_transaction(fun() ->
        ok = kura_write(1),
        {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
        ?assertEqual(0, elsewhere(fun count_jobs/0))
    end),
    ?assertEqual({1, 1}, {count_jobs(), count_probes()}).

unique_insert_in_a_kura_transaction_joins_it(_Config) ->
    Unique = #{unique => #{keys => [worker, args]}},
    Job = #{worker => shigoto_test_worker, args => #{~"n" => 1}},
    ?assertError(
        boom,
        kura_transaction(fun() ->
            {ok, #{id := _}} = shigoto:insert(Job, Unique),
            {ok, {conflict, _}} = shigoto:insert(Job, Unique),
            error(boom)
        end)
    ),
    ?assertEqual(0, count_jobs()).

%%----------------------------------------------------------------------
%% kura writes inside shigoto:transaction/1
%%----------------------------------------------------------------------

kura_write_in_a_rolled_back_shigoto_transaction_is_undone(_Config) ->
    application:set_env(shigoto, repo, ?POOL),
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            ok = kura_write(1),
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, {count_jobs(), count_probes()}).

kura_write_in_a_shigoto_transaction_commits_with_it(_Config) ->
    application:set_env(shigoto, repo, ?POOL),
    done = shigoto:transaction(fun() ->
        ok = kura_write(1),
        {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
        ?assertEqual(0, elsewhere(fun count_probes/0)),
        done
    end),
    ?assertEqual({1, 1}, {count_jobs(), count_probes()}).

shigoto_transaction_with_a_pool_keeps_its_own_connection(_Config) ->
    shigoto:transaction(fun() ->
        ?assert(is_pid(shigoto_db:in_transaction(?POOL))),
        ?assertEqual(undefined, kura_pool_minato:transaction_conn(?POOL))
    end).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

kura_transaction(Fun) ->
    kura_driver_minato:transaction(kura_pool_minato, ?POOL, Fun, #{}).

kura_write(Id) ->
    #{command := insert} = kura_driver_minato:query(
        kura_pool_minato, ?POOL, ~"INSERT INTO shigoto_kura_probe (id) VALUES ($1)", [Id], #{}
    ),
    ok.

count_jobs() ->
    count(~"SELECT count(*) AS n FROM shigoto_jobs").

count_probes() ->
    count(~"SELECT count(*) AS n FROM shigoto_kura_probe").

count(SQL) ->
    #{rows := [#{n := N}]} = shigoto_db:query(?POOL, SQL, []),
    N.

elsewhere(Fun) ->
    Self = self(),
    Ref = make_ref(),
    _ = spawn_link(fun() -> Self ! {Ref, Fun()} end),
    receive
        {Ref, Answer} -> Answer
    after 5000 -> ct:fail(no_answer)
    end.
