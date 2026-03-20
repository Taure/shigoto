-module(shigoto_features_SUITE).
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
    test_get_job/1,
    test_encryption_roundtrip/1,
    test_heartbeat_stale_threshold/1
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
        test_get_job,
        test_encryption_roundtrip,
        test_heartbeat_stale_threshold
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
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
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_tagged_worker, args => #{}},
        #{}
    ),
    ?assertEqual([<<"email">>, <<"notifications">>], maps:get(tags, Job)).

test_tags_explicit(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(
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
    {ok, Job} = shigoto_repo:insert_job(
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
    {ok, Job} = shigoto_repo:insert_job(
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
    [ErrorEntry | _] = Errors,
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
        fun(Job) -> shigoto_executor:execute_sync(Job, ?POOL, 5000) end,
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
    {ok, Job} = shigoto_repo:insert_job(
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
        %% Claiming should decrypt
        {ok, [Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
        ClaimedArgs = maps:get(args, Claimed),
        %% The decrypted args should be the original JSON
        Decoded =
            case is_binary(ClaimedArgs) of
                true -> json:decode(ClaimedArgs);
                false -> ClaimedArgs
            end,
        ?assertEqual(<<"data">>, maps:get(<<"secret">>, Decoded))
    after
        application:set_env(shigoto, encryption_key, undefined)
    end.

%%----------------------------------------------------------------------
%% Heartbeat stale threshold test
%%----------------------------------------------------------------------

test_heartbeat_stale_threshold(_Config) ->
    %% Insert a job and claim it
    {ok, Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{<<"action">> => <<"slow">>}},
        #{}
    ),
    JobId = maps:get(id, Job),
    {ok, [_Claimed]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    %% Set heartbeat_at to the past so rescue picks it up
    _ = pgo:query(
        <<"UPDATE shigoto_jobs SET heartbeat_at = now() - interval '120 seconds' WHERE id = $1">>,
        [JobId],
        #{pool => ?POOL}
    ),
    %% Rescue with 60 second threshold
    {ok, Count} = shigoto_repo:rescue_stale_jobs(?POOL, 60),
    ?assert(Count >= 1),
    %% Job should be available again
    {ok, [Rescued]} = shigoto_repo:claim_jobs(?POOL, <<"default">>, 1),
    ?assertEqual(JobId, maps:get(id, Rescued)).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

cleanup() ->
    pgo:query(<<"DELETE FROM shigoto_jobs">>, [], #{pool => ?POOL}),
    pgo:query(<<"DELETE FROM shigoto_batches">>, [], #{pool => ?POOL}),
    ok.
