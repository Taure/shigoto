-module(shigoto_integration_SUITE).
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
    test_insert_and_claim/1,
    test_job_execution_success/1,
    test_job_execution_failure/1,
    test_cancel_job/1,
    test_retry_job/1,
    test_drain_queue/1,
    test_migration/1,
    test_prune_old_jobs/1,
    test_unique_prevents_duplicate/1,
    test_unique_different_args_allowed/1,
    test_unique_period_expiry/1,
    test_unique_states_filter/1,
    test_unique_replace_fields/1,
    test_unique_worker_callback/1,
    test_unique_opts_override/1,
    test_unique_different_queues_allowed/1,
    test_unique_key_stored/1,
    test_unique_concurrent_insert/1,
    test_non_unique_has_null_key/1,
    test_worker_defaults_applied/1,
    test_worker_defaults_overridden/1,
    test_worker_defaults_partial/1,
    test_job_timeout/1,
    test_cancel_executing_job/1,
    test_snooze_job/1,
    test_transaction_commit/1,
    test_transaction_rollback/1,
    test_transaction_telemetry_deferred/1,
    test_transaction_commit_rollback_no_telemetry/1,
    test_transaction_nested/1,
    test_transaction_pool_option/1,
    test_insert_conflict_no_crash/1,
    test_prune_archive/1,
    test_cancel_no_pool/1,
    test_cancel_by_no_pool/1,
    test_retry_no_pool/1,
    test_retry_by_no_pool/1,
    test_cancel_by_in_transaction/1,
    test_global_concurrency_single_admitted/1,
    test_global_concurrency_admits_one_of_two/1,
    test_global_concurrency_admits_two_of_three/1,
    test_stager_surfaces_due_queue/1,
    test_stager_ignores_not_yet_due/1,
    test_stager_stage_once_fails_soft/1
]).

-define(POOL, shigoto_test_pool).

all() ->
    [
        test_migration,
        test_insert_and_claim,
        test_job_execution_success,
        test_job_execution_failure,
        test_cancel_job,
        test_retry_job,
        test_drain_queue,
        test_prune_old_jobs,
        test_unique_prevents_duplicate,
        test_unique_different_args_allowed,
        test_unique_period_expiry,
        test_unique_states_filter,
        test_unique_replace_fields,
        test_unique_worker_callback,
        test_unique_opts_override,
        test_unique_different_queues_allowed,
        test_unique_key_stored,
        test_unique_concurrent_insert,
        test_non_unique_has_null_key,
        test_worker_defaults_applied,
        test_worker_defaults_overridden,
        test_worker_defaults_partial,
        test_job_timeout,
        test_cancel_executing_job,
        test_snooze_job,
        test_transaction_commit,
        test_transaction_rollback,
        test_transaction_telemetry_deferred,
        test_transaction_commit_rollback_no_telemetry,
        test_transaction_nested,
        test_transaction_pool_option,
        test_insert_conflict_no_crash,
        test_prune_archive,
        test_cancel_no_pool,
        test_cancel_by_no_pool,
        test_retry_no_pool,
        test_retry_by_no_pool,
        test_cancel_by_in_transaction,
        test_global_concurrency_single_admitted,
        test_global_concurrency_admits_one_of_two,
        test_global_concurrency_admits_two_of_three,
        test_stager_surfaces_due_queue,
        test_stager_ignores_not_yet_due,
        test_stager_stage_once_fails_soft
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(shigoto_test_pool),
    Config.

end_per_suite(_Config) ->
    shigoto_migration:down(?POOL),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup_jobs(),
    ok.

%%----------------------------------------------------------------------
%% Core tests
%%----------------------------------------------------------------------

test_migration(_Config) ->
    %% Fresh start to ensure pgo type cache matches schema
    shigoto_migration:down(?POOL),
    ok = shigoto_migration:up(?POOL),
    %% Idempotent
    ok = shigoto_migration:up(?POOL).

test_insert_and_claim(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    ?assertMatch(#{worker := <<"shigoto_test_worker">>}, Job),

    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual(maps:get(id, Job), maps:get(id, Claimed)),
    ?assertEqual(<<"executing">>, maps:get(state, Claimed)).

test_job_execution_success(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ok = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 1).

test_job_execution_failure(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"fail"}
        },
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    {error, _} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000).

test_cancel_job(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    ok = shigoto_repo:cancel_job(?POOL, maps:get(id, Job)),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 1).

test_retry_job(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    ok = shigoto_repo:cancel_job(?POOL, maps:get(id, Job)),
    ok = shigoto_repo:retry_job(?POOL, maps:get(id, Job)),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual(maps:get(id, Job), maps:get(id, Claimed)).

test_drain_queue(_Config) ->
    shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    ok = shigoto:drain_queue(~"default"),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 10).

test_prune_old_jobs(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{~"action" => ~"succeed"}
        },
        #{}
    ),
    shigoto_repo:complete_job(?POOL, maps:get(id, Job)),
    {ok, Count} = shigoto_repo:prune_jobs(?POOL, 0),
    ?assert(Count >= 1).

%%----------------------------------------------------------------------
%% Unique job tests
%%----------------------------------------------------------------------

test_unique_prevents_duplicate(_Config) ->
    Unique = #{keys => [worker, args], states => [available, executing]},
    Params = #{worker => shigoto_test_worker, args => #{~"x" => 1}},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    {ok, {conflict, Job2}} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_different_args_allowed(_Config) ->
    Unique = #{keys => [worker, args]},
    {ok, Job1} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{~"x" => 1}},
        #{unique => Unique}
    ),
    {ok, Job2} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{~"x" => 2}},
        #{unique => Unique}
    ),
    ?assertNotEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_period_expiry(_Config) ->
    Unique = #{keys => [worker, args], period => 1},
    Params = #{worker => shigoto_test_worker, args => #{~"x" => 1}},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    timer:sleep(1500),
    {ok, Job2} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertNotEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_states_filter(_Config) ->
    %% Only check available state
    Unique = #{keys => [worker, args], states => [available]},
    Params = #{worker => shigoto_test_worker, args => #{~"x" => 1}},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    %% Complete the job so it's no longer in 'available' state
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    shigoto_repo:complete_job(?POOL, maps:get(id, Claimed)),
    %% Now insert again — should succeed since completed is not in states
    {ok, Job2} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertNotEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_replace_fields(_Config) ->
    Unique = #{keys => [worker, args], replace => [priority]},
    Params = #{worker => shigoto_test_worker, args => #{~"x" => 1}, priority => 1},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertEqual(1, maps:get(priority, Job1)),
    %% Insert again with different priority — should update
    Params2 = Params#{priority => 10},
    {ok, {conflict, Updated}} = shigoto_repo:insert_job(?POOL, Params2, #{unique => Unique}),
    ?assertEqual(maps:get(id, Job1), maps:get(id, Updated)),
    ?assertEqual(10, maps:get(priority, Updated)).

test_unique_worker_callback(_Config) ->
    %% shigoto_unique_worker defines unique/0
    Params = #{worker => shigoto_unique_worker, args => #{~"a" => 1}},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{}),
    {ok, {conflict, Job2}} = shigoto_repo:insert_job(?POOL, Params, #{}),
    ?assertEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_opts_override(_Config) ->
    %% shigoto_unique_worker defines unique/0 with period=300
    %% Override with period=1 via opts
    Params = #{worker => shigoto_unique_worker, args => #{~"a" => 1}},
    Unique = #{keys => [worker, args], period => 1},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    timer:sleep(1500),
    {ok, Job2} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertNotEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_different_queues_allowed(_Config) ->
    %% shigoto_unique_queue_worker uses keys => [worker, queue]
    Params1 = #{worker => shigoto_unique_queue_worker, args => #{}, queue => ~"queue_a"},
    Params2 = #{worker => shigoto_unique_queue_worker, args => #{}, queue => ~"queue_b"},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params1, #{}),
    {ok, Job2} = shigoto_repo:insert_job(?POOL, Params2, #{}),
    ?assertNotEqual(maps:get(id, Job1), maps:get(id, Job2)).

test_unique_key_stored(_Config) ->
    Unique = #{keys => [worker, args]},
    Params = #{worker => shigoto_test_worker, args => #{~"x" => 1}},
    {ok, Job} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ?assertNotEqual(null, maps:get(unique_key, Job)).

test_unique_concurrent_insert(_Config) ->
    Unique = #{keys => [worker, args]},
    Params = #{worker => shigoto_test_worker, args => #{~"concurrent" => true}},
    Self = self(),
    Insert = fun() ->
        Result = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
        Self ! {done, self(), Result}
    end,
    Pid1 = spawn(Insert),
    Pid2 = spawn(Insert),
    R1 =
        receive
            {done, Pid1, Res1} -> Res1
        after 5000 -> timeout
        end,
    R2 =
        receive
            {done, Pid2, Res2} -> Res2
        after 5000 -> timeout
        end,
    %% One should be {ok, Job} and the other {ok, {conflict, Job}}
    Results = [R1, R2],
    Inserts = [R || {ok, M} = R <- Results, is_map(M)],
    Conflicts = [R || {ok, {conflict, _}} = R <- Results],
    ?assertEqual(1, length(Inserts)),
    ?assertEqual(1, length(Conflicts)).

test_non_unique_has_null_key(_Config) ->
    %% Non-unique jobs should have null unique_key
    Params = #{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}},
    {ok, Job} = shigoto_repo:insert_job(?POOL, Params, #{}),
    ?assertEqual(null, maps:get(unique_key, Job)).

%%----------------------------------------------------------------------
%% Snooze tests
%%----------------------------------------------------------------------

test_snooze_job(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_snooze_worker, args => #{}},
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    {snooze, 60} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    %% Job should be back to available but scheduled in the future
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 1).

%%----------------------------------------------------------------------
%% Timeout tests
%%----------------------------------------------------------------------

test_cancel_executing_job(_Config) ->
    %% Create ETS table and start executor supervisor for this test
    {ok, SupPid} = shigoto_executor_sup:start_link(),
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_timeout_worker, args => #{}},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    %% Start async executor
    {ok, ExecPid} = shigoto_executor_sup:start_executor(Claimed, ?POOL, self()),
    ExecRef = monitor(process, ExecPid),
    timer:sleep(100),
    %% Cancel while executing — should kill the executor and update DB
    ok = shigoto:cancel(?POOL, JobId),
    receive
        {'DOWN', ExecRef, process, ExecPid, _} -> ok
    after 2000 -> ct:fail(executor_not_stopped)
    end,
    %% Cleanup
    unlink(SupPid),
    exit(SupPid, shutdown).

test_job_timeout(_Config) ->
    %% shigoto_timeout_worker has timeout() -> 500 but sleeps 5s
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_timeout_worker, args => #{}},
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    {error, timeout} = shigoto_executor:execute_sync(Claimed, ?POOL, 500).

%%----------------------------------------------------------------------
%% Worker config tests
%%----------------------------------------------------------------------

test_worker_defaults_applied(_Config) ->
    %% shigoto_configured_worker defines max_attempts=7, queue=priority_queue, priority=5
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_configured_worker, args => #{}},
        #{}
    ),
    ?assertEqual(7, maps:get(max_attempts, Job)),
    ?assertEqual(<<"priority_queue">>, maps:get(queue, Job)),
    ?assertEqual(5, maps:get(priority, Job)).

test_worker_defaults_overridden(_Config) ->
    %% Per-insert params override worker defaults
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_configured_worker,
            args => #{},
            max_attempts => 1,
            queue => ~"custom",
            priority => 99
        },
        #{}
    ),
    ?assertEqual(1, maps:get(max_attempts, Job)),
    ?assertEqual(<<"custom">>, maps:get(queue, Job)),
    ?assertEqual(99, maps:get(priority, Job)).

test_worker_defaults_partial(_Config) ->
    %% Worker without optional callbacks uses system defaults
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}},
        #{}
    ),
    ?assertEqual(3, maps:get(max_attempts, Job)),
    ?assertEqual(<<"default">>, maps:get(queue, Job)),
    ?assertEqual(0, maps:get(priority, Job)).

test_transaction_commit(_Config) ->
    Result = shigoto:transaction(fun() ->
        {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"n" => 1}}),
        {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"n" => 2}}),
        done
    end),
    ?assertEqual(done, Result),
    ?assertEqual(2, count_jobs()).

test_transaction_rollback(_Config) ->
    ?assertError(
        boom,
        shigoto:transaction(fun() ->
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"n" => 1}}),
            erlang:error(boom)
        end)
    ),
    ?assertEqual(0, count_jobs()).

test_transaction_telemetry_deferred(_Config) ->
    Handler = {?MODULE, telemetry_deferred},
    ok = telemetry:attach(
        Handler,
        [shigoto, job, inserted],
        fun(_Event, _Measure, Meta, Pid) -> Pid ! {job_inserted, Meta} end,
        self()
    ),
    try
        %% Rolled-back inserts must not emit telemetry.
        try
            shigoto:transaction(fun() ->
                {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
                erlang:error(boom)
            end)
        catch
            error:boom -> ok
        end,
        ?assertEqual(
            timeout,
            receive
                {job_inserted, _} -> got
            after 200 -> timeout
            end
        ),
        %% Committed inserts emit once, after commit.
        done = shigoto:transaction(fun() ->
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
            done
        end),
        ?assertMatch(
            {job_inserted, _},
            receive
                M -> M
            after 1000 -> timeout
            end
        )
    after
        telemetry:detach(Handler)
    end.

test_insert_conflict_no_crash(_Config) ->
    Unique = #{keys => [worker, args], states => [available], period => infinity},
    Params = #{worker => shigoto_test_worker, args => #{~"id" => 1}},
    {ok, Job} = shigoto:insert(Params, #{unique => Unique}),
    ?assert(is_map(Job)),
    ?assertMatch({ok, {conflict, _}}, shigoto:insert(Params, #{unique => Unique})),
    ?assertEqual(1, count_jobs()).

test_transaction_commit_rollback_no_telemetry(_Config) ->
    Handler = {?MODULE, commit_rollback},
    ok = telemetry:attach(
        Handler,
        [shigoto, job, inserted],
        fun(_Event, _Measure, Meta, Pid) -> Pid ! {job_inserted, Meta} end,
        self()
    ),
    try
        ?assertError(
            transaction_rolled_back,
            shigoto:transaction(fun() ->
                {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
                {error, _} = pgo:query(~"select 1/0", [], #{pool => ?POOL}),
                done
            end)
        ),
        ?assertEqual(0, count_jobs()),
        ?assertEqual(
            timeout,
            receive
                {job_inserted, _} -> got
            after 200 -> timeout
            end
        )
    after
        telemetry:detach(Handler)
    end.

test_transaction_nested(_Config) ->
    Handler = {?MODULE, nested},
    ok = telemetry:attach(
        Handler,
        [shigoto, job, inserted],
        fun(_Event, _Measure, _Meta, Pid) -> Pid ! job_inserted end,
        self()
    ),
    try
        ok = shigoto:transaction(fun() ->
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"n" => 1}}),
            ok = shigoto:transaction(fun() ->
                {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"n" => 2}}),
                ok
            end)
        end),
        ?assertEqual(2, count_jobs()),
        ?assertEqual(2, drain_inserted(0))
    after
        telemetry:detach(Handler)
    end.

test_transaction_pool_option(_Config) ->
    Pool2 = start_pool2(),
    ok = shigoto:transaction(
        fun() ->
            {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"p" => 2}}),
            ok
        end,
        #{pool => Pool2}
    ),
    ?assertEqual(1, count_jobs()),
    cleanup_jobs(),
    %% Rolling back the transaction on Pool2 must discard the insert. If insert had
    %% resolved the default pool instead of the transaction's, it could not
    %% participate in Pool2's transaction and the row would survive.
    ?assertError(
        rollback_marker,
        shigoto:transaction(
            fun() ->
                {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{}}),
                error(rollback_marker)
            end,
            #{pool => Pool2}
        )
    ),
    ?assertEqual(0, count_jobs()).

test_prune_archive(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    shigoto_repo:complete_job(?POOL, maps:get(id, Job)),
    {ok, _} = shigoto_repo:archive_jobs(?POOL, 0),
    ?assertEqual(1, count_archive()),
    %% A just-archived row is within the retention window and must survive.
    {ok, 0} = shigoto_repo:prune_archive(?POOL, 90),
    ?assertEqual(1, count_archive()),
    %% With a zero-day window it is past retention and deleted.
    {ok, 1} = shigoto_repo:prune_archive(?POOL, 0),
    ?assertEqual(0, count_archive()).

%%----------------------------------------------------------------------
%% Pool-less API tests
%%----------------------------------------------------------------------

test_cancel_no_pool(_Config) ->
    {ok, Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}),
    ok = shigoto:cancel(maps:get(id, Job)),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 1).

test_cancel_by_no_pool(_Config) ->
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}),
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}),
    {ok, Count} = shigoto:cancel_by(#{worker => shigoto_test_worker}),
    ?assertEqual(2, Count),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 10).

test_retry_no_pool(_Config) ->
    {ok, Job} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}),
    JobId = maps:get(id, Job),
    ok = shigoto:cancel(JobId),
    ok = shigoto:retry(JobId),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual(JobId, maps:get(id, Claimed)).

test_retry_by_no_pool(_Config) ->
    {ok, _} = shigoto:insert(#{worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}}),
    {ok, _} = shigoto:cancel_by(#{worker => shigoto_test_worker}),
    {ok, Count} = shigoto:retry_by(#{worker => shigoto_test_worker}),
    ?assertEqual(1, Count),
    {ok, [_]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10).

test_cancel_by_in_transaction(_Config) ->
    ok = shigoto:transaction(fun() ->
        {ok, _} = shigoto:insert(#{
            worker => shigoto_test_worker, args => #{~"action" => ~"succeed"}
        }),
        {ok, 1} = shigoto:cancel_by(#{worker => shigoto_test_worker}),
        ok
    end),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, ~"default", 10).

%%----------------------------------------------------------------------
%% Global concurrency tests
%%----------------------------------------------------------------------

test_global_concurrency_single_admitted(_Config) ->
    %% Off-by-one regression: a single claimed job is at exactly the limit
    %% (its own row is already 'executing'), so it must be admitted, not snoozed.
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_global_conc_worker, args => #{~"n" => 1}}, #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual(
        ok, shigoto_resilience:check_global_concurrency(shigoto_global_conc_worker, Claimed)
    ).

test_global_concurrency_admits_one_of_two(_Config) ->
    %% Livelock regression: two jobs claimed concurrently (both 'executing')
    %% under a limit of 1 must resolve to exactly one admitted and one snoozed,
    %% never both snoozed (which would oscillate available -> executing -> snooze).
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_global_conc_worker, args => #{~"n" => 1}}, #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_global_conc_worker, args => #{~"n" => 2}}, #{}
    ),
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, ~"default", 2),
    ?assertEqual(2, length(Claimed)),
    Results = [
        shigoto_resilience:check_global_concurrency(shigoto_global_conc_worker, J)
     || J <- Claimed
    ],
    Admitted = [R || R <- Results, R =:= ok],
    Snoozed = [R || R <- Results, is_tuple(R) andalso element(1, R) =:= snooze],
    ?assertEqual(1, length(Admitted)),
    ?assertEqual(1, length(Snoozed)).

test_global_concurrency_admits_two_of_three(_Config) ->
    %% Boundary at limit > 1: three jobs claimed under a limit of 2 must resolve
    %% to exactly two admitted and one snoozed.
    [
        shigoto_repo:insert_job(
            ?POOL, #{worker => shigoto_global_conc2_worker, args => #{~"n" => N}}, #{}
        )
     || N <- [1, 2, 3]
    ],
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, ~"default", 3),
    ?assertEqual(3, length(Claimed)),
    Results = [
        shigoto_resilience:check_global_concurrency(shigoto_global_conc2_worker, J)
     || J <- Claimed
    ],
    Admitted = [R || R <- Results, R =:= ok],
    Snoozed = [R || R <- Results, is_tuple(R) andalso element(1, R) =:= snooze],
    ?assertEqual(2, length(Admitted)),
    ?assertEqual(1, length(Snoozed)).

%%----------------------------------------------------------------------
%% Stager tests
%%----------------------------------------------------------------------

test_stager_surfaces_due_queue(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            queue => ~"soon",
            scheduled_at => seconds_from_now(1)
        },
        #{}
    ),
    {ok, Before} = shigoto_stager:due_queues(?POOL),
    ?assertNot(lists:member(~"soon", Before)),
    timer:sleep(1200),
    {ok, After} = shigoto_stager:due_queues(?POOL),
    ?assert(lists:member(~"soon", After)).

test_stager_ignores_not_yet_due(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, queue => ~"ready"},
        #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            queue => ~"later",
            scheduled_at => seconds_from_now(3600)
        },
        #{}
    ),
    {ok, Queues} = shigoto_stager:due_queues(?POOL),
    ?assert(lists:member(~"ready", Queues)),
    ?assertNot(lists:member(~"later", Queues)).

test_stager_stage_once_fails_soft(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, queue => ~"stager_once"},
        #{}
    ),
    ?assertEqual(ok, shigoto_stager:stage_once()).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

seconds_from_now(Seconds) ->
    Secs = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    calendar:gregorian_seconds_to_datetime(Secs + Seconds).

drain_inserted(N) ->
    receive
        job_inserted -> drain_inserted(N + 1)
    after 300 -> N
    end.

start_pool2() ->
    Pool2 = shigoto_test_pool2,
    case
        pgo:start_pool(Pool2, #{
            host => "localhost",
            port => 5556,
            database => "shigoto_test",
            user => "postgres",
            password => "root",
            pool_size => 2
        })
    of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    Pool2.

cleanup_jobs() ->
    pgo:query(~"DELETE FROM shigoto_jobs", [], #{pool => ?POOL}),
    pgo:query(~"DELETE FROM shigoto_jobs_archive", [], #{pool => ?POOL}),
    ok.

count_jobs() ->
    count(~"SELECT count(*) AS count FROM shigoto_jobs").

count_archive() ->
    count(~"SELECT count(*) AS count FROM shigoto_jobs_archive").

count(SQL) ->
    #{rows := [#{count := N}]} = pgo:query(
        SQL,
        [],
        #{pool => ?POOL, decode_opts => [return_rows_as_maps, column_name_as_atom]}
    ),
    N.
