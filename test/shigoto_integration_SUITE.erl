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
    test_snooze_job/1
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
        test_snooze_job
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
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

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

cleanup_jobs() ->
    pgo:query(~"DELETE FROM shigoto_jobs", [], #{pool => ?POOL}),
    ok.
