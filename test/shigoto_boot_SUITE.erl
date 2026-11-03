-module(shigoto_boot_SUITE).
-behaviour(ct_suite).
-moduledoc "The application holds its queues back while the schema cannot be migrated.".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    queues_wait_for_the_migration/1,
    notifier_survives_while_queues_wait/1,
    a_queue_failing_on_the_late_path_is_logged/1,
    boot_does_not_retry_a_refused_migration/1
]).

-define(POOL, shigoto_test_pool).
-define(LIMITED_POOL, shigoto_limited_pool).

all() ->
    [
        queues_wait_for_the_migration,
        notifier_survives_while_queues_wait,
        a_queue_failing_on_the_late_path_is_logged,
        boot_does_not_retry_a_refused_migration
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    ok = application:load(shigoto),
    application:set_env(shigoto, pool, ?POOL),
    Config.

end_per_suite(_Config) ->
    application:unset_env(shigoto, queues),
    shigoto_migration:down(?POOL),
    ok.

init_per_testcase(_TestCase, Config) ->
    application:set_env(shigoto, queues, [{~"boot_probe", 1}]),
    Config.

end_per_testcase(_TestCase, _Config) ->
    _ = application:stop(shigoto),
    application:unset_env(shigoto, notifier),
    application:unset_env(shigoto, fanout_queues),
    ok = shigoto_migration:up(?POOL).

queues_wait_for_the_migration(_Config) ->
    #{} = shigoto_db:query(?POOL, ~"COMMENT ON TABLE shigoto_jobs IS NULL", []),
    Reader = read_the_archive(),
    try
        {ok, _} = application:ensure_all_started(shigoto),
        ?assertEqual([], supervisor:which_children(shigoto_queue_sup)),
        ?assert(is_pid(whereis(shigoto_migrator)))
    after
        Reader ! stop
    end,
    ok = shigoto_migrator:retry_now(),
    ok = wait_for(fun() -> supervisor:which_children(shigoto_queue_sup) =/= [] end, 50),
    ?assertMatch(
        [{{shigoto_queue, ~"boot_probe"}, _, _, _}], supervisor:which_children(shigoto_queue_sup)
    ),
    ok = wait_for(fun() -> whereis(shigoto_migrator) =:= undefined end, 50),
    ?assertEqual(not_running, shigoto_migrator:retry_now()),
    ?assertMatch(
        #{rows := [#{version := ~"shigoto 6"}]},
        shigoto_db:query(?POOL, ~"SELECT obj_description('shigoto_jobs'::regclass) AS version", [])
    ).

notifier_survives_while_queues_wait(_Config) ->
    application:set_env(shigoto, notifier, connection()),
    #{} = shigoto_db:query(?POOL, ~"COMMENT ON TABLE shigoto_jobs IS NULL", []),
    Reader = read_the_archive(),
    {Sup, Notifier} =
        try
            {ok, _} = application:ensure_all_started(shigoto),
            ok = wait_for(fun notifier_listening/0, 50),
            Pids = {whereis(shigoto_sup), whereis(shigoto_notifier)},
            [
                #{} = shigoto_db:query(?POOL, ~"SELECT pg_notify('shigoto_jobs_insert', $1)", [Q])
             || Q <- [~"boot_probe", ~"", ~"other"],
                _ <- lists:seq(1, 5)
            ],
            timer:sleep(1000),
            ?assertEqual(Pids, {whereis(shigoto_sup), whereis(shigoto_notifier)}),
            ?assertEqual({error, migration_pending}, shigoto:add_queue(~"late", 1)),
            ?assertMatch(
                {error, #{status := unhealthy, reason := migration_pending}}, shigoto:health()
            ),
            ?assertEqual({error, not_found}, shigoto:pause_queue(~"boot_probe")),
            Pids
        after
            Reader ! stop
        end,
    ok = shigoto_migrator:retry_now(),
    ok = wait_for(fun() -> whereis(shigoto_migrator) =:= undefined end, 50),
    ?assertMatch(
        [{{shigoto_queue, ~"boot_probe"}, _, _, _}], supervisor:which_children(shigoto_queue_sup)
    ),
    ?assertEqual({Sup, Notifier}, {whereis(shigoto_sup), whereis(shigoto_notifier)}),
    ?assertMatch({ok, _}, shigoto:add_queue(~"late", 1)),
    ?assertMatch({ok, #{status := ok}}, shigoto:health()).

a_queue_failing_on_the_late_path_is_logged(_Config) ->
    {ok, _} = application:ensure_all_started(shigoto),
    application:set_env(shigoto, queues, [{~"boot_probe", 1}, {~"late_probe", 1}]),
    application:set_env(shigoto, fanout_queues, [{~"bad_fanout", 1, not_a_map}]),
    Self = self(),
    ok = telemetry:attach(
        start_failed,
        [shigoto, queue, start_failed],
        fun(_Event, _Measurements, Metadata, _HandlerConfig) -> Self ! {start_failed, Metadata} end,
        undefined
    ),
    ok = shigoto_log_probe:attach(),
    try
        {ok, Migrator} = shigoto_migrator:start_link(),
        unlink(Migrator),
        Ref = monitor(process, Migrator),
        ok = shigoto_migrator:retry_now(),
        receive
            {'DOWN', Ref, process, Migrator, Exit} -> ?assertEqual(normal, Exit)
        after 5000 -> ct:fail(migrator_did_not_stop)
        end,
        receive
            {log, error, #{msg := ~"shigoto_queue_start_failed"} = Report} ->
                ?assertMatch(#{queue := ~"bad_fanout", reason := _}, Report)
        after 2000 -> ct:fail(no_queue_start_failed_log)
        end,
        receive
            {start_failed, Metadata} -> ?assertMatch(#{queue := ~"bad_fanout"}, Metadata)
        after 2000 -> ct:fail(no_start_failed_telemetry)
        end
    after
        shigoto_log_probe:detach(),
        telemetry:detach(start_failed)
    end,
    ?assertEqual(
        [{shigoto_queue, ~"boot_probe"}, {shigoto_queue, ~"late_probe"}],
        lists:sort([
            Id
         || {Id, Pid, _, _} <- supervisor:which_children(shigoto_queue_sup), is_pid(Pid)
        ])
    ).

boot_does_not_retry_a_refused_migration(_Config) ->
    _ = shigoto_db:query(?POOL, ~"DROP ROLE IF EXISTS shigoto_limited", []),
    #{} = shigoto_db:query(?POOL, ~"CREATE ROLE shigoto_limited LOGIN PASSWORD 'limited'", []),
    {ok, _} = shigoto_db:start_pool(
        ?LIMITED_POOL, (connection())#{
            user => "shigoto_limited", password => "limited", pool_size => 1
        }
    ),
    #{} = shigoto_db:query(?POOL, ~"COMMENT ON TABLE shigoto_jobs IS NULL", []),
    ?assertMatch(
        {error, {pgsql_error, #{code := ~"42501"}}}, shigoto_migration:up(?LIMITED_POOL)
    ),
    Started = erlang:monotonic_time(millisecond),
    ?assertNot(shigoto_migrator:boot(?LIMITED_POOL)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000).

connection() ->
    #{
        host => "localhost",
        port => shigoto_test_repo:port(),
        database => "shigoto_test",
        user => "postgres",
        password => "root"
    }.

notifier_listening() ->
    case sys:get_state(shigoto_notifier) of
        {state, undefined} -> false;
        {state, _Listener} -> true
    end.

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
