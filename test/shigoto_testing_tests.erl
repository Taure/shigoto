-module(shigoto_testing_tests).
-include_lib("eunit/include/eunit.hrl").

%% These tests run with NO database — that is the whole point of the module.

arm(Mode) ->
    application:set_env(shigoto, testing, Mode),
    application:set_env(shigoto, testing_confirm_no_persistence, true),
    shigoto_testing:reset().

disarm() ->
    application:unset_env(shigoto, testing),
    application:unset_env(shigoto, testing_confirm_no_persistence),
    shigoto_testing:reset().

%%----------------------------------------------------------------------
%% perform_job — no mode needed
%%----------------------------------------------------------------------

perform_job_ok_test() ->
    ?assertEqual(ok, shigoto:perform_job(shigoto_test_worker, #{~"action" => ~"succeed"})).

perform_job_error_test() ->
    ?assertEqual(
        {error, deliberate_failure},
        shigoto:perform_job(shigoto_test_worker, #{~"action" => ~"fail"})
    ).

perform_job_crash_is_error_test() ->
    ?assertMatch(
        {error, _}, shigoto:perform_job(shigoto_test_worker, #{~"action" => ~"crash"})
    ).

perform_job_result_test() ->
    ?assertEqual(
        {ok, #{~"produced" => 42}},
        shigoto:perform_job(shigoto_result_worker, #{~"action" => ~"produce", ~"value" => 42})
    ).

perform_job_deps_results_test() ->
    Result = shigoto:perform_job(
        shigoto_result_worker,
        #{~"action" => ~"consume"},
        #{deps_results => #{41 => #{~"n" => 7}}}
    ),
    ?assertEqual({ok, #{~"got" => #{~"n" => 7}}}, Result).

perform_job_snooze_test() ->
    ?assertEqual({snooze, 60}, shigoto:perform_job(shigoto_snooze_worker, #{})).

perform_job_undefined_worker_test() ->
    ?assertError(
        {undefined_worker_perform, no_such_worker_xyz},
        shigoto:perform_job(no_such_worker_xyz, #{})
    ).

%%----------------------------------------------------------------------
%% manual mode + assertions
%%----------------------------------------------------------------------

manual_capture_test_() ->
    {setup, fun() -> arm(manual) end, fun(_) -> disarm() end, [
        fun manual_captures_without_persisting/0,
        fun manual_assert_and_refute/0,
        fun manual_args_match/0,
        fun manual_reset_clears/0,
        fun manual_insert_all_captures/0,
        fun manual_scheduled_state/0,
        fun manual_unknown_filter_key_raises/0
    ]}.

manual_captures_without_persisting() ->
    ?assertMatch(
        {ok, #{state := ~"available", worker := ~"shigoto_test_worker"}},
        shigoto:insert(#{worker => shigoto_test_worker, args => #{~"x" => 1}})
    ),
    ?assertEqual(1, length(shigoto_testing:all_enqueued())).

manual_assert_and_refute() ->
    shigoto_testing:reset(),
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}, queue => ~"emails"}),
    ok = shigoto_testing:assert_enqueued(#{worker => shigoto_test_worker}),
    ok = shigoto_testing:assert_enqueued(#{queue => ~"emails"}),
    ok = shigoto_testing:refute_enqueued(#{queue => ~"sms"}),
    ?assertError({assert_enqueued, _, _}, shigoto_testing:assert_enqueued(#{worker => nope})),
    ?assertError(
        {refute_enqueued, _, _}, shigoto_testing:refute_enqueued(#{worker => shigoto_test_worker})
    ).

manual_args_match() ->
    shigoto_testing:reset(),
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"id" => 5, ~"k" => ~"v"}}),
    ok = shigoto_testing:assert_enqueued(#{args => #{~"id" => 5}}),
    ok = shigoto_testing:refute_enqueued(#{args => #{~"id" => 6}}).

manual_reset_clears() ->
    shigoto_testing:reset(),
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
    ?assertEqual(1, length(shigoto_testing:all_enqueued())),
    shigoto_testing:reset(),
    ?assertEqual(0, length(shigoto_testing:all_enqueued())).

manual_insert_all_captures() ->
    shigoto_testing:reset(),
    {ok, Jobs} = shigoto:insert_all([
        #{worker => shigoto_test_worker, args => #{~"i" => 1}},
        #{worker => shigoto_test_worker, args => #{~"i" => 2}}
    ]),
    ?assertEqual(2, length(Jobs)),
    ?assertEqual(2, length(shigoto_testing:all_enqueued())).

manual_scheduled_state() ->
    shigoto_testing:reset(),
    {ok, _} = shigoto:insert(#{
        worker => shigoto_test_worker, args => #{}, scheduled_at => {{2099, 1, 1}, {0, 0, 0}}
    }),
    ok = shigoto_testing:assert_enqueued(#{state => ~"scheduled"}),
    ok = shigoto_testing:refute_enqueued(#{state => ~"available"}).

manual_unknown_filter_key_raises() ->
    ?assertError(
        {unknown_filter_key, [workr]}, shigoto_testing:assert_enqueued(#{workr => nope})
    ).

%%----------------------------------------------------------------------
%% inline mode
%%----------------------------------------------------------------------

inline_mode_test_() ->
    {setup, fun() -> arm(inline) end, fun(_) -> disarm() end, [
        fun inline_runs_and_completes/0,
        fun inline_result_payload/0,
        fun inline_insert_all_runs_each/0,
        fun inline_failure_raises/0,
        fun inline_snooze_scheduled/0
    ]}.

inline_runs_and_completes() ->
    ?assertMatch(
        {ok, #{state := ~"completed"}},
        shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}})
    ).

inline_result_payload() ->
    ?assertMatch(
        {ok, #{state := ~"completed", result := #{~"produced" := 42}}},
        shigoto:insert(#{
            worker => shigoto_result_worker, args => #{~"action" => ~"produce", ~"value" => 42}
        })
    ).

inline_insert_all_runs_each() ->
    ?assertMatch(
        {ok, [#{state := ~"completed"}, #{state := ~"completed"}]},
        shigoto:insert_all([
            #{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}},
            #{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}
        ])
    ).

inline_failure_raises() ->
    ?assertError(
        {shigoto_inline_job_failed, shigoto_test_worker, deliberate_failure},
        shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"fail"}})
    ).

inline_snooze_scheduled() ->
    ?assertMatch(
        {ok, #{state := ~"scheduled", snooze := 60}},
        shigoto:insert(#{worker => shigoto_snooze_worker, args => #{}})
    ).

%%----------------------------------------------------------------------
%% fail-safe: a mode without the confirmation key does NOT arm
%%----------------------------------------------------------------------

testing_mode_requires_confirmation_test() ->
    application:set_env(shigoto, testing, manual),
    application:unset_env(shigoto, testing_confirm_no_persistence),
    try
        ?assertEqual(disabled, shigoto_config:testing_mode())
    after
        application:unset_env(shigoto, testing)
    end.

testing_mode_disabled_by_default_test() ->
    application:unset_env(shigoto, testing),
    ?assertEqual(disabled, shigoto_config:testing_mode()).
