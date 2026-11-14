-module(shigoto_bench_SUITE).
-behaviour(ct_suite).

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    bench_insert_single/1,
    bench_insert_bulk_100/1,
    bench_insert_bulk_1000/1,
    bench_insert_unique/1,
    bench_claim_and_complete/1,
    bench_claim_and_complete_concurrent/1,
    bench_full_lifecycle/1,
    bench_full_lifecycle_10_queues/1,
    bench_insert_with_encryption/1,
    bench_insert_with_deps/1,
    bench_global_concurrency_check/1
]).

-define(POOL, shigoto_test_pool).

all() ->
    [{group, benchmarks}].

groups() ->
    [
        {benchmarks, [sequence], [
            bench_insert_single,
            bench_insert_bulk_100,
            bench_insert_bulk_1000,
            bench_insert_unique,
            bench_claim_and_complete,
            bench_claim_and_complete_concurrent,
            bench_full_lifecycle,
            bench_full_lifecycle_10_queues,
            bench_insert_with_encryption,
            bench_insert_with_deps,
            bench_global_concurrency_check
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    cleanup(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup(),
    ok.

%%----------------------------------------------------------------------
%% Insert benchmarks
%%----------------------------------------------------------------------

bench_insert_single(Config) ->
    N = 1000,
    {Time, _} = timer:tc(fun() ->
        insert_n(N)
    end),
    report(Config, ~"insert_single", N, Time).

bench_insert_bulk_100(Config) ->
    Batches = 100,
    BatchSize = 100,
    N = Batches * BatchSize,
    {Time, _} = timer:tc(fun() ->
        insert_bulk(Batches, BatchSize)
    end),
    report(Config, ~"insert_bulk_100", N, Time).

bench_insert_bulk_1000(Config) ->
    Batches = 10,
    BatchSize = 1000,
    N = Batches * BatchSize,
    {Time, _} = timer:tc(fun() ->
        insert_bulk(Batches, BatchSize)
    end),
    report(Config, ~"insert_bulk_1000", N, Time).

bench_insert_unique(Config) ->
    N = 1000,
    Unique = #{keys => [worker, args], states => [available]},
    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(I) ->
                shigoto_repo:insert_job(
                    ?POOL,
                    #{worker => shigoto_test_worker, args => #{~"i" => I}},
                    #{unique => Unique}
                )
            end,
            lists:seq(1, N)
        )
    end),
    report(Config, ~"insert_unique", N, Time).

bench_insert_with_encryption(Config) ->
    Key = crypto:strong_rand_bytes(32),
    application:set_env(shigoto, encryption_key, Key),
    N = 1000,
    {Time, _} = timer:tc(fun() ->
        insert_n(N)
    end),
    application:set_env(shigoto, encryption_key, undefined),
    report(Config, ~"insert_encrypted", N, Time).

bench_insert_with_deps(Config) ->
    N = 500,
    {Time, _} = timer:tc(fun() ->
        insert_chain(N)
    end),
    report(Config, ~"insert_with_deps", N, Time).

%%----------------------------------------------------------------------
%% Claim + complete benchmarks
%%----------------------------------------------------------------------

bench_claim_and_complete(Config) ->
    N = 1000,
    insert_n(N),
    {Time, _} = timer:tc(fun() ->
        claim_and_complete_loop(N)
    end),
    report(Config, ~"claim_complete", N, Time).

bench_claim_and_complete_concurrent(Config) ->
    N = 2000,
    Workers = 4,
    PerWorker = N div Workers,
    insert_n(N),
    Self = self(),
    {Time, _} = timer:tc(fun() ->
        Pids = [
            spawn_link(fun() ->
                claim_and_complete_loop(PerWorker),
                Self ! {done, self()}
            end)
         || _ <- lists:seq(1, Workers)
        ],
        wait_all(Pids)
    end),
    report(Config, ~"claim_complete_4x", N, Time).

%%----------------------------------------------------------------------
%% Full lifecycle benchmarks
%%----------------------------------------------------------------------

bench_full_lifecycle(Config) ->
    N = 500,
    {Time, _} = timer:tc(fun() ->
        insert_n(N),
        drain_all(~"default", N)
    end),
    report(Config, ~"full_lifecycle", N, Time).

bench_full_lifecycle_10_queues(Config) ->
    N = 1000,
    Queues = [<<"q", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 10)],
    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(I) when is_integer(I) ->
                Q = lists:nth((I rem 10) + 1, Queues),
                shigoto_repo:insert_job(
                    ?POOL,
                    #{worker => shigoto_test_worker, args => #{}, queue => Q},
                    #{}
                )
            end,
            lists:seq(1, N)
        ),
        lists:foreach(
            fun(Q) -> drain_all(Q, N div 10 + 1) end,
            Queues
        )
    end),
    report(Config, ~"lifecycle_10_queues", N, Time).

%%----------------------------------------------------------------------
%% Global concurrency benchmark
%%----------------------------------------------------------------------

bench_global_concurrency_check(Config) ->
    N = 1000,
    lists:foreach(
        fun(I) ->
            shigoto_repo:insert_job(
                ?POOL,
                #{worker => shigoto_global_conc_worker, args => #{~"i" => I}},
                #{}
            )
        end,
        lists:seq(1, N)
    ),
    {ok, Jobs} = shigoto_repo:claim_jobs(?POOL, ~"default", N),
    {Time, _} = timer:tc(fun() ->
        lists:foreach(
            fun(#{} = Job) ->
                shigoto_resilience:check_global_concurrency(shigoto_global_conc_worker, Job)
            end,
            Jobs
        )
    end),
    report(Config, ~"global_conc_check", length(Jobs), Time).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

insert_n(N) ->
    lists:foreach(
        fun(I) ->
            shigoto_repo:insert_job(
                ?POOL,
                #{worker => shigoto_test_worker, args => #{~"i" => I}},
                #{}
            )
        end,
        lists:seq(1, N)
    ).

insert_bulk(Batches, BatchSize) ->
    lists:foreach(
        fun(B) ->
            Jobs = [
                #{worker => shigoto_test_worker, args => #{~"b" => B, ~"i" => I}}
             || I <- lists:seq(1, BatchSize)
            ],
            shigoto_repo:insert_all(?POOL, Jobs, #{})
        end,
        lists:seq(1, Batches)
    ).

insert_chain(N) ->
    insert_chain(N, undefined).

insert_chain(0, _PrevId) ->
    ok;
insert_chain(N, undefined) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{~"step" => N}},
        #{}
    ),
    insert_chain(N - 1, maps:get(id, Job));
insert_chain(N, PrevId) ->
    {ok, #{} = Job} = shigoto_repo:insert_job(
        ?POOL,
        #{worker => shigoto_test_worker, args => #{~"step" => N}, depends_on => [PrevId]},
        #{}
    ),
    insert_chain(N - 1, maps:get(id, Job)).

claim_and_complete_loop(0) ->
    ok;
claim_and_complete_loop(Remaining) ->
    case shigoto_repo:claim_jobs(?POOL, ~"default", 10) of
        {ok, []} ->
            ok;
        {ok, Jobs} ->
            lists:foreach(
                fun(#{id := Id}) when is_integer(Id) ->
                    shigoto_repo:complete_job(?POOL, Id)
                end,
                Jobs
            ),
            claim_and_complete_loop(Remaining - length(Jobs))
    end.

drain_all(Queue, MaxIter) ->
    drain_all(Queue, MaxIter, 0).

drain_all(_Queue, 0, _Done) ->
    ok;
drain_all(Queue, Remaining, Done) ->
    case shigoto_repo:claim_jobs(?POOL, Queue, 10) of
        {ok, []} ->
            ok;
        {ok, Jobs} ->
            lists:foreach(
                fun(#{} = Job) ->
                    shigoto_executor:execute_sync(Job, ?POOL, 5000)
                end,
                Jobs
            ),
            drain_all(Queue, Remaining - 1, Done + length(Jobs))
    end.

wait_all([]) ->
    ok;
wait_all([Pid | Rest]) ->
    receive
        {done, Pid} -> wait_all(Rest)
    after 60000 ->
        ct:fail(timeout)
    end.

report(Config, Name, N, TimeMicros) ->
    TimeMs = TimeMicros / 1000,
    TimeSec = TimeMicros / 1_000_000,
    OpsPerSec = round(N / TimeSec),
    AvgMs = TimeMs / N,
    TotalStr = float_to_list(TimeMs, [{decimals, 1}]),
    AvgStr = float_to_list(AvgMs, [{decimals, 3}]),
    Line = io_lib:format(
        "~ts | ~ts ms | ~w jobs | ~ts ms/job | ~w jobs/sec",
        [Name, TotalStr, N, AvgStr, OpsPerSec]
    ),
    ct:pal("~ts", [Line]),
    ok = file:write_file(results_file(Config), [Line, "\n"], [append]).

results_file(Config) ->
    Path = io_lib:format("~ts/shigoto_bench.txt", [proplists:get_value(priv_dir, Config)]),
    case unicode:characters_to_binary(Path) of
        File when is_binary(File) -> File
    end.

cleanup() ->
    shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
    shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs_archive", []),
    shigoto_db:query(?POOL, ~"DELETE FROM shigoto_batches", []),
    ok.
