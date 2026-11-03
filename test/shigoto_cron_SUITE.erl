-module(shigoto_cron_SUITE).
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
    cron_inserts_a_due_entry/1,
    cron_schedules_each_minute_once/1,
    cron_uses_the_worker_queue/1,
    cron_skips_while_another_node_leads/1,
    cron_catches_up_a_missed_minute/1,
    cron_does_not_backfill_a_new_entry/1,
    cron_never_moves_the_last_run_back/1,
    cron_telemetry_fires_after_the_pass_commits/1,
    stager_notifies_a_due_queue/1
]).

-define(POOL, shigoto_test_pool).
-define(CHANNEL, ~"shigoto_jobs_insert").
-define(CRON_LOCK_ID, 839274628).

all() ->
    [
        cron_inserts_a_due_entry,
        cron_schedules_each_minute_once,
        cron_uses_the_worker_queue,
        cron_skips_while_another_node_leads,
        cron_catches_up_a_missed_minute,
        cron_does_not_backfill_a_new_entry,
        cron_never_moves_the_last_run_back,
        cron_telemetry_fires_after_the_pass_commits,
        stager_notifies_a_due_queue
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:unset_env(shigoto, cron),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_cron", []),
    ok.

%%----------------------------------------------------------------------
%% Cron
%%----------------------------------------------------------------------

cron_inserts_a_due_entry(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{~"n" => 1}}]),
    Before = this_minute(),
    ok = shigoto_cron:schedule_once(),
    After = this_minute(),
    ?assertMatch([#{worker := ~"shigoto_test_worker", queue := ~"default"}], jobs()),
    [#{last_scheduled_at := LastRun}] = cron_rows(),
    ?assert(LastRun =:= Before orelse LastRun =:= After).

cron_schedules_each_minute_once(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    ok = shigoto_cron:schedule_once(),
    #{} = shigoto_db:query(?POOL, ~"UPDATE shigoto_jobs SET state = 'completed'", []),
    ok = shigoto_cron:schedule_once(),
    ?assertEqual(1, length(jobs())).

cron_uses_the_worker_queue(_Config) ->
    set_cron([{~"configured", ~"* * * * *", shigoto_configured_worker, #{}}]),
    ok = shigoto_cron:schedule_once(),
    ?assertMatch([#{queue := ~"priority_queue", priority := 5}], jobs()),
    ?assertMatch(
        [#{queue := ~"priority_queue", priority := 5, max_attempts := 7}], cron_rows()
    ).

cron_skips_while_another_node_leads(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    Self = self(),
    Leader = spawn_link(fun() ->
        shigoto_db:transaction(?POOL, fun() ->
            true = shigoto_repo:try_advisory_xact_lock(?POOL, ?CRON_LOCK_ID),
            Self ! leading,
            receive
                stop -> ok
            end
        end)
    end),
    receive
        leading -> ok
    after 5000 -> ct:fail(leader_did_not_lock)
    end,
    ok = shigoto_cron:schedule_once(),
    ?assertEqual([], jobs()),
    Leader ! stop.

cron_catches_up_a_missed_minute(_Config) ->
    {_Date, {_, Missed, _}} = minutes_ago(5),
    Schedule = iolist_to_binary([integer_to_binary(Missed), ~" * * * *"]),
    set_cron([{~"missed", Schedule, shigoto_test_worker, #{}}]),
    ok = shigoto_repo:upsert_cron_entry(?POOL, #{
        name => ~"missed",
        worker => shigoto_test_worker,
        schedule => Schedule,
        last_scheduled_at => minutes_ago(10)
    }),
    ok = shigoto_cron:schedule_once(),
    ?assertEqual(1, length(jobs())),
    ok = shigoto_cron:schedule_once(),
    ?assertEqual(1, length(jobs())).

cron_does_not_backfill_a_new_entry(_Config) ->
    {_Date, {_, Missed, _}} = minutes_ago(5),
    Schedule = iolist_to_binary([integer_to_binary(Missed), ~" * * * *"]),
    set_cron([{~"new", Schedule, shigoto_test_worker, #{}}]),
    ok = shigoto_cron:schedule_once(),
    ?assertEqual([], jobs()),
    ?assertMatch([#{name := ~"new"}], cron_rows()).

cron_never_moves_the_last_run_back(_Config) ->
    %% A leader whose clock ran ahead stored a later minute than this one.
    Ahead = minutes_ago(-10),
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    ok = shigoto_repo:upsert_cron_entry(?POOL, #{
        name => ~"every_minute",
        worker => shigoto_test_worker,
        schedule => ~"* * * * *",
        last_scheduled_at => Ahead
    }),
    ok = shigoto_cron:schedule_once(),
    ?assertEqual([], jobs()),
    ?assertMatch([#{last_scheduled_at := Ahead}], cron_rows()).

cron_telemetry_fires_after_the_pass_commits(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    Handler = {?MODULE, inserted},
    Self = self(),
    ok = telemetry:attach(
        Handler,
        [shigoto, job, inserted],
        fun(_Event, _Measure, _Meta, _HandlerConfig) ->
            Self ! {inserted, shigoto_db:in_transaction(?POOL)}
        end,
        undefined
    ),
    try
        ok = shigoto_cron:schedule_once(),
        receive
            {inserted, Holder} -> ?assertEqual(undefined, Holder)
        after 2000 -> ct:fail(no_job_inserted_telemetry)
        end
    after
        telemetry:detach(Handler)
    end.

%%----------------------------------------------------------------------
%% Stager
%%----------------------------------------------------------------------

stager_notifies_a_due_queue(_Config) ->
    Listener = shigoto_cron_suite_listener,
    {ok, _} = shigoto_db:start_listener(Listener, #{
        host => "localhost",
        port => shigoto_test_repo:port(),
        database => "shigoto_test",
        user => "postgres",
        password => "root"
    }),
    try
        ok = minato:listen(Listener, ?CHANNEL),
        {ok, _} = shigoto_repo:insert_job(
            ?POOL, #{worker => shigoto_test_worker, args => #{}, queue => ~"staged"}, #{}
        ),
        flush_notifications(),
        ok = shigoto_stager:stage_once(),
        receive
            {minato_notification, ?CHANNEL, ~"staged", _From} -> ok
        after 2000 -> ct:fail(stager_did_not_notify)
        end
    after
        minato:stop_listener(Listener)
    end.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

set_cron(Entries) ->
    application:set_env(shigoto, cron, Entries).

jobs() ->
    #{rows := Rows} = shigoto_db:query(?POOL, ~"SELECT * FROM shigoto_jobs ORDER BY id", []),
    Rows.

cron_rows() ->
    #{rows := Rows} = shigoto_db:query(?POOL, ~"SELECT * FROM shigoto_cron ORDER BY name", []),
    Rows.

this_minute() ->
    {Date, {H, M, _}} = calendar:universal_time(),
    {Date, {H, M, 0}}.

minutes_ago(N) ->
    Secs = calendar:datetime_to_gregorian_seconds(this_minute()),
    calendar:gregorian_seconds_to_datetime(Secs - N * 60).

flush_notifications() ->
    receive
        {minato_notification, _, _, _} -> flush_notifications()
    after 300 -> ok
    end.
