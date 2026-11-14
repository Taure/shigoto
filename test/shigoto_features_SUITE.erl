-module(shigoto_features_SUITE).
-behaviour(ct_suite).
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    groups/0,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    test_bulk_insert/1,
    test_bulk_insert_empty/1,
    test_tags_worker_default/1,
    test_tags_explicit/1,
    test_tags_cancel_by/1,
    test_cancel_by_worker/1,
    test_cancel_by_queue/1,
    test_progress_tracking/1,
    test_structured_errors/1,
    test_pluggable_backoff/1,
    test_middleware_chain/1,
    test_batch_create_and_complete/1,
    test_batch_with_callback/1,
    test_batch_counts_cancelled_and_discarded_jobs/1,
    test_batch_event_is_discard_whichever_job_is_last/1,
    test_batch_total_is_counted_with_the_insert/1,
    test_get_job/1,
    test_encryption_roundtrip/1,
    test_encrypted_unique_key_hides_args/1,
    test_encrypted_unique_key_is_keyed/1,
    test_encrypted_args_filter_is_refused/1,
    test_heartbeat_stale_threshold/1,
    test_dependents_follow_their_policy_when_a_parent_fails/1,
    test_dependency_policy_defaults_to_the_application_setting/1,
    test_dependency_policy_applies_to_cancel_and_rescue/1,
    test_dependency_policy_is_validated_on_insert/1,
    test_a_cascaded_job_counts_in_its_batch/1,
    test_statements_run_before_the_policy_column_exists/1,
    test_a_job_naming_no_module_can_be_discarded/1,
    test_claim_counts_as_a_heartbeat/1,
    test_stale_threshold_under_a_second/1,
    test_rescue_discards_a_job_out_of_attempts/1,
    test_heartbeat_is_written_under_the_claim/1,
    test_depends_on_blocks_claiming/1,
    test_depends_on_resolved_on_complete/1,
    test_depends_on_resolved_on_discard/1,
    test_depends_on_resolved_on_cancel/1,
    test_depends_on_resolved_when_attempts_exhausted/1,
    test_depends_on_held_while_parent_retryable/1,
    test_depends_on_chain/1,
    test_on_discard_callback/1
]).

-define(POOL, shigoto_test_pool).

all() ->
    [
        test_bulk_insert,
        test_bulk_insert_empty,
        test_tags_worker_default,
        test_tags_explicit,
        test_tags_cancel_by,
        test_cancel_by_worker,
        test_cancel_by_queue,
        test_progress_tracking,
        test_structured_errors,
        test_pluggable_backoff,
        test_middleware_chain,
        test_batch_create_and_complete,
        test_batch_with_callback,
        test_batch_counts_cancelled_and_discarded_jobs,
        test_batch_event_is_discard_whichever_job_is_last,
        test_batch_total_is_counted_with_the_insert,
        test_get_job,
        test_heartbeat_stale_threshold,
        test_dependents_follow_their_policy_when_a_parent_fails,
        test_dependency_policy_defaults_to_the_application_setting,
        test_dependency_policy_applies_to_cancel_and_rescue,
        test_dependency_policy_is_validated_on_insert,
        test_a_cascaded_job_counts_in_its_batch,
        test_statements_run_before_the_policy_column_exists,
        test_a_job_naming_no_module_can_be_discarded,
        test_claim_counts_as_a_heartbeat,
        test_stale_threshold_under_a_second,
        test_rescue_discards_a_job_out_of_attempts,
        test_heartbeat_is_written_under_the_claim,
        test_depends_on_blocks_claiming,
        test_depends_on_resolved_on_complete,
        test_depends_on_resolved_on_discard,
        test_depends_on_resolved_on_cancel,
        test_depends_on_resolved_when_attempts_exhausted,
        test_depends_on_held_while_parent_retryable,
        test_depends_on_chain,
        test_on_discard_callback,
        {group, frames_v1},
        {group, frames_v2}
    ].

%% The cases that store something encrypted run once with each
%% `encryption_write_format`: `v1`, the default, and `v2`.
groups() ->
    [{frames_v1, [], encrypting()}, {frames_v2, [], encrypting()}].

encrypting() ->
    [
        test_encryption_roundtrip,
        test_encrypted_unique_key_hides_args,
        test_encrypted_unique_key_is_keyed,
        test_encrypted_args_filter_is_refused
    ].

init_per_group(frames_v1, Config) ->
    application:set_env(shigoto, encryption_write_format, v1),
    Config;
init_per_group(frames_v2, Config) ->
    application:set_env(shigoto, encryption_write_format, v2),
    Config.

end_per_group(_Group, _Config) ->
    application:unset_env(shigoto, encryption_write_format).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(shigoto_test_pool),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup(),
    ok.

%%----------------------------------------------------------------------
%% Bulk insert tests
%%----------------------------------------------------------------------

test_bulk_insert(_Config) ->
    Jobs = [
        #{worker => shigoto_test_worker, args => #{<<"id">> => I}}
     || I <- lists:seq(1, 10)
    ],
    {ok, Inserted} = shigoto_repo:insert_all(?POOL, Jobs, #{}),
    ?assertEqual(10, length(Inserted)),
    %% All should be claimable
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 20),
    ?assertEqual(10, length(Claimed)).

test_bulk_insert_empty(_Config) ->
    {ok, []} = shigoto_repo:insert_all(?POOL, [], #{}).

%%----------------------------------------------------------------------
%% Tags tests
%%----------------------------------------------------------------------

test_tags_worker_default(_Config) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_tagged_worker, args => #{}},
        #{}
    ),
    ?assertEqual([<<"email">>, <<"notifications">>], maps:get(tags, Job)).

test_tags_explicit(_Config) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, tags => [<<"urgent">>, <<"api">>]},
        #{}
    ),
    ?assertEqual([<<"urgent">>, <<"api">>], maps:get(tags, Job)).

test_tags_cancel_by(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_tagged_worker, args => #{<<"a">> => 1}},
        #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_tagged_worker, args => #{<<"a">> => 2}},
        #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}},
        #{}
    ),
    {ok, Count} = shigoto_repo:cancel_by(?POOL, #{tags => [<<"email">>]}),
    ?assertEqual(2, Count),
    %% The non-tagged job should still be claimable
    {ok, [_]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10).

%%----------------------------------------------------------------------
%% Cancel by pattern tests
%%----------------------------------------------------------------------

test_cancel_by_worker(_Config) ->
    {ok, _} = shigoto_repo:insert_job(?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}),
    {ok, _} = shigoto_repo:insert_job(?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}),
    {ok, _} = shigoto_repo:insert_job(?POOL, #{worker => shigoto_tagged_worker, args => #{}}, #{}),
    {ok, Count} = shigoto_repo:cancel_by(?POOL, #{worker => shigoto_test_worker}),
    ?assertEqual(2, Count).

test_cancel_by_queue(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, queue => <<"special">>},
        #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}},
        #{}
    ),
    {ok, Count} = shigoto_repo:cancel_by(?POOL, #{queue => <<"special">>}),
    ?assertEqual(1, Count).

%%----------------------------------------------------------------------
%% Progress tracking tests
%%----------------------------------------------------------------------

test_progress_tracking(_Config) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}},
        #{}
    ),
    JobId = maps:get(id, Job),
    ?assertEqual(0, maps:get(progress, Job)),
    ok = shigoto_repo:update_progress(?POOL, JobId, 50),
    {ok, Updated} = shigoto_repo:get_job(?POOL, JobId),
    ?assertEqual(50, maps:get(progress, Updated)),
    ok = shigoto_repo:update_progress(?POOL, JobId, 100),
    {ok, Final} = shigoto_repo:get_job(?POOL, JobId),
    ?assertEqual(100, maps:get(progress, Final)).

%%----------------------------------------------------------------------
%% Structured errors tests
%%----------------------------------------------------------------------

test_structured_errors(_Config) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"action">> => <<"fail">>}},
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    {error, _} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    {ok, Failed} = shigoto_repo:get_job(?POOL, maps:get(id, Job)),
    RawErrors = maps:get(errors, Failed),
    Errors =
        case is_binary(RawErrors) of
            true -> json:decode(RawErrors);
            false -> RawErrors
        end,
    ?assert(is_list(Errors)),
    [#{} = ErrorEntry | _] = Errors,
    ?assert(maps:is_key(<<"error">>, ErrorEntry)),
    ?assert(maps:is_key(<<"at">>, ErrorEntry)),
    ?assert(maps:is_key(<<"attempt">>, ErrorEntry)),
    ?assert(maps:is_key(<<"worker">>, ErrorEntry)).

%%----------------------------------------------------------------------
%% Pluggable backoff tests
%%----------------------------------------------------------------------

test_pluggable_backoff(_Config) ->
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_backoff_worker, args => #{<<"action">> => <<"fail">>}},
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    %% execute_sync will call the custom backoff/2 which returns 10 for attempt 1
    {error, _} = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    %% Job should be retryable but scheduled in the future
    {ok, []} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1).

%%----------------------------------------------------------------------
%% Middleware tests
%%----------------------------------------------------------------------

test_middleware_chain(_Config) ->
    PidBin = list_to_binary(pid_to_list(self())),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_middleware_worker, args => #{<<"test_pid">> => PidBin}},
        #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ok = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    %% Should receive middleware_before, performed, middleware_after in order
    receive
        {middleware_before, _} -> ok
    after 1000 -> ct:fail(no_middleware_before)
    end,
    receive
        {performed, _} -> ok
    after 1000 -> ct:fail(no_performed)
    end,
    receive
        {middleware_after, _} -> ok
    after 1000 -> ct:fail(no_middleware_after)
    end.

%%----------------------------------------------------------------------
%% Batch tests
%%----------------------------------------------------------------------

test_batch_create_and_complete(_Config) ->
    {ok, Batch} = shigoto_batch:create(?POOL, #{}),
    BatchId = maps:get(id, Batch),
    ?assertEqual(<<"active">>, maps:get(state, Batch)),
    ?assertEqual(0, maps:get(total_jobs, Batch)),

    %% Insert jobs into the batch
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{<<"action">> => <<"succeed">>},
            batch => BatchId
        },
        #{}
    ),
    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{<<"action">> => <<"succeed">>},
            batch => BatchId
        },
        #{}
    ),

    %% Check batch total
    {ok, Updated} = shigoto_batch:get(?POOL, BatchId),
    ?assertEqual(2, maps:get(total_jobs, Updated)),

    %% Execute both jobs
    {ok, Jobs} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 2),
    lists:foreach(
        fun(#{} = Job) -> shigoto_executor:execute_sync(Job, ?POOL, 5000) end,
        Jobs
    ),

    %% Batch should be finished
    {ok, Final} = shigoto_batch:get(?POOL, BatchId),
    ?assertEqual(2, maps:get(completed_jobs, Final)),
    ?assertEqual(<<"finished">>, maps:get(state, Final)).

test_batch_with_callback(_Config) ->
    PidBin = list_to_binary(pid_to_list(self())),
    {ok, Batch} = shigoto_batch:create(?POOL, #{
        callback_worker => shigoto_batch_callback_worker,
        callback_args => #{<<"test_pid">> => PidBin, <<"batch">> => <<"done">>}
    }),
    BatchId = maps:get(id, Batch),

    {ok, _} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{<<"action">> => <<"succeed">>},
            batch => BatchId
        },
        #{}
    ),

    %% Execute the job
    {ok, [Job]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    shigoto_executor:execute_sync(Job, ?POOL, 5000),

    %% Batch callback should have been inserted — drain to execute it
    {ok, [CallbackJob]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    shigoto_executor:execute_sync(CallbackJob, ?POOL, 5000),

    receive
        {batch_callback, CallbackArgs} ->
            ?assertEqual(<<"done">>, maps:get(<<"batch">>, CallbackArgs))
    after 2000 ->
        ct:fail(no_batch_callback)
    end.

%%----------------------------------------------------------------------
%% Get job test
%%----------------------------------------------------------------------

test_get_job(_Config) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"x">> => 1}},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, Fetched} = shigoto_repo:get_job(?POOL, JobId),
    ?assertEqual(JobId, maps:get(id, Fetched)),
    ?assertEqual({error, not_found}, shigoto_repo:get_job(?POOL, 999999999)).

%%----------------------------------------------------------------------
%% Encryption test
%%----------------------------------------------------------------------

test_encrypted_unique_key_hides_args(_Config) ->
    application:set_env(shigoto, encryption_key, crypto:strong_rand_bytes(32)),
    try
        Unique = #{keys => [worker, args], states => [available, executing]},
        Params = #{worker => shigoto_test_worker, args => #{~"secret" => ~"hunter2"}},
        {ok, #{id := Id, unique_key := UniqueKey}} =
            shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
        ?assert(is_binary(UniqueKey)),
        ?assertEqual(nomatch, binary:match(UniqueKey, [~"hunter2", ~"secret"])),
        ?assertMatch(
            {ok, {conflict, #{id := Id}}},
            shigoto_repo:insert_job(?POOL, Params, #{unique => Unique})
        )
    after
        application:unset_env(shigoto, encryption_key)
    end.

test_encrypted_unique_key_is_keyed(_Config) ->
    Unique = #{keys => [worker, args], states => [available, executing]},
    Params = #{worker => shigoto_test_worker, args => #{~"user_id" => 5}},
    KeyFor = fun(EncKey) ->
        application:set_env(shigoto, encryption_key, EncKey),
        {ok, #{unique_key := K}} = shigoto_repo:insert_job(?POOL, Params, #{unique => Unique}),
        #{} = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
        K
    end,
    try
        K1 = KeyFor(crypto:strong_rand_bytes(32)),
        K2 = KeyFor(crypto:strong_rand_bytes(32)),
        ?assertNotEqual(K1, K2),
        Material = iolist_to_binary([~"{\"user_id\":5}", ~":", ~"shigoto_test_worker"]),
        ?assertNotEqual(binary:encode_hex(crypto:hash(sha256, Material)), K1)
    after
        application:unset_env(shigoto, encryption_key)
    end.

test_encrypted_args_filter_is_refused(_Config) ->
    application:set_env(shigoto, encryption_key, crypto:strong_rand_bytes(32)),
    try
        Args = #{~"user_id" => 5},
        {ok, _} = shigoto_repo:insert_job(
            ?POOL, #{worker => shigoto_test_worker, args => Args}, #{}
        ),
        Refused = {error, args_filter_unsupported_with_encryption},
        ?assertEqual(Refused, shigoto_repo:find_jobs(?POOL, #{args => Args})),
        ?assertEqual(Refused, shigoto:cancel_by(?POOL, #{args => Args})),
        ?assertEqual(Refused, shigoto:retry_by(?POOL, #{args => Args})),
        ?assertMatch(
            {ok, [_]}, shigoto_repo:find_jobs(?POOL, #{worker => shigoto_test_worker})
        ),
        ?assertEqual({ok, 1}, shigoto:cancel_by(?POOL, #{worker => shigoto_test_worker}))
    after
        application:unset_env(shigoto, encryption_key)
    end.

test_encryption_roundtrip(_Config) ->
    %% Set encryption key
    Key = crypto:strong_rand_bytes(32),
    application:set_env(shigoto, encryption_key, Key),
    try
        {ok, _Job} = shigoto_repo:insert_job(
            ?POOL,
            #{worker => shigoto_test_worker, args => #{<<"secret">> => <<"data">>}},
            #{}
        ),
        %% A claimed job is still as it is stored; it is opened for the run,
        %% after the worker it names has been checked.
        {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
        ?assertMatch(<<"\"enc:", _/binary>>, maps:get(args, Claimed)),
        {ok, shigoto_test_worker, #{args := Args}} = shigoto_job:opened(Claimed),
        ?assertEqual(<<"data">>, maps:get(<<"secret">>, Args))
    after
        application:set_env(shigoto, encryption_key, undefined)
    end.

test_batch_counts_cancelled_and_discarded_jobs(_Config) ->
    {ok, #{id := BatchId}} = shigoto_batch:create(?POOL, #{}),
    InBatch = fun(Tag) ->
        {ok, #{id := JobId}} = shigoto_repo:insert_job(
            ?POOL,
            #{
                worker => shigoto_test_worker,
                args => #{~"n" => Tag},
                batch => BatchId,
                tags => [Tag]
            },
            #{}
        ),
        JobId
    end,
    Cancelled = InBatch(~"one"),
    Discarded = InBatch(~"two"),
    _ = [InBatch(~"swept") || _ <- lists:seq(1, 3)],
    {ok, _Outside} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}, tags => [~"swept"]}, #{}
    ),
    Completed = InBatch(~"last"),
    ?assertMatch({ok, #{total_jobs := 6}}, shigoto_batch:get(?POOL, BatchId)),
    ok = shigoto_repo:cancel_job(?POOL, Cancelled),
    ?assertMatch({ok, #{discarded_jobs := 1}}, shigoto_batch:get(?POOL, BatchId)),
    %% Cancelling it again counts nothing.
    ok = shigoto_repo:cancel_job(?POOL, Cancelled),
    ?assertMatch({ok, #{discarded_jobs := 1}}, shigoto_batch:get(?POOL, BatchId)),
    ok = shigoto_repo:discard_job(?POOL, Discarded),
    ok = shigoto_repo:discard_job(?POOL, Discarded),
    ?assertMatch({ok, #{discarded_jobs := 2}}, shigoto_batch:get(?POOL, BatchId)),
    ?assertEqual({ok, 4}, shigoto_repo:cancel_by(?POOL, #{tags => [~"swept"]})),
    ?assertMatch(
        {ok, #{discarded_jobs := 5, completed_jobs := 0, state := ~"active"}},
        shigoto_batch:get(?POOL, BatchId)
    ),
    {ok, [#{id := Completed} = Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_repo:complete_job(?POOL, Claimed),
    ?assertMatch(
        {ok, #{total_jobs := 6, discarded_jobs := 5, completed_jobs := 1, state := ~"finished"}},
        shigoto_batch:get(?POOL, BatchId)
    ).

test_batch_event_is_discard_whichever_job_is_last(_Config) ->
    {ok, #{id := BatchId}} = shigoto_batch:create(?POOL, #{
        callback_worker => shigoto_batch_callback_worker,
        callback_args => #{~"test_pid" => list_to_binary(pid_to_list(self()))}
    }),
    {ok, [#{id := First}, _Second]} = shigoto_repo:insert_all(
        ?POOL,
        [
            #{worker => shigoto_test_worker, args => #{~"n" => N}, batch => BatchId}
         || N <- [1, 2]
        ],
        #{}
    ),
    ok = shigoto_repo:cancel_job(?POOL, First),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_repo:complete_job(?POOL, Claimed),
    ?assertMatch(
        {ok, #{state := ~"callback_discarding", completed_jobs := 1, discarded_jobs := 1}},
        shigoto_batch:get(?POOL, BatchId)
    ),
    {ok, [Callback]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_executor:execute_sync(Callback, ?POOL, 5000),
    receive
        {batch_callback, Args} -> ?assertMatch(#{~"_batch_event" := ~"discard"}, Args)
    after 2000 -> ct:fail(no_batch_callback)
    end.

test_batch_total_is_counted_with_the_insert(_Config) ->
    {ok, #{id := One}} = shigoto_batch:create(?POOL, #{}),
    {ok, #{id := Other}} = shigoto_batch:create(?POOL, #{}),
    Job = fun(Batch) -> #{worker => shigoto_test_worker, args => #{}, batch => Batch} end,
    {ok, Inserted} = shigoto_repo:insert_all(
        ?POOL,
        [Job(One), Job(Other), Job(One), #{worker => shigoto_test_worker, args => #{}}, Job(One)],
        #{}
    ),
    %% The jobs come back in the order they were given.
    ?assertEqual([One, Other, One, null, One], [maps:get(batch_id, Row) || Row <- Inserted]),
    Ids = [maps:get(id, Row) || Row <- Inserted],
    ?assertEqual(lists:sort(Ids), Ids),
    ?assertMatch({ok, #{total_jobs := 3}}, shigoto_batch:get(?POOL, One)),
    ?assertMatch({ok, #{total_jobs := 1}}, shigoto_batch:get(?POOL, Other)),
    {ok, #{batch_id := Other}} = shigoto_repo:insert_job(?POOL, Job(Other), #{}),
    ?assertMatch({ok, #{total_jobs := 2}}, shigoto_batch:get(?POOL, Other)),
    %% An insert that is rolled back takes its count with it.
    ?assertError(
        rolled_back,
        shigoto_db:transaction(?POOL, fun() ->
            {ok, _} = shigoto_repo:insert_job(?POOL, Job(Other), #{}),
            {ok, _} = shigoto_repo:insert_all(?POOL, [Job(One), Job(One)], #{}),
            error(rolled_back)
        end)
    ),
    ?assertMatch({ok, #{total_jobs := 3}}, shigoto_batch:get(?POOL, One)),
    ?assertMatch({ok, #{total_jobs := 2}}, shigoto_batch:get(?POOL, Other)).

%%----------------------------------------------------------------------
%% Heartbeat stale threshold test
%%----------------------------------------------------------------------

test_heartbeat_stale_threshold(_Config) ->
    %% Insert a job and claim it
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"action">> => <<"slow">>}},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [_Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    %% Claimed and last heard from two minutes ago, so rescue picks it up
    ok = last_heard_from(JobId, ~"heartbeat_at = now() - interval '120 seconds'"),
    ok = last_heard_from(JobId, ~"attempted_at = now() - interval '120 seconds'"),
    %% Rescue with 60 second threshold
    {ok, Count} = shigoto_repo:rescue_stale_jobs(?POOL, 60),
    ?assert(Count >= 1),
    %% Job should be available again
    {ok, [Rescued]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ?assertEqual(JobId, maps:get(id, Rescued)),
    ?assertMatch(#{attempt := 2}, Rescued),
    ?assertMatch(
        [#{~"error" := ~"rescued", ~"attempt" := 1, ~"worker" := ~"shigoto_test_worker"}],
        json:decode(maps:get(errors, Rescued))
    ).

test_a_job_naming_no_module_can_be_discarded(_Config) ->
    Insert =
        ~"""
    INSERT INTO shigoto_jobs (queue, worker, args, max_attempts)
    VALUES ('default', 'shigoto_never_a_module', '{}', 1) RETURNING id
    """,
    Failing = inserted_id(Insert),
    Stale = inserted_id(Insert),
    {ok, [First, _]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertMatch(#{id := Failing}, First),
    %% There is no on_discard/2 to run, and looking for one must not crash.
    ?assertEqual(
        {error, {unknown_worker, ~"shigoto_never_a_module"}},
        shigoto_executor:execute_sync(First, ?POOL, 5000)
    ),
    ?assertMatch({ok, #{state := ~"discarded"}}, shigoto_repo:get_job(?POOL, Failing)),
    ok = last_heard_from(
        Stale,
        ~"heartbeat_at = now() - interval '120 seconds', attempted_at = now() - interval '120 seconds'"
    ),
    ?assertEqual({ok, 1}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    ?assertMatch({ok, #{state := ~"discarded"}}, shigoto_repo:get_job(?POOL, Stale)).

test_claim_counts_as_a_heartbeat(_Config) ->
    {ok, #{id := JobId}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual(maps:get(attempted_at, Claimed), maps:get(heartbeat_at, Claimed)),
    %% A heartbeat left by an earlier attempt, on a job claimed just now.
    ok = last_heard_from(JobId, ~"heartbeat_at = now() - interval '120 seconds'"),
    ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    %% A node from before claims set the heartbeat leaves it empty.
    ok = last_heard_from(JobId, ~"heartbeat_at = NULL"),
    ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    ok = last_heard_from(JobId, ~"attempted_at = now() - interval '120 seconds'"),
    ?assertEqual({ok, 1}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 60)).

test_stale_threshold_under_a_second(_Config) ->
    {ok, #{id := JobId}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    {ok, [_Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 1),
    ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 0.5)),
    ok = last_heard_from(JobId, ~"heartbeat_at = now() - interval '600 milliseconds'"),
    ok = last_heard_from(JobId, ~"attempted_at = now() - interval '600 milliseconds'"),
    ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 5)),
    ?assertEqual({ok, 1}, shigoto_repo:rescue_stale_jobs(?POOL, 0.5)).

test_rescue_discards_a_job_out_of_attempts(_Config) ->
    {ok, #{id := First}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 1}, max_attempts => 1}, #{}
    ),
    {ok, #{id := Second}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 2}, max_attempts => 1}, #{}
    ),
    {ok, #{id := Spare}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 3}, max_attempts => 2}, #{}
    ),
    {ok, #{id := Child}} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{~"n" => 4}, depends_on => [First, Second]},
        #{}
    ),
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertEqual([First, Second, Spare], lists:sort([Id || #{id := Id} <- Claimed])),
    [
        ok = last_heard_from(
            Id,
            ~"heartbeat_at = now() - interval '120 seconds', attempted_at = now() - interval '120 seconds'"
        )
     || Id <- [First, Second, Spare]
    ],
    ?assertEqual({ok, 3}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    [
        ?assertMatch(
            {ok, #{state := ~"discarded", attempt := 1, heartbeat_at := null}},
            shigoto_repo:get_job(?POOL, Id)
        )
     || Id <- [First, Second]
    ],
    {ok, #{discarded_at := DiscardedAt}} = shigoto_repo:get_job(?POOL, First),
    ?assertNotEqual(null, DiscardedAt),
    ?assertMatch(
        {ok, #{state := ~"available", attempt := 1, discarded_at := null}},
        shigoto_repo:get_job(?POOL, Spare)
    ),
    %% Both parents went in one sweep: the child is released from both.
    ?assertMatch({ok, #{depends_on := []}}, shigoto_repo:get_job(?POOL, Child)),
    {ok, Next} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertEqual([Spare, Child], lists:sort([Id || #{id := Id} <- Next])).

test_heartbeat_is_written_under_the_claim(_Config) ->
    {ok, #{id := Held}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 1}}, #{}
    ),
    {ok, #{id := Reclaimed}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 2}}, #{}
    ),
    {ok, #{id := Cancelled}} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{~"n" => 3}}, #{}
    ),
    {ok, [_, _, _]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET state = 'available' WHERE id = $1", [Reclaimed]
    ),
    {ok, [#{id := Reclaimed, attempt := 2}]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_repo:cancel_job(?POOL, Cancelled),
    [ok = last_heard_from(Id, ~"heartbeat_at = NULL") || Id <- [Held, Reclaimed, Cancelled]],
    ?assertEqual({ok, []}, shigoto_repo:heartbeat(?POOL, [])),
    ?assertEqual(
        {ok, [{Held, 1}]},
        shigoto_repo:heartbeat(?POOL, [{Held, 1}, {Reclaimed, 1}, {Cancelled, 1}])
    ),
    ?assertMatch({ok, #{heartbeat_at := null}}, shigoto_repo:get_job(?POOL, Reclaimed)),
    ?assertMatch({ok, #{heartbeat_at := null}}, shigoto_repo:get_job(?POOL, Cancelled)),
    {ok, #{heartbeat_at := Heartbeat}} = shigoto_repo:get_job(?POOL, Held),
    ?assertNotEqual(null, Heartbeat),
    ?assertEqual({ok, [{Reclaimed, 2}]}, shigoto_repo:heartbeat(?POOL, [{Reclaimed, 2}])).

%%----------------------------------------------------------------------
%% on_dependency_failure
%%----------------------------------------------------------------------

test_dependents_follow_their_policy_when_a_parent_fails(_Config) ->
    Parent = waiting(#{max_attempts => 1}),
    Runs = waiting(#{depends_on => [Parent], on_dependency_failure => run}),
    Unset = waiting(#{depends_on => [Parent]}),
    Cancels = waiting(#{depends_on => [Parent], on_dependency_failure => cancel}),
    Discards = waiting(#{depends_on => [Parent], on_dependency_failure => discard}),
    %% Below a cancelled job: one that goes with it, one that runs without it.
    Below = waiting(#{depends_on => [Cancels], on_dependency_failure => discard}),
    Released = waiting(#{depends_on => [Cancels, Discards]}),
    %% Waits on a job that failed and on one that has not: it goes at once.
    Other = waiting(#{}),
    Both = waiting(#{depends_on => [Parent, Other], on_dependency_failure => cancel}),
    {ok, [Claimed, _Other]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertMatch(#{id := Parent}, Claimed),
    ok = shigoto_repo:fail_job(?POOL, Claimed, boom, 60),
    ?assertMatch(#{state := ~"discarded"}, job(Parent)),
    [?assertMatch(#{state := ~"available", depends_on := []}, job(Id)) || Id <- [Runs, Unset]],
    ?assertEqual(
        #{integer_to_binary(Parent) => null}, json:decode(maps:get(deps_results, job(Runs)))
    ),
    [
        ?assertMatch(#{state := ~"cancelled", attempt := 0, discarded_at := null}, job(Id))
     || Id <- [Cancels, Both]
    ],
    ?assertNotEqual(null, maps:get(cancelled_at, job(Cancels))),
    [
        begin
            ?assertMatch(#{state := ~"discarded", attempt := 0, cancelled_at := null}, job(Id)),
            ?assertNotEqual(null, maps:get(discarded_at, job(Id)))
        end
     || Id <- [Discards, Below]
    ],
    [
        ?assertMatch(
            [#{~"error" := ~"dependency_failed", ~"attempt" := 0, ~"at" := <<_:19/binary, "Z">>}],
            json:decode(maps:get(errors, job(Id)))
        )
     || Id <- [Cancels, Discards, Below, Both]
    ],
    ?assertMatch(#{state := ~"available", depends_on := []}, job(Released)),
    {ok, Next} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertEqual([Runs, Unset, Released], lists:sort([Id || #{id := Id} <- Next])).

test_dependency_policy_defaults_to_the_application_setting(_Config) ->
    application:set_env(shigoto, on_dependency_failure, cancel),
    try
        Parent = waiting(#{}),
        Unset = waiting(#{depends_on => [Parent]}),
        Runs = waiting(#{depends_on => [Parent], on_dependency_failure => run}),
        ok = shigoto_repo:discard_job(?POOL, Parent),
        ?assertMatch(#{state := ~"cancelled", on_dependency_failure := null}, job(Unset)),
        ?assertMatch(
            #{state := ~"available", depends_on := [], on_dependency_failure := ~"run"}, job(Runs)
        ),
        application:set_env(shigoto, on_dependency_failure, sometimes),
        ?assertError(
            {invalid_on_dependency_failure, sometimes}, shigoto_config:on_dependency_failure()
        )
    after
        application:unset_env(shigoto, on_dependency_failure)
    end,
    ?assertEqual(run, shigoto_config:on_dependency_failure()).

test_dependency_policy_applies_to_cancel_and_rescue(_Config) ->
    Cancelled = waiting(#{tags => [~"swept"]}),
    Swept = waiting(#{tags => [~"swept"]}),
    Stale = waiting(#{max_attempts => 1, priority => 9}),
    AfterCancel = waiting(#{depends_on => [Cancelled], on_dependency_failure => discard}),
    AfterSweep = waiting(#{depends_on => [Swept], on_dependency_failure => cancel}),
    %% Cancelled by the same statement as the job it waits on: counted once.
    Together = waiting(#{
        depends_on => [Swept], on_dependency_failure => discard, tags => [~"swept"]
    }),
    AfterRescue = waiting(#{depends_on => [Stale], on_dependency_failure => cancel}),
    ok = shigoto_repo:cancel_job(?POOL, Cancelled),
    ?assertMatch(#{state := ~"discarded"}, job(AfterCancel)),
    ?assertEqual({ok, 2}, shigoto_repo:cancel_by(?POOL, #{tags => [~"swept"]})),
    ?assertMatch(#{state := ~"cancelled"}, job(AfterSweep)),
    ?assertMatch(#{state := ~"cancelled", errors := ~"[]"}, job(Together)),
    {ok, [#{id := Stale}]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = last_heard_from(
        Stale,
        ~"heartbeat_at = now() - interval '120 seconds', attempted_at = now() - interval '120 seconds'"
    ),
    ?assertEqual({ok, 1}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    ?assertMatch(#{state := ~"discarded"}, job(Stale)),
    ?assertMatch(#{state := ~"cancelled"}, job(AfterRescue)).

test_dependency_policy_is_validated_on_insert(_Config) ->
    Params = #{worker => shigoto_test_worker, args => #{}},
    ?assertEqual(
        {error, {invalid_on_dependency_failure, ~"cancel"}},
        shigoto_repo:insert_job(?POOL, Params#{on_dependency_failure => ~"cancel"}, #{})
    ),
    ?assertEqual(
        {error, {invalid_on_dependency_failure, skip}},
        shigoto_repo:insert_all(?POOL, [Params, Params#{on_dependency_failure => skip}], #{})
    ),
    Gone = waiting(#{}),
    Fine = waiting(#{}),
    ok = shigoto_repo:cancel_job(?POOL, Gone),
    %% The dependency has already failed: there is nothing to wait for and the
    %% job would be dead on arrival.
    ?assertEqual(
        {error, {dependency_failed, [Gone]}},
        shigoto_repo:insert_job(
            ?POOL, Params#{depends_on => [Gone, Fine], on_dependency_failure => discard}, #{}
        )
    ),
    ?assertMatch(
        {ok, #{depends_on := [Fine]}},
        shigoto_repo:insert_job(
            ?POOL, Params#{depends_on => [Gone, Fine], on_dependency_failure => run}, #{}
        )
    ),
    {ok, [Plain, Stated]} = shigoto_repo:insert_all(
        ?POOL, [Params, Params#{depends_on => [Fine], on_dependency_failure => cancel}], #{}
    ),
    ?assertMatch(#{on_dependency_failure := null}, Plain),
    ?assertMatch(#{on_dependency_failure := ~"cancel", depends_on := [Fine]}, Stated),
    ok = shigoto_repo:discard_job(?POOL, Fine),
    ?assertMatch(#{state := ~"cancelled"}, job(maps:get(id, Stated))).

test_a_cascaded_job_counts_in_its_batch(_Config) ->
    {ok, #{id := BatchId}} = shigoto_batch:create(?POOL, #{}),
    Parent = waiting(#{batch => BatchId}),
    _Cancels = waiting(#{
        batch => BatchId, depends_on => [Parent], on_dependency_failure => cancel
    }),
    _Discards = waiting(#{
        batch => BatchId, depends_on => [Parent], on_dependency_failure => discard
    }),
    ok = shigoto_repo:cancel_job(?POOL, Parent),
    ?assertMatch(
        {ok, #{total_jobs := 3, discarded_jobs := 3, state := ~"finished"}},
        shigoto_batch:get(?POOL, BatchId)
    ).

test_statements_run_before_the_policy_column_exists(_Config) ->
    #{} = shigoto_db:query(
        ?POOL, ~"ALTER TABLE shigoto_jobs DROP COLUMN on_dependency_failure", []
    ),
    try
        Parent = waiting(#{max_attempts => 1}),
        Child = waiting(#{depends_on => [Parent]}),
        {ok, [_]} = shigoto_repo:insert_all(
            ?POOL, [#{worker => shigoto_test_worker, args => #{}, depends_on => [Parent]}], #{}
        ),
        {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
        ok = shigoto_repo:fail_job(?POOL, Claimed, boom, 60),
        ?assertMatch(#{state := ~"discarded"}, job(Parent)),
        ?assertMatch(#{state := ~"available", depends_on := []}, job(Child)),
        ok = shigoto_repo:cancel_job(?POOL, Child),
        ?assertEqual({ok, 1}, shigoto_repo:cancel_by(?POOL, #{worker => shigoto_test_worker})),
        ?assertEqual({ok, 0}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
        ?assertMatch(
            {error, _},
            shigoto_repo:insert_job(
                ?POOL,
                #{worker => shigoto_test_worker, args => #{}, on_dependency_failure => cancel},
                #{}
            )
        )
    after
        #{} = shigoto_db:query(
            ?POOL,
            ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS on_dependency_failure TEXT",
            []
        )
    end.

waiting(Params) ->
    {ok, #{id := JobId}} = shigoto_repo:insert_job(
        ?POOL, maps:merge(#{worker => shigoto_test_worker, args => #{}}, Params), #{}
    ),
    JobId.

job(JobId) ->
    {ok, Job} = shigoto_repo:get_job(?POOL, JobId),
    Job.

last_heard_from(JobId, Set) ->
    #{} = shigoto_db:query(
        ?POOL, iolist_to_binary([~"UPDATE shigoto_jobs SET ", Set, ~" WHERE id = $1"]), [JobId]
    ),
    ok.

%%----------------------------------------------------------------------
%% Job dependency tests
%%----------------------------------------------------------------------

test_depends_on_blocks_claiming(_Config) ->
    %% Insert parent job
    {ok, #{} = Parent} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ParentId = maps:get(id, Parent),
    %% Insert child that depends on parent
    {ok, _Child} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            depends_on => [ParentId]
        },
        #{}
    ),
    %% Only parent should be claimable
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed)),
    ?assertMatch([#{id := ParentId} | _], Claimed).

test_depends_on_resolved_on_complete(_Config) ->
    %% Insert parent and child
    {ok, #{} = Parent} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ParentId = maps:get(id, Parent),
    {ok, #{} = Child} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            depends_on => [ParentId]
        },
        #{}
    ),
    ChildId = maps:get(id, Child),
    %% Claim and complete parent
    {ok, [_]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ok = shigoto_repo:complete_job(?POOL, ParentId),
    %% Child should now be claimable
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed)),
    ?assertMatch([#{id := ChildId} | _], Claimed).

test_depends_on_resolved_on_discard(_Config) ->
    {ok, #{} = Parent} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ParentId = maps:get(id, Parent),
    {ok, #{} = Child} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            depends_on => [ParentId]
        },
        #{}
    ),
    ChildId = maps:get(id, Child),
    %% Discard parent — child should still become claimable
    ok = shigoto_repo:discard_job(?POOL, ParentId),
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed)),
    ?assertMatch([#{id := ChildId} | _], Claimed).

test_depends_on_resolved_on_cancel(_Config) ->
    {ok, #{} = Parent} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{}}, #{}
    ),
    ParentId = maps:get(id, Parent),
    {ok, #{} = Child} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{},
            depends_on => [ParentId]
        },
        #{}
    ),
    ChildId = maps:get(id, Child),
    %% Cancel parent — child should still become claimable
    ok = shigoto_repo:cancel_job(?POOL, ParentId),
    {ok, Claimed} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed)),
    ?assertMatch([#{id := ChildId} | _], Claimed).

test_depends_on_resolved_when_attempts_exhausted(_Config) ->
    ChildId = insert_parent_and_child(1),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_repo:fail_job(?POOL, Claimed, boom, 1),
    {ok, Next} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ?assertEqual([ChildId], [maps:get(id, J) || J <- Next]).

test_depends_on_held_while_parent_retryable(_Config) ->
    _ChildId = insert_parent_and_child(3),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, ~"default", 10),
    ok = shigoto_repo:fail_job(?POOL, Claimed, boom, 3600),
    %% The parent is retryable, not finished, so the child stays blocked.
    ?assertEqual({ok, []}, shigoto_repo:claim_jobs(?POOL, ~"default", 10)).

insert_parent_and_child(MaxAttempts) ->
    {ok, #{} = Parent} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, max_attempts => MaxAttempts},
        #{}
    ),
    ParentId = maps:get(id, Parent),
    {ok, #{} = Child} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{}, depends_on => [ParentId]},
        #{}
    ),
    maps:get(id, Child).

test_depends_on_chain(_Config) ->
    %% A -> B -> C chain
    {ok, #{} = A} = shigoto_repo:insert_job(
        ?POOL, #{worker => shigoto_test_worker, args => #{<<"step">> => <<"a">>}}, #{}
    ),
    AId = maps:get(id, A),
    {ok, #{} = B} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{<<"step">> => <<"b">>},
            depends_on => [AId]
        },
        #{}
    ),
    BId = maps:get(id, B),
    {ok, _C} = shigoto_repo:insert_job(
        ?POOL,
        #{
            worker => shigoto_test_worker,
            args => #{<<"step">> => <<"c">>},
            depends_on => [BId]
        },
        #{}
    ),
    %% Only A should be claimable
    {ok, Claimed1} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed1)),
    ?assertMatch([#{id := AId} | _], Claimed1),
    %% Complete A — B becomes claimable, C still blocked
    ok = shigoto_repo:complete_job(?POOL, AId),
    {ok, Claimed2} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed2)),
    ?assertMatch([#{id := BId} | _], Claimed2),
    %% Complete B — C becomes claimable
    ok = shigoto_repo:complete_job(?POOL, BId),
    {ok, Claimed3} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 10),
    ?assertEqual(1, length(Claimed3)).

%%----------------------------------------------------------------------
%% on_discard callback test
%%----------------------------------------------------------------------

test_on_discard_callback(_Config) ->
    %% Register self so the discard worker can find us
    register(shigoto_discard_test, self()),
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_discard_worker, args => #{<<"key">> => <<"value">>}},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ?assertEqual(JobId, maps:get(id, Claimed)),
    _ = shigoto_executor:execute_sync(Claimed, ?POOL, 5000),
    Result =
        receive
            {discarded, Args} ->
                ?assertEqual(<<"value">>, maps:get(<<"key">>, Args)),
                ok
        after 2000 ->
            {error, on_discard_not_called}
        end,
    unregister(shigoto_discard_test),
    case Result of
        ok -> ok;
        {error, Reason} -> ct:fail(Reason)
    end.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

cleanup() ->
    shigoto_db:query(?POOL, <<"DELETE FROM shigoto_jobs">>, []),
    shigoto_db:query(?POOL, <<"DELETE FROM shigoto_batches">>, []),
    ok.

inserted_id(Insert) ->
    case shigoto_db:query(?POOL, Insert, []) of
        #{rows := [#{id := Id}]} when is_integer(Id) -> Id
    end.
