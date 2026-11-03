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
    cron_logs_no_row_values/1,
    cron_encrypts_entry_args/1,
    cron_resets_a_last_run_far_ahead/1,
    cron_skips_a_bad_entry/1,
    cron_warns_once_per_skipped_entry/1,
    cron_skips_a_worker_whose_defaults_overflow/1,
    cron_reports_a_failed_pass/1,
    cron_pass_refuses_an_open_transaction/1,
    cron_warns_when_its_lock_is_held_elsewhere/1,
    cron_does_not_warn_while_a_peer_schedules/1,
    stager_warns_when_its_lock_is_held_elsewhere/1,
    stager_notifies_a_due_queue/1
]).

-define(POOL, shigoto_test_pool).
-define(CHANNEL, ~"shigoto_jobs_insert").
-define(CRON_LOCK_ID, 839274628).
-define(STAGE_LOCK_ID, 839274629).

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
        cron_logs_no_row_values,
        cron_encrypts_entry_args,
        cron_resets_a_last_run_far_ahead,
        cron_skips_a_bad_entry,
        cron_warns_once_per_skipped_entry,
        cron_skips_a_worker_whose_defaults_overflow,
        cron_reports_a_failed_pass,
        cron_pass_refuses_an_open_transaction,
        cron_warns_when_its_lock_is_held_elsewhere,
        cron_does_not_warn_while_a_peer_schedules,
        stager_warns_when_its_lock_is_held_elsewhere,
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
    in_one_minute(
        fun() ->
            ok = shigoto_cron:schedule_once(),
            #{} = shigoto_db:query(?POOL, ~"UPDATE shigoto_jobs SET state = 'completed'", []),
            ok = shigoto_cron:schedule_once(),
            length(jobs())
        end,
        fun(Count) -> ?assertEqual(1, Count) end
    ).

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

cron_logs_no_row_values(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{~"secret" => ~"hunter2"}}]),
    #{} = shigoto_db:query(
        ?POOL,
        ~"ALTER TABLE shigoto_cron ADD CONSTRAINT shigoto_cron_probe CHECK (schedule <> '* * * * *')",
        []
    ),
    ok = shigoto_log_probe:attach(),
    try
        {error, pass_failed} = shigoto_cron:schedule_once(),
        Report = receive_log(~"shigoto_cron_pass_failed"),
        ?assertMatch(
            #{
                reason :=
                    {shigoto_cron,
                        {store_failed, ~"every_minute", {pgsql_error, #{code := ~"23514"}}}}
            },
            Report
        ),
        Logged = iolist_to_binary(io_lib:format("~p", [Report])),
        ?assertEqual(nomatch, binary:match(Logged, [~"Failing row", ~"hunter2"]))
    after
        shigoto_log_probe:detach(),
        #{} = shigoto_db:query(
            ?POOL, ~"ALTER TABLE shigoto_cron DROP CONSTRAINT shigoto_cron_probe", []
        )
    end.

cron_warns_when_its_lock_is_held_elsewhere(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    Holder = hold_lock(?CRON_LOCK_ID),
    ok = shigoto_log_probe:attach(),
    ok = attach_lock_telemetry(),
    try
        {noreply, #{misses := 4}} = shigoto_cron:handle_info(tick, #{misses => 3}),
        refute_log(~"shigoto_cron_lock_held_elsewhere"),
        {noreply, #{misses := 5}} = shigoto_cron:handle_info(tick, #{misses => 4}),
        ?assertMatch(
            #{consecutive_misses := 5}, receive_log(~"shigoto_cron_lock_held_elsewhere")
        ),
        receive
            {lock_unavailable, #{consecutive_misses := 5}, #{lock := cron}} -> ok
        after 2000 -> ct:fail(no_lock_telemetry)
        end
    after
        telemetry:detach(lock_unavailable),
        shigoto_log_probe:detach(),
        Holder ! stop,
        flush_ticks()
    end.

cron_does_not_warn_while_a_peer_schedules(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    Holder = hold_lock(?CRON_LOCK_ID),
    try
        in_one_minute(
            fun() ->
                {ok, Now} = shigoto_repo:current_minute(?POOL),
                Previous = calendar:gregorian_seconds_to_datetime(
                    calendar:datetime_to_gregorian_seconds(Now) - 60
                ),
                ok = shigoto_repo:upsert_cron_entry(?POOL, #{
                    name => ~"every_minute",
                    worker => shigoto_test_worker,
                    schedule => ~"* * * * *",
                    last_scheduled_at => Previous
                }),
                shigoto_cron:handle_info(tick, #{misses => 4})
            end,
            fun(Answer) -> ?assertEqual({noreply, #{misses => 0}}, Answer) end
        )
    after
        Holder ! stop,
        flush_ticks()
    end.

stager_warns_when_its_lock_is_held_elsewhere(_Config) ->
    application:set_env(shigoto, stage_interval, 60000),
    Holder = hold_lock(?STAGE_LOCK_ID),
    ok = shigoto_log_probe:attach(),
    try
        {noreply, #{misses := 9}} = shigoto_stager:handle_info(stage, #{misses => 8}),
        refute_log(~"shigoto_stager_lock_held_elsewhere"),
        {noreply, #{misses := 10}} = shigoto_stager:handle_info(stage, #{misses => 9}),
        ?assertMatch(
            #{consecutive_misses := 10}, receive_log(~"shigoto_stager_lock_held_elsewhere")
        )
    after
        shigoto_log_probe:detach(),
        application:unset_env(shigoto, stage_interval),
        Holder ! stop,
        flush_ticks()
    end.

cron_pass_refuses_an_open_transaction(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    ?assertEqual(
        {error, in_transaction}, shigoto:transaction(fun shigoto_cron:schedule_once/0)
    ),
    ?assertEqual([], jobs()).

cron_skips_a_bad_entry(_Config) ->
    set_cron([
        {~"good", ~"* * * * *", shigoto_test_worker, #{~"n" => 1}},
        {~"bad", ~"* * * * *", shigoto_test_worker, #{~"at" => {2026, 1, 1}}}
    ]),
    ok = shigoto_log_probe:attach(),
    try
        ok = shigoto_cron:schedule_once(),
        ?assertMatch(
            #{name := ~"bad", reason := invalid_args}, receive_log(~"shigoto_cron_entry_skipped")
        )
    after
        shigoto_log_probe:detach()
    end,
    ?assertMatch([#{worker := ~"shigoto_test_worker"}], jobs()),
    ?assertMatch([#{name := ~"good"}], cron_rows()).

cron_warns_once_per_skipped_entry(_Config) ->
    set_cron([{~"warn_once", ~"not a schedule", shigoto_test_worker, #{}}]),
    Self = self(),
    ok = telemetry:attach(
        warn_once,
        [shigoto, cron, skipped],
        fun(_Event, _Measurements, Metadata, _HandlerConfig) -> Self ! {skipped, Metadata} end,
        undefined
    ),
    ok = shigoto_log_probe:attach(),
    try
        ok = shigoto_cron:schedule_once(),
        ok = shigoto_cron:schedule_once(),
        ?assertMatch(#{name := ~"warn_once"}, receive_log(~"shigoto_cron_entry_skipped")),
        receive
            {log, _, #{msg := ~"shigoto_cron_entry_skipped"}} -> ct:fail(warned_twice)
        after 500 -> ok
        end,
        ?assertEqual(2, length(receive_all_skipped()))
    after
        shigoto_log_probe:detach(),
        telemetry:detach(warn_once)
    end.

receive_all_skipped() ->
    receive
        {skipped, #{name := ~"warn_once"} = Metadata} -> [Metadata | receive_all_skipped()]
    after 0 -> []
    end.

cron_skips_a_worker_whose_defaults_overflow(_Config) ->
    set_cron([
        {~"good", ~"* * * * *", shigoto_test_worker, #{}},
        {~"overflow", ~"* * * * *", shigoto_overflow_worker, #{}}
    ]),
    Self = self(),
    ok = telemetry:attach(
        skipped,
        [shigoto, cron, skipped],
        fun(_Event, _Measurements, Metadata, _HandlerConfig) -> Self ! {skipped, Metadata} end,
        undefined
    ),
    try
        ok = shigoto_cron:schedule_once(),
        receive
            {skipped, Metadata} ->
                ?assertMatch(
                    #{name := ~"overflow", reason := {invalid_worker_defaults, [max_attempts]}},
                    Metadata
                )
        after 2000 -> ct:fail(no_skipped_telemetry)
        end
    after
        telemetry:detach(skipped)
    end,
    ?assertMatch([#{worker := ~"shigoto_test_worker"}], jobs()),
    ?assertMatch([#{name := ~"good"}], cron_rows()).

cron_reports_a_failed_pass(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    #{} = shigoto_db:query(?POOL, ~"ALTER TABLE shigoto_cron RENAME TO shigoto_cron_away", []),
    try
        ?assertEqual({error, pass_failed}, shigoto_cron:schedule_once())
    after
        #{} = shigoto_db:query(?POOL, ~"ALTER TABLE shigoto_cron_away RENAME TO shigoto_cron", [])
    end.

cron_resets_a_last_run_far_ahead(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{}}]),
    ok = shigoto_repo:upsert_cron_entry(?POOL, #{
        name => ~"every_minute",
        worker => shigoto_test_worker,
        schedule => ~"* * * * *",
        last_scheduled_at => {{2099, 1, 1}, {0, 0, 0}}
    }),
    ok = shigoto_log_probe:attach(),
    try
        ok = shigoto_cron:schedule_once(),
        ?assertMatch(
            #{name := ~"every_minute", last_scheduled_at := {{2099, 1, 1}, _}},
            receive_log(~"shigoto_cron_last_run_in_future")
        ),
        [#{last_scheduled_at := Stored}] = cron_rows(),
        {ok, Now} = shigoto_repo:current_minute(?POOL),
        ?assert(Stored =< Now andalso Stored >= minutes_ago(2))
    after
        shigoto_log_probe:detach()
    end.

cron_encrypts_entry_args(_Config) ->
    set_cron([{~"every_minute", ~"* * * * *", shigoto_test_worker, #{~"secret" => ~"hunter2"}}]),
    application:set_env(shigoto, encryption_key, crypto:strong_rand_bytes(32)),
    try
        ok = shigoto_cron:schedule_once(),
        case shigoto_db:query(?POOL, ~"SELECT args::text AS args FROM shigoto_cron", []) of
            #{rows := [#{args := Stored}]} when is_binary(Stored) ->
                ?assertEqual(nomatch, binary:match(Stored, ~"hunter2"))
        end
    after
        application:unset_env(shigoto, encryption_key)
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

%% Runs Observe within one database minute, starting over (at most three
%% times) when the minute turns while it runs, then checks what it saw.
in_one_minute(Observe, Check) ->
    in_one_minute(Observe, Check, 3).

in_one_minute(_Observe, _Check, 0) ->
    {skip, minute_kept_turning};
in_one_minute(Observe, Check, Tries) ->
    {ok, Before} = shigoto_repo:current_minute(?POOL),
    Seen = Observe(),
    case shigoto_repo:current_minute(?POOL) of
        {ok, Before} ->
            Check(Seen);
        {ok, _Turned} ->
            #{} = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
            #{} = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_cron", []),
            in_one_minute(Observe, Check, Tries - 1)
    end.

hold_lock(Lock) ->
    Self = self(),
    Holder = spawn_link(fun() ->
        shigoto_db:transaction(?POOL, fun() ->
            true = shigoto_repo:try_advisory_xact_lock(?POOL, Lock),
            Self ! holding,
            receive
                stop -> ok
            end
        end)
    end),
    receive
        holding -> Holder
    after 5000 -> ct:fail(lock_not_taken)
    end.

attach_lock_telemetry() ->
    Self = self(),
    telemetry:attach(
        lock_unavailable,
        [shigoto, leader_lock, unavailable],
        fun(_Event, Measurements, Metadata, _HandlerConfig) ->
            Self ! {lock_unavailable, Measurements, Metadata}
        end,
        undefined
    ).

refute_log(Msg) ->
    receive
        {log, _Level, #{msg := Msg}} -> ct:fail({unexpected_log, Msg})
    after 200 -> ok
    end.

flush_ticks() ->
    receive
        tick -> flush_ticks();
        stage -> flush_ticks()
    after 0 -> ok
    end.

receive_log(Msg) ->
    receive
        {log, _Level, #{msg := Msg} = Report} -> Report
    after 2000 -> ct:fail({no_log, Msg})
    end.

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
