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
    test_prune_old_jobs/1
]).

all() ->
    [
        test_migration,
        test_insert_and_claim,
        test_job_execution_success,
        test_job_execution_failure,
        test_cancel_job,
        test_retry_job,
        test_drain_queue,
        test_prune_old_jobs
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
    ok = shigoto_test_repo:start(),
    Config.

end_per_suite(_Config) ->
    shigoto_migration:down(shigoto_test_repo),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup_jobs(),
    ok.

%%----------------------------------------------------------------------
%% Tests
%%----------------------------------------------------------------------

test_migration(_Config) ->
    ok = shigoto_migration:up(shigoto_test_repo).

test_insert_and_claim(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    ?assertMatch(#{worker := <<"shigoto_test_worker">>}, Job),

    {ok, [Claimed]} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1),
    ?assertEqual(maps:get(id, Job), maps:get(id, Claimed)),
    ?assertEqual(<<"executing">>, maps:get(state, Claimed)).

test_job_execution_success(_Config) ->
    {ok, _} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1),
    ok = shigoto_executor:execute_sync(Claimed, shigoto_test_repo, 5000),
    {ok, []} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1).

test_job_execution_failure(_Config) ->
    {ok, _} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"fail">>}
    }, #{}),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1),
    {error, _} = shigoto_executor:execute_sync(Claimed, shigoto_test_repo, 5000).

test_cancel_job(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    ok = shigoto_repo:cancel_job(shigoto_test_repo, maps:get(id, Job)),
    {ok, []} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1).

test_retry_job(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    ok = shigoto_repo:cancel_job(shigoto_test_repo, maps:get(id, Job)),
    ok = shigoto_repo:retry_job(shigoto_test_repo, maps:get(id, Job)),
    {ok, [Claimed]} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 1),
    ?assertEqual(maps:get(id, Job), maps:get(id, Claimed)).

test_drain_queue(_Config) ->
    shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    ok = shigoto:drain_queue(<<"default">>),
    {ok, []} = shigoto_repo:claim_jobs(shigoto_test_repo, <<"default">>, 10).

test_prune_old_jobs(_Config) ->
    {ok, Job} = shigoto_repo:insert_job(shigoto_test_repo, #{
        worker => shigoto_test_worker,
        args => #{<<"action">> => <<"succeed">>}
    }, #{}),
    shigoto_repo:complete_job(shigoto_test_repo, maps:get(id, Job)),
    %% Prune with 0 days = prune everything completed
    {ok, Count} = shigoto_repo:prune_jobs(shigoto_test_repo, 0),
    ?assert(Count >= 1).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

cleanup_jobs() ->
    kura_repo_worker:pgo_query(shigoto_test_repo, <<"DELETE FROM shigoto_jobs">>, []),
    ok.
