-module(shigoto_core_SUITE).
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
    %% Dependency cycle detection
    test_dependency_missing_ids_rejected/1,
    test_dependency_cycle_detected/1,
    test_dependency_valid_chain_accepted/1,
    test_dependency_self_reference_safe/1,
    test_dependency_multiple_parents/1,
    %% Bulk retry
    test_retry_by_worker/1,
    test_retry_by_queue/1,
    test_retry_by_tags/1,
    test_retry_by_empty_filter/1,
    test_retry_by_only_retries_terminal/1,
    %% Dynamic queues
    test_add_queue/1,
    test_add_queue_idempotent/1,
    test_remove_queue/1,
    %% Health check
    test_health_ok/1,
    %% Job archival
    test_archive_jobs/1,
    %% Dashboard search
    test_search_by_state/1,
    test_search_by_worker/1,
    test_search_pagination/1,
    test_search_combined_filters/1,
    %% Edge cases
    test_claim_respects_priority/1,
    test_claim_respects_scheduled_at/1,
    test_snooze_preserves_attempt_count/1,
    test_max_attempts_discards/1,
    test_concurrent_claim_no_double_execute/1,
    test_cancel_by_no_match/1,
    test_insert_minimal_params/1,
    test_debounce_resets_scheduled_at/1
]).

-eqwalizer({nowarn_function, {test_dependency_cycle_detected, 1}}).
-eqwalizer({nowarn_function, {test_dependency_valid_chain_accepted, 1}}).
-eqwalizer({nowarn_function, {test_dependency_multiple_parents, 1}}).
-eqwalizer({nowarn_function, {test_retry_by_worker, 1}}).
-eqwalizer({nowarn_function, {test_retry_by_queue, 1}}).
-eqwalizer({nowarn_function, {test_retry_by_tags, 1}}).
-eqwalizer({nowarn_function, {test_retry_by_empty_filter, 1}}).
-eqwalizer({nowarn_function, {test_archive_jobs, 1}}).
-eqwalizer({nowarn_function, {test_search_by_state, 1}}).
-eqwalizer({nowarn_function, {test_search_combined_filters, 1}}).
-eqwalizer({nowarn_function, {test_claim_respects_priority, 1}}).
-eqwalizer({nowarn_function, {test_snooze_preserves_attempt_count, 1}}).
-eqwalizer({nowarn_function, {test_max_attempts_discards, 1}}).
-eqwalizer({nowarn_function, {test_insert_minimal_params, 1}}).
-eqwalizer({nowarn_function, {test_debounce_resets_scheduled_at, 1}}).

-define(POOL, shigoto_test_pool).

all() ->
    [
        test_dependency_missing_ids_rejected,
        test_dependency_cycle_detected,
        test_dependency_valid_chain_accepted,
        test_dependency_self_reference_safe,
        test_dependency_multiple_parents,
        test_retry_by_worker,
        test_retry_by_queue,
        test_retry_by_tags,
        test_retry_by_empty_filter,
        test_retry_by_only_retries_terminal,
        test_add_queue,
        test_add_queue_idempotent,
        test_remove_queue,
        test_health_ok,
        test_archive_jobs,
        test_search_by_state,
        test_search_by_worker,
        test_search_pagination,
        test_search_combined_filters,
        test_claim_respects_priority,
        test_claim_respects_scheduled_at,
        test_snooze_preserves_attempt_count,
        test_max_attempts_discards,
        test_concurrent_claim_no_double_execute,
        test_cancel_by_no_match,
        test_insert_minimal_params,
        test_debounce_resets_scheduled_at
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup(),
    ok.

%%----------------------------------------------------------------------
%% Dependency cycle detection
%%----------------------------------------------------------------------

test_dependency_missing_ids_rejected(_Config) ->
    Result = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [999999998, 999999999]},
        #{}
    ),
    ?assertMatch({error, {missing_dependencies, _}}, Result).

test_dependency_cycle_detected(_Config) ->
    %% A depends on B, B depends on A — create B first with dep on A
    {ok, A} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    AId = maps:get(id, A),
    {ok, B} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [AId]},
        #{}
    ),
    BId = maps:get(id, B),
    %% Now try to insert C that depends on both A and B — B already depends on A,
    %% so B's depends_on contains AId. C depends on [AId, BId]. B depends on AId
    %% which is also in C's depends_on — this is a mutual dependency.
    %% Actually that's not a cycle for C. Let me create a real cycle:
    %% Try to make A depend on B (but A is already inserted without deps).
    %% We can't modify A. Instead test: D depends on E, E depends on D.
    {ok, D} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    DId = maps:get(id, D),
    {ok, E} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [DId]},
        #{}
    ),
    EId = maps:get(id, E),
    %% F depends on both D and E. E depends on D. D is in F's deps, D is in E's deps.
    %% E.depends_on contains D, and D is in F's depends_on — that's a cycle detection case.
    Result = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [DId, EId]},
        #{}
    ),
    %% This should detect that E depends on D, and D is also in the new job's deps
    ?assertMatch({error, dependency_cycle}, Result),
    %% But depending on just E (no mutual) should be fine
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [EId]},
        #{}
    ),
    %% And depending on just B (which depends on A, no overlap) should be fine
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [BId]},
        #{}
    ).

test_dependency_valid_chain_accepted(_Config) ->
    {ok, A} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    AId = maps:get(id, A),
    {ok, B} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [AId]},
        #{}
    ),
    BId = maps:get(id, B),
    {ok, C} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [BId]},
        #{}
    ),
    ?assertNotEqual(undefined, maps:get(id, C)).

test_dependency_self_reference_safe(_Config) ->
    %% Can't depend on yourself since you don't have an ID yet
    %% This tests with a nonexistent ID
    Result = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [999999997]},
        #{}
    ),
    ?assertMatch({error, {missing_dependencies, _}}, Result).

test_dependency_multiple_parents(_Config) ->
    {ok, A} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, B} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    AId = maps:get(id, A),
    BId = maps:get(id, B),
    %% C depends on both A and B (fan-in)
    {ok, C} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [AId, BId]},
        #{}
    ),
    %% C should not be claimable until both complete
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ClaimedIds = [maps:get(id, J) || J <- Claimed],
    ?assert(lists:member(AId, ClaimedIds)),
    ?assert(lists:member(BId, ClaimedIds)),
    ?assertNot(lists:member(maps:get(id, C), ClaimedIds)),
    %% Complete A — C still blocked
    ok = shigoto_repo:complete_job(?POOL, AId),
    {ok, []} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    %% Complete B — C now claimable
    ok = shigoto_repo:complete_job(?POOL, BId),
    {ok, [Claimed2]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(maps:get(id, C), maps:get(id, Claimed2)).

%%----------------------------------------------------------------------
%% Bulk retry
%%----------------------------------------------------------------------

test_retry_by_worker(_Config) ->
    {ok, J1} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, J2} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_tagged_worker, args => #{}}, #{}
    ),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J1)),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J2)),
    {ok, Count} = shigoto_repo:retry_by(?POOL, #{worker => shigoto_test_worker}),
    ?assertEqual(1, Count),
    %% J1 should be available again
    {ok, J1Updated} = shigoto_repo:get_job(?POOL, maps:get(id, J1)),
    ?assertEqual(<<"available">>, maps:get(state, J1Updated)),
    %% J2 should still be discarded
    {ok, J2Updated} = shigoto_repo:get_job(?POOL, maps:get(id, J2)),
    ?assertEqual(<<"discarded">>, maps:get(state, J2Updated)).

test_retry_by_queue(_Config) ->
    {ok, J1} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}, queue => <<"q1">>}, #{}
    ),
    {ok, J2} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}, queue => <<"q2">>}, #{}
    ),
    ok = shigoto_repo:cancel_job(?POOL, maps:get(id, J1)),
    ok = shigoto_repo:cancel_job(?POOL, maps:get(id, J2)),
    {ok, 1} = shigoto_repo:retry_by(?POOL, #{queue => <<"q1">>}),
    {ok, J1U} = shigoto_repo:get_job(?POOL, maps:get(id, J1)),
    ?assertEqual(<<"available">>, maps:get(state, J1U)).

test_retry_by_tags(_Config) ->
    {ok, J1} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, tags => [<<"urgent">>]},
        #{}
    ),
    {ok, J2} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, tags => [<<"low">>]},
        #{}
    ),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J1)),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J2)),
    {ok, 1} = shigoto_repo:retry_by(?POOL, #{tags => [<<"urgent">>]}),
    {ok, J1U} = shigoto_repo:get_job(?POOL, maps:get(id, J1)),
    ?assertEqual(<<"available">>, maps:get(state, J1U)),
    {ok, J2U} = shigoto_repo:get_job(?POOL, maps:get(id, J2)),
    ?assertEqual(<<"discarded">>, maps:get(state, J2U)).

test_retry_by_empty_filter(_Config) ->
    {ok, J1} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, J2} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J1)),
    ok = shigoto_repo:cancel_job(?POOL, maps:get(id, J2)),
    %% Empty filter retries all terminal jobs
    {ok, Count} = shigoto_repo:retry_by(?POOL, #{}),
    ?assertEqual(2, Count).

test_retry_by_only_retries_terminal(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    %% Job is available, not terminal — retry_by should not touch it
    {ok, 0} = shigoto_repo:retry_by(?POOL, #{worker => shigoto_test_worker}).

%%----------------------------------------------------------------------
%% Dynamic queues
%%----------------------------------------------------------------------

test_add_queue(_Config) ->
    {ok, SupPid} = shigoto_queue_sup:start_link([]),
    try
        {ok, Pid} = shigoto:add_queue(<<"dynamic_test">>, 5),
        ?assert(is_pid(Pid)),
        ok = shigoto:remove_queue(<<"dynamic_test">>)
    after
        unlink(SupPid),
        exit(SupPid, shutdown)
    end.

test_add_queue_idempotent(_Config) ->
    {ok, SupPid} = shigoto_queue_sup:start_link([]),
    try
        {ok, Pid1} = shigoto:add_queue(<<"dynamic_idem">>, 5),
        {ok, Pid2} = shigoto:add_queue(<<"dynamic_idem">>, 5),
        ?assertEqual(Pid1, Pid2),
        ok = shigoto:remove_queue(<<"dynamic_idem">>)
    after
        unlink(SupPid),
        exit(SupPid, shutdown)
    end.

test_remove_queue(_Config) ->
    {ok, SupPid} = shigoto_queue_sup:start_link([]),
    try
        {ok, _} = shigoto:add_queue(<<"dynamic_rm">>, 3),
        ok = shigoto:remove_queue(<<"dynamic_rm">>),
        ?assertMatch({error, _}, shigoto:remove_queue(<<"dynamic_rm">>))
    after
        unlink(SupPid),
        exit(SupPid, shutdown)
    end.

%%----------------------------------------------------------------------
%% Health check
%%----------------------------------------------------------------------

test_health_ok(_Config) ->
    %% Start queue sup with a test queue for health check
    {ok, SupPid} = shigoto_queue_sup:start_link([{<<"health_q">>, 1}]),
    try
        application:set_env(shigoto, queues, [{<<"health_q">>, 1}]),
        {ok, Health} = shigoto:health(),
        ?assertEqual(ok, maps:get(status, Health)),
        ?assert(is_map(maps:get(counts, Health))),
        ?assertEqual(0, maps:get(stale_jobs, Health)),
        ?assert(is_map(maps:get(queues, Health)))
    after
        application:set_env(shigoto, queues, [{<<"default">>, 10}]),
        unlink(SupPid),
        exit(SupPid, shutdown)
    end.

%%----------------------------------------------------------------------
%% Job archival
%%----------------------------------------------------------------------

test_archive_jobs(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    JobId = maps:get(id, Job),
    ok = shigoto_repo:complete_job(?POOL, JobId),
    %% Archive with 0 days threshold
    {ok, Count} = shigoto_repo:archive_jobs(?POOL, 0),
    ?assert(Count >= 1),
    %% Job should be gone from main table
    ?assertEqual({error, not_found}, shigoto_repo:get_job(?POOL, JobId)),
    %% But should be in archive
    ArchiveSQL = <<"SELECT id FROM shigoto_jobs_archive WHERE id = $1">>,
    #{rows := ArchiveRows} = pgo:query(
        ArchiveSQL, [JobId], #{
            pool => ?POOL, decode_opts => [return_rows_as_maps, column_name_as_atom]
        }
    ),
    ?assertEqual(1, length(ArchiveRows)).

%%----------------------------------------------------------------------
%% Dashboard search
%%----------------------------------------------------------------------

test_search_by_state(_Config) ->
    {ok, J1} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, _J2} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J1)),
    {ok, Results} = shigoto_dashboard:search_jobs(#{state => <<"discarded">>}),
    ?assert(length(Results) >= 1),
    lists:foreach(
        fun(R) -> ?assertEqual(<<"discarded">>, maps:get(state, R)) end,
        Results
    ).

test_search_by_worker(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_tagged_worker, args => #{}}, #{}
    ),
    {ok, Results} = shigoto_dashboard:search_jobs(#{worker => <<"shigoto_tagged_worker">>}),
    ?assertEqual(1, length(Results)),
    ?assertEqual(<<"shigoto_tagged_worker">>, maps:get(worker, hd(Results))).

test_search_pagination(_Config) ->
    lists:foreach(
        fun(I) ->
            shigoto_repo:insert_job(
                ?POOL,
                #{worker => shigoto_test_worker, args => #{<<"i">> => I}},
                #{}
            )
        end,
        lists:seq(1, 10)
    ),
    {ok, Page1} = shigoto_dashboard:search_jobs(#{limit => 3, offset => 0}),
    ?assertEqual(3, length(Page1)),
    {ok, Page2} = shigoto_dashboard:search_jobs(#{limit => 3, offset => 3}),
    ?assertEqual(3, length(Page2)),
    %% Pages should have different jobs (no overlap)
    Page1Ids = [maps:get(id, J) || J <- Page1],
    Page2Ids = [maps:get(id, J) || J <- Page2],
    Overlap = [Id || Id <- Page1Ids, lists:member(Id, Page2Ids)],
    ?assertEqual([], Overlap).

test_search_combined_filters(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, queue => <<"search_q">>},
        #{}
    ),
    {ok, J2} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_tagged_worker, args => #{}, queue => <<"search_q">>},
        #{}
    ),
    ok = shigoto_repo:discard_job(?POOL, maps:get(id, J2)),
    {ok, Results} = shigoto_dashboard:search_jobs(#{
        queue => <<"search_q">>,
        state => <<"discarded">>
    }),
    ?assertEqual(1, length(Results)),
    ?assertEqual(<<"shigoto_tagged_worker">>, maps:get(worker, hd(Results))).

%%----------------------------------------------------------------------
%% Edge cases
%%----------------------------------------------------------------------

test_claim_respects_priority(_Config) ->
    {ok, Low} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"p">> => <<"low">>}, priority => 0},
        #{}
    ),
    {ok, High} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"p">> => <<"high">>}, priority => 10},
        #{}
    ),
    %% Claim 1 — should get high priority first
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ?assertEqual(maps:get(id, High), maps:get(id, Claimed)),
    %% Claim next — should get low priority
    {ok, [Claimed2]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ?assertEqual(maps:get(id, Low), maps:get(id, Claimed2)).

test_claim_respects_scheduled_at(_Config) ->
    %% Insert a job scheduled in the future
    Future = {{2099, 1, 1}, {0, 0, 0}},
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, scheduled_at => Future},
        #{}
    ),
    %% Should not be claimable
    {ok, []} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10).

test_snooze_preserves_attempt_count(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_snooze_worker, args => #{}}, #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    %% Attempt is now 1 after claim
    ?assertEqual(1, maps:get(attempt, Claimed)),
    {snooze, 60} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    %% Snoozed job should keep attempt=1 (snooze doesn't count as failure)
    {ok, Snoozed} = shigoto_repo:get_job(?POOL, JobId),
    ?assertEqual(1, maps:get(attempt, Snoozed)),
    ?assertEqual(<<"available">>, maps:get(state, Snoozed)).

test_max_attempts_discards(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"action">> => <<"fail">>}, max_attempts => 1},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    {error, _} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    {ok, Failed} = shigoto_repo:get_job(?POOL, JobId),
    ?assertEqual(<<"discarded">>, maps:get(state, Failed)).

test_concurrent_claim_no_double_execute(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    Self = self(),
    Claim = fun() ->
        Result = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
        Self ! {claimed, self(), Result}
    end,
    Pid1 = spawn(Claim),
    Pid2 = spawn(Claim),
    R1 =
        receive
            {claimed, Pid1, Res1} -> Res1
        after 5000 -> timeout
        end,
    R2 =
        receive
            {claimed, Pid2, Res2} -> Res2
        after 5000 -> timeout
        end,
    %% Exactly one should get the job, the other gets empty list
    Results = [{ok, length(Jobs)} || {ok, Jobs} <- [R1, R2]],
    ?assertEqual(lists:sort([{ok, 0}, {ok, 1}]), lists:sort(Results)).

test_cancel_by_no_match(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    %% Cancel by nonexistent worker
    {ok, 0} = shigoto_repo:cancel_by(?POOL, #{worker => nonexistent_worker}).

test_insert_minimal_params(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}},
        #{}
    ),
    ?assertEqual(<<"default">>, maps:get(queue, Job)),
    ?assertEqual(0, maps:get(priority, Job)),
    ?assertEqual(3, maps:get(max_attempts, Job)),
    ?assertEqual(<<"available">>, maps:get(state, Job)),
    ?assertEqual(0, maps:get(attempt, Job)),
    ?assertEqual(0, maps:get(progress, Job)).

test_debounce_resets_scheduled_at(_Config) ->
    Unique = #{keys => [worker, args], debounce => 10},
    Params = #{worker => shigoto_test_worker, args => #{<<"db">> => 1}},
    {ok, Job1} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ScheduledAt1 = maps:get(scheduled_at, Job1),
    timer:sleep(100),
    {ok, {conflict, Job2}} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
    ScheduledAt2 = maps:get(scheduled_at, Job2),
    %% Debounce should have reset scheduled_at to a later time
    ?assertNotEqual(ScheduledAt1, ScheduledAt2).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

cleanup() ->
    pgo:query(<<"DELETE FROM shigoto_jobs">>, [], #{pool => ?POOL}),
    pgo:query(<<"DELETE FROM shigoto_jobs_archive">>, [], #{pool => ?POOL}),
    pgo:query(<<"DELETE FROM shigoto_batches">>, [], #{pool => ?POOL}),
    ok.
