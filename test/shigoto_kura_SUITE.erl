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
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    insert_in_a_rolled_back_kura_transaction_is_undone/1,
    insert_in_a_kura_transaction_commits_with_it/1,
    unique_insert_in_a_kura_transaction_joins_it/1,
    kura_write_in_a_rolled_back_shigoto_transaction_is_undone/1,
    kura_write_in_a_shigoto_transaction_commits_with_it/1,
    shigoto_transaction_with_a_pool_keeps_its_own_connection/1,
    a_commit_kura_refuses_raises_like_shigoto/1,
    kura_is_available/1,
    migration_and_cron_refuse_a_kura_transaction/1,
    repo_transaction_rolls_back_its_jobs/1,
    repo_transaction_commits_its_jobs/1,
    repo_writes_join_shigoto_transaction/1,
    sandboxed_insert_is_rolled_back_at_checkin/1,
    sandboxed_repo_transaction_holds_its_jobs/1,
    sandboxed_repo_transaction_rolls_back_its_jobs/1,
    sandboxed_repo_writes_join_shigoto_transaction/1,
    sandboxed_shigoto_transaction_rolls_back_to_its_savepoint/1,
    sandboxed_failed_statement_rolls_back_shigoto_transaction/1,
    sandboxed_nested_shigoto_transaction_joins_the_outer/1,
    sandboxed_shigoto_transaction_in_repo_transaction_joins_it/1,
    sandboxed_repo_transaction_refuses_migration/1,
    sandboxed_overlapping_shigoto_transaction_raises/1,
    sandboxed_insert_with_pool_config_joins_the_sandbox/1,
    shigoto_processes_stay_out_of_the_sandbox/1,
    insert_after_checkin_commits/1
]).

-define(POOL, shigoto_test_pool).
-define(REPO, shigoto_kura_test_repo).

all() ->
    [
        insert_in_a_rolled_back_kura_transaction_is_undone,
        insert_in_a_kura_transaction_commits_with_it,
        unique_insert_in_a_kura_transaction_joins_it,
        kura_write_in_a_rolled_back_shigoto_transaction_is_undone,
        kura_write_in_a_shigoto_transaction_commits_with_it,
        shigoto_transaction_with_a_pool_keeps_its_own_connection,
        a_commit_kura_refuses_raises_like_shigoto,
        kura_is_available,
        migration_and_cron_refuse_a_kura_transaction,
        repo_transaction_rolls_back_its_jobs,
        repo_transaction_commits_its_jobs,
        repo_writes_join_shigoto_transaction,
        insert_after_checkin_commits,
        {group, sandbox},
        {group, shared_sandbox}
    ].

groups() ->
    Sandboxed = [
        sandboxed_insert_is_rolled_back_at_checkin,
        sandboxed_repo_transaction_holds_its_jobs,
        sandboxed_repo_transaction_rolls_back_its_jobs,
        sandboxed_repo_writes_join_shigoto_transaction,
        sandboxed_shigoto_transaction_rolls_back_to_its_savepoint,
        sandboxed_failed_statement_rolls_back_shigoto_transaction,
        sandboxed_nested_shigoto_transaction_joins_the_outer,
        sandboxed_shigoto_transaction_in_repo_transaction_joins_it,
        sandboxed_repo_transaction_refuses_migration,
        sandboxed_overlapping_shigoto_transaction_raises,
        sandboxed_insert_with_pool_config_joins_the_sandbox,
        shigoto_processes_stay_out_of_the_sandbox
    ],
    [{sandbox, [], Sandboxed}, {shared_sandbox, [], Sandboxed}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    #{} = shigoto_db:query(
        ?POOL, ~"CREATE TABLE IF NOT EXISTS shigoto_kura_probe (id integer)", []
    ),
    #{} = shigoto_db:query(
        ?POOL,
        ~"""
        CREATE TABLE IF NOT EXISTS shigoto_kura_deferred (
          id integer, CONSTRAINT shigoto_kura_deferred_id UNIQUE (id) DEFERRABLE INITIALLY DEFERRED
        )
        """,
        []
    ),
    #{} = shigoto_db:query(
        ?POOL,
        ~"CREATE TABLE IF NOT EXISTS shigoto_kura_posts (id bigserial PRIMARY KEY, title text NOT NULL)",
        []
    ),
    application:set_env(kura, repos, #{
        ?REPO => #{
            backend => kura_backend_postgres,
            host => "localhost",
            port => shigoto_test_repo:port(),
            database => "shigoto_test",
            user => "postgres",
            password => "root",
            pool_size => 2
        }
    }),
    {ok, _} = application:ensure_all_started(kura),
    Config ++ [{sandbox_table, sandbox_table()}].

end_per_suite(Config) ->
    case lists:keyfind(sandbox_table, 1, Config) of
        {sandbox_table, Owner} when is_pid(Owner) -> exit(Owner, shutdown)
    end,
    _ = application:stop(kura),
    _ = shigoto_db:query(?POOL, ~"DROP TABLE IF EXISTS shigoto_kura_probe", []),
    _ = shigoto_db:query(?POOL, ~"DROP TABLE IF EXISTS shigoto_kura_deferred", []),
    _ = shigoto_db:query(?POOL, ~"DROP TABLE IF EXISTS shigoto_kura_posts", []),
    ok.

init_per_group(sandbox, Config) ->
    [{sandbox, #{}} | Config];
init_per_group(shared_sandbox, Config) ->
    [{sandbox, #{shared => true}} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok = kura_sandbox:checkin(?REPO),
    application:unset_env(shigoto, repo),
    application:set_env(shigoto, pool, ?POOL),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_kura_probe", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_kura_deferred", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_kura_posts", []),
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

a_commit_kura_refuses_raises_like_shigoto(_Config) ->
    application:set_env(shigoto, repo, ?POOL),
    ?assertError(
        {shigoto_db, {commit_failed, {pgsql_error, #{code := ~"23505"}}}},
        shigoto:transaction(fun() ->
            ?assertEqual(undefined, shigoto_db:in_transaction(?POOL)),
            ok = kura_write_deferred(1),
            ok = kura_write_deferred(1)
        end)
    ).

kura_is_available(_Config) ->
    ?assert(shigoto_db:kura_available()).

migration_and_cron_refuse_a_kura_transaction(_Config) ->
    kura_transaction(fun() ->
        ?assertEqual({error, in_transaction}, shigoto_migration:up(?POOL)),
        ?assertEqual({error, in_transaction}, shigoto_cron:schedule_once())
    end).

%%----------------------------------------------------------------------
%% A real kura repo
%%----------------------------------------------------------------------

repo_transaction_rolls_back_its_jobs(_Config) ->
    application:set_env(shigoto, repo, ?REPO),
    ?assertError(
        boom,
        ?REPO:transaction(fun() ->
            {ok, _Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, {count_jobs(), count_posts()}).

repo_transaction_commits_its_jobs(_Config) ->
    application:set_env(shigoto, repo, ?REPO),
    {ok, _} = ?REPO:transaction(fun() ->
        {ok, Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
        {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
        ?assertEqual(0, elsewhere(fun count_jobs/0)),
        {ok, Post}
    end),
    ?assertEqual({1, 1}, {count_jobs(), count_posts()}).

repo_writes_join_shigoto_transaction(_Config) ->
    application:set_env(shigoto, repo, ?REPO),
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            {ok, _Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, {count_jobs(), count_posts()}).

%%----------------------------------------------------------------------
%% Inside kura_sandbox
%%----------------------------------------------------------------------

sandboxed_insert_is_rolled_back_at_checkin(Config) ->
    sandbox(Config),
    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    ?assertEqual({1, 0}, seen()),
    ?assertEqual({0, 0}, committed()),
    ok = kura_sandbox:checkin(?REPO),
    ?assertEqual({0, 0}, committed()).

sandboxed_repo_transaction_holds_its_jobs(Config) ->
    sandbox(Config),
    {ok, _} = ?REPO:transaction(fun() ->
        {ok, Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
        {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
        {ok, Post}
    end),
    ?assertEqual({1, 1}, seen()),
    ?assertEqual({0, 0}, committed()),
    ok = kura_sandbox:checkin(?REPO),
    ?assertEqual({0, 0}, committed()).

sandboxed_repo_transaction_rolls_back_its_jobs(Config) ->
    sandbox(Config),
    ?assertError(
        boom,
        ?REPO:transaction(fun() ->
            {ok, _Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, seen()),
    ?assertEqual({0, 0}, committed()).

sandboxed_repo_writes_join_shigoto_transaction(Config) ->
    sandbox(Config),
    done = shigoto:transaction(fun() ->
        {ok, _Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
        {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
        ?assertEqual({1, 1}, seen()),
        done
    end),
    ?assertEqual({1, 1}, seen()),
    ?assertEqual({0, 0}, committed()),
    ok = kura_sandbox:checkin(?REPO),
    ?assertEqual({0, 0}, committed()).

sandboxed_shigoto_transaction_rolls_back_to_its_savepoint(Config) ->
    sandbox(Config),
    {ok, _Kept} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"kept"})),
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            {ok, _Post} = ?REPO:insert(shigoto_kura_test_post:changeset(#{title => ~"a"})),
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            error(boom)
        end)
    ),
    ?assertEqual({0, 1}, seen()),
    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    ?assertEqual({1, 1}, seen()),
    ?assertEqual({0, 0}, committed()).

sandboxed_failed_statement_rolls_back_shigoto_transaction(Config) ->
    sandbox(Config),
    ?assertError(
        transaction_rolled_back,
        shigoto:transaction(fun() ->
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            {error, {pgsql_error, #{code := ~"22012"}}} =
                shigoto_db:query(?REPO, ~"SELECT 1 / 0", []),
            done
        end)
    ),
    ?assertEqual({0, 0}, seen()),
    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    ?assertEqual({1, 0}, seen()),
    ?assertEqual({0, 0}, committed()).

sandboxed_nested_shigoto_transaction_joins_the_outer(Config) ->
    sandbox(Config),
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            {ok, _Job} = shigoto:transaction(fun() ->
                shigoto:insert(#{worker => shigoto_test_worker, args => #{}})
            end),
            ?assertEqual({error, in_transaction}, shigoto_migration:up(?REPO)),
            ?assertEqual({1, 0}, seen()),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, seen()),
    ?assertEqual({0, 0}, committed()).

sandboxed_shigoto_transaction_in_repo_transaction_joins_it(Config) ->
    sandbox(Config),
    {ok, done} = ?REPO:transaction(fun() ->
        caught =
            try
                shigoto:transaction(fun() ->
                    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
                    throw(caught)
                end)
            catch
                throw:caught -> caught
            end,
        {ok, done}
    end),
    ?assertEqual({1, 0}, seen()),
    ?assertEqual({0, 0}, committed()).

sandboxed_repo_transaction_refuses_migration(Config) ->
    sandbox(Config),
    ?assertNot(shigoto_db:transaction_open(?REPO)),
    {ok, done} = ?REPO:transaction(fun() ->
        ?assertEqual({error, in_transaction}, shigoto_migration:up(?REPO)),
        {ok, done}
    end).

sandboxed_overlapping_shigoto_transaction_raises(Config) ->
    sandbox(Config),
    Self = self(),
    {ok, done} = ?REPO:transaction(fun() ->
        Child = spawn(fun() ->
            receive
                go -> Self ! {overlap, attempted(fun() -> shigoto:transaction(fun() -> ok end) end)}
            end
        end),
        ok = allowed(Config, Child),
        Child ! go,
        receive
            {overlap, Answer} ->
                ?assertEqual({error, {kura_sandbox, overlapping_transactions}}, Answer)
        after 5000 -> ct:fail(no_overlap)
        end,
        {ok, done}
    end).

sandboxed_insert_with_pool_config_joins_the_sandbox(Config) ->
    ok = kura_sandbox:checkout(?REPO, sandbox_opts(Config)),
    application:set_env(shigoto, pool, ?REPO),
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            ?assertEqual({1, 0}, seen()),
            error(boom)
        end)
    ),
    ?assertEqual({0, 0}, committed()),
    ok = kura_sandbox:checkin(?REPO),
    ?assertEqual({0, 0}, committed()).

shigoto_processes_stay_out_of_the_sandbox(Config) ->
    sandbox(Config),
    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    Count = fun() -> count_on(?REPO, ~"SELECT count(*) AS n FROM shigoto_jobs") end,
    ?assertEqual(
        0,
        elsewhere(fun() ->
            ok = shigoto_db:ignore_sandbox(),
            Count()
        end)
    ),
    Shared = maps:get(shared, sandbox_opts(Config), false),
    ?assertEqual(Shared, elsewhere(Count) =:= 1).

insert_after_checkin_commits(_Config) ->
    application:set_env(shigoto, repo, ?REPO),
    ok = kura_sandbox:checkout(?REPO),
    ok = kura_sandbox:checkin(?REPO),
    {ok, _Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    ?assertEqual({1, 0}, committed()).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

sandbox(Config) ->
    application:set_env(shigoto, repo, ?REPO),
    ok = kura_sandbox:checkout(?REPO, sandbox_opts(Config)).

%% An allowed process looks for its owner's own checkout, which a shared one is not.
allowed(Config, Child) ->
    case sandbox_opts(Config) of
        #{shared := true} -> ok;
        #{} -> kura_sandbox:allow(?REPO, self(), Child)
    end.

sandbox_opts(Config) ->
    case lists:keyfind(sandbox, 1, Config) of
        {sandbox, #{} = Opts} -> Opts
    end.

attempted(Fun) ->
    try Fun() of
        Value -> {ok, Value}
    catch
        error:Reason -> {error, Reason}
    end.

count_on(Pool, SQL) ->
    #{rows := [#{n := N}]} = shigoto_db:query(Pool, SQL, []),
    N.

%% kura_sandbox's table belongs to the process that creates it, and the process
%% that runs init_per_suite does not outlive it.
sandbox_table() ->
    Self = self(),
    Owner = spawn(fun() ->
        ok = kura_sandbox:start(),
        Self ! {sandbox_table, self()},
        receive
            never -> ok
        end
    end),
    receive
        {sandbox_table, Owner} -> Owner
    after 5000 -> ct:fail(no_sandbox_table)
    end.

%% What the test sees through kura: its sandbox when one is checked out.
seen() ->
    {
        seen(~"SELECT count(*) AS n FROM shigoto_jobs"),
        seen(~"SELECT count(*) AS n FROM shigoto_kura_posts")
    }.

seen(SQL) ->
    #{rows := [#{n := N}]} = kura_db:query(?REPO, SQL, []),
    N.

%% What another connection sees: only what was committed.
committed() ->
    {
        committed(~"SELECT count(*) AS n FROM shigoto_jobs"),
        committed(~"SELECT count(*) AS n FROM shigoto_kura_posts")
    }.

committed(SQL) ->
    {ok, #{rows := [#{n := N}]}} = minato:query(?POOL, SQL, [], #{
        return_rows_as_maps => true, column_name_as_atom => true
    }),
    N.

kura_write_deferred(Id) ->
    #{command := insert} = kura_driver_minato:query(
        kura_pool_minato, ?POOL, ~"INSERT INTO shigoto_kura_deferred (id) VALUES ($1)", [Id], #{}
    ),
    ok.

count_posts() ->
    count(~"SELECT count(*) AS n FROM shigoto_kura_posts").

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
