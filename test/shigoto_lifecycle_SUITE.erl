-module(shigoto_lifecycle_SUITE).
-behaviour(ct_suite).
-moduledoc """
The job lifecycle through the running application: the real queue, executor,
heartbeat, stager, notifier and pruner processes against PostgreSQL. Nothing
here calls the repo to move a job along; a case inserts a job and watches what
the application does with it.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([forward/4]).
-export([
    polling_alone_runs_an_inserted_job/1,
    a_notification_wakes_the_queue/1,
    a_scheduled_job_runs_when_due/1,
    a_snoozed_job_runs_again_later/1,
    a_failed_job_runs_again_after_its_backoff/1,
    a_retry_is_woken_by_the_stager/1,
    a_job_out_of_attempts_is_discarded/1,
    a_killed_worker_process_is_a_failure/1,
    cancelling_a_waiting_job_keeps_it_from_running/1,
    a_burst_of_notifications_leaves_one_poll_timer/1,
    the_pruner_archives_old_finished_jobs/1,
    a_batch_callback_runs_after_its_jobs/1,
    a_child_runs_after_its_parent_with_the_result/1,
    a_burst_of_jobs_all_complete/1
]).

-define(POOL, shigoto_test_pool).
-define(QUEUE, ~"default").
-define(ENV_KEYS, [
    queues,
    poll_interval,
    heartbeat_interval,
    stage_interval,
    notifier,
    fanout_queues
]).

all() ->
    [
        polling_alone_runs_an_inserted_job,
        a_notification_wakes_the_queue,
        a_scheduled_job_runs_when_due,
        a_snoozed_job_runs_again_later,
        a_failed_job_runs_again_after_its_backoff,
        a_retry_is_woken_by_the_stager,
        a_job_out_of_attempts_is_discarded,
        a_killed_worker_process_is_a_failure,
        cancelling_a_waiting_job_keeps_it_from_running,
        a_burst_of_notifications_leaves_one_poll_timer,
        the_pruner_archives_old_finished_jobs,
        a_batch_callback_runs_after_its_jobs,
        a_child_runs_after_its_parent_with_the_result,
        a_burst_of_jobs_all_complete
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    case application:load(shigoto) of
        ok -> ok;
        {error, {already_loaded, shigoto}} -> ok
    end,
    Config.

end_per_suite(_Config) ->
    shigoto_migration:down(?POOL),
    ok.

init_per_testcase(TestCase, Config) ->
    ok = clean(),
    Env = env(TestCase),
    [application:set_env(shigoto, Key, Value) || Key := Value <- Env],
    application:set_env(shigoto, pool, ?POOL),
    {ok, _} = application:ensure_all_started(shigoto),
    case Env of
        #{notifier := _} -> ok = wait_for(fun notifier_listening/0);
        #{} -> ok
    end,
    Config.

end_per_testcase(_TestCase, _Config) ->
    _ = telemetry:detach(?MODULE),
    _ = application:stop(shigoto),
    %% seki keeps a circuit breaker per worker; one case's failures must not
    %% open it for the next.
    _ = application:stop(seki),
    [application:unset_env(shigoto, Key) || Key <- ?ENV_KEYS],
    ok = clean().

env(TestCase) ->
    maps:merge(
        #{
            queues => [{?QUEUE, 5}],
            poll_interval => 100,
            heartbeat_interval => 5000,
            stage_interval => 200
        },
        overrides(TestCase)
    ).

overrides(a_notification_wakes_the_queue) ->
    #{poll_interval => 60000, notifier => connection()};
overrides(a_scheduled_job_runs_when_due) ->
    #{poll_interval => 60000, notifier => connection()};
overrides(a_retry_is_woken_by_the_stager) ->
    #{poll_interval => 60000, notifier => connection()};
overrides(a_burst_of_notifications_leaves_one_poll_timer) ->
    #{poll_interval => 200, notifier => connection()};
overrides(_TestCase) ->
    #{}.

%%----------------------------------------------------------------------
%% Running a job
%%----------------------------------------------------------------------

polling_alone_runs_an_inserted_job(_Config) ->
    ?assertEqual(undefined, whereis(shigoto_notifier)),
    Id = enqueue(~"polled"),
    Worker = performing(~"polled"),
    ?assertMatch(#{state := ~"executing", attempt := 1}, row(Id)),
    instruct(Worker, {return, {ok, #{~"answer" => 42}}}),
    Row = await(Id, ~"completed"),
    ?assertMatch(#{attempt := 1, errors := ~"[]"}, Row),
    ?assertNotEqual(null, maps:get(completed_at, Row)),
    ?assertEqual(#{~"answer" => 42}, json:decode(maps:get(result, Row))).

a_notification_wakes_the_queue(_Config) ->
    %% The poll timer is a minute away, so only the NOTIFY from the insert
    %% trigger can have started this job.
    Id = enqueue(~"notified"),
    Worker = performing(~"notified"),
    instruct(Worker, {return, ok}),
    _ = await(Id, ~"completed").

a_scheduled_job_runs_when_due(_Config) ->
    Id = enqueue(~"scheduled", #{scheduled_at => seconds_from_now(2)}),
    ok = idle(~"scheduled", 800),
    ?assertMatch(#{state := ~"available", attempt := 0}, row(Id)),
    Worker = performing(~"scheduled"),
    instruct(Worker, {return, ok}),
    _ = await(Id, ~"completed").

a_snoozed_job_runs_again_later(_Config) ->
    Id = enqueue(~"snoozed"),
    instruct(performing(~"snoozed"), {return, {snooze, 1}}),
    Snoozed = await(Id, ~"available"),
    ?assertMatch(#{attempt := 1, max_attempts := 4, errors := ~"[]"}, Snoozed),
    instruct(performing(~"snoozed"), {return, ok}),
    ?assertMatch(#{attempt := 2, max_attempts := 4}, await(Id, ~"completed")).

%%----------------------------------------------------------------------
%% Failing and retrying
%%----------------------------------------------------------------------

a_failed_job_runs_again_after_its_backoff(_Config) ->
    Id = enqueue(~"retried"),
    instruct(performing(~"retried"), {return, {error, first_try}}),
    Failed = await(Id, ~"retryable"),
    ?assertMatch(#{attempt := 1}, Failed),
    ?assertMatch([#{~"attempt" := 1, ~"error" := ~"first_try"}], errors(Failed)),
    instruct(performing(~"retried"), {return, ok}),
    Done = await(Id, ~"completed"),
    ?assertMatch(#{attempt := 2}, Done),
    ?assertMatch([_], errors(Done)).

a_retry_is_woken_by_the_stager(_Config) ->
    Id = enqueue(~"staged"),
    instruct(performing(~"staged"), {return, {error, first_try}}),
    _ = await(Id, ~"retryable"),
    instruct(performing(~"staged"), {return, ok}),
    ?assertMatch(#{attempt := 2}, await(Id, ~"completed")).

a_job_out_of_attempts_is_discarded(_Config) ->
    Id = enqueue(~"exhausted", #{max_attempts => 2}),
    instruct(performing(~"exhausted"), {return, {error, first_try}}),
    instruct(performing(~"exhausted"), {return, {error, second_try}}),
    Row = await(Id, ~"discarded"),
    ?assertMatch(#{attempt := 2}, Row),
    ?assertNotEqual(null, maps:get(discarded_at, Row)),
    ?assertMatch(
        [#{~"error" := ~"first_try"}, #{~"error" := ~"second_try"}], errors(Row)
    ),
    receive
        {discarded, ~"exhausted", [_, _]} -> ok
    after 2000 -> ct:fail(on_discard_not_called)
    end,
    ok = idle(~"exhausted", 1500).

a_killed_worker_process_is_a_failure(_Config) ->
    Id = enqueue(~"killed"),
    instruct(performing(~"killed"), die),
    Failed = await(Id, ~"retryable"),
    ?assertMatch([#{~"error" := ~"killed"}], errors(Failed)),
    instruct(performing(~"killed"), {return, ok}),
    _ = await(Id, ~"completed").

%%----------------------------------------------------------------------
%% Cancelling
%%----------------------------------------------------------------------

cancelling_a_waiting_job_keeps_it_from_running(_Config) ->
    ok = shigoto:pause_queue(?QUEUE),
    Id = enqueue(~"cancelled-waiting"),
    ok = shigoto:cancel(Id),
    ok = shigoto:resume_queue(?QUEUE),
    ok = idle(~"cancelled-waiting", 500),
    Row = row(Id),
    ?assertMatch(#{state := ~"cancelled", attempt := 0}, Row),
    ?assertNotEqual(null, maps:get(cancelled_at, Row)).

%%----------------------------------------------------------------------
%% Waking up
%%----------------------------------------------------------------------

a_burst_of_notifications_leaves_one_poll_timer(_Config) ->
    ok = telemetry:attach(?MODULE, [shigoto, queue, poll], fun ?MODULE:forward/4, self()),
    [
        #{} = shigoto_db:query(?POOL, ~"SELECT pg_notify('shigoto_jobs_insert', $1)", [?QUEUE])
     || _ <- lists:seq(1, 50)
    ],
    timer:sleep(500),
    ok = flush_polls(),
    %% Two seconds at one poll every 200 ms.
    Polls = polls_within(2000),
    ?assert(Polls >= 5, Polls),
    ?assert(Polls =< 15, Polls).

%%----------------------------------------------------------------------
%% Pruning
%%----------------------------------------------------------------------

the_pruner_archives_old_finished_jobs(_Config) ->
    Old = enqueue(~"old"),
    Recent = enqueue(~"recent"),
    instruct(performing(~"old"), {return, ok}),
    instruct(performing(~"recent"), {return, ok}),
    _ = await(Old, ~"completed"),
    _ = await(Recent, ~"completed"),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET inserted_at = now() - interval '30 days' WHERE id = $1", [
            Old
        ]
    ),
    %% The pruner's own timer is hourly; this is the message it sends itself.
    shigoto_pruner ! prune,
    ok = wait_for(fun() -> archived(Old) end),
    ?assertMatch(#{rows := []}, shigoto_db:query(?POOL, select_job(), [Old])),
    ?assertNot(archived(Recent)),
    ?assertMatch(#{state := ~"completed"}, row(Recent)).

%%----------------------------------------------------------------------
%% Batches and dependencies
%%----------------------------------------------------------------------

a_batch_callback_runs_after_its_jobs(_Config) ->
    BatchId = new_batch(),
    One = enqueue(~"batch-one", #{batch => BatchId}),
    Two = enqueue(~"batch-two", #{batch => BatchId}),
    FirstWorker = performing(~"batch-one"),
    SecondWorker = performing(~"batch-two"),
    instruct(FirstWorker, {return, ok}),
    _ = await(One, ~"completed"),
    receive
        {batch_callback, _} -> ct:fail(callback_before_the_batch_finished)
    after 300 -> ok
    end,
    instruct(SecondWorker, {return, ok}),
    _ = await(Two, ~"completed"),
    receive
        {batch_callback, Args} -> ?assertNot(maps:is_key(~"_batch_event", Args))
    after 5000 -> ct:fail(no_batch_callback)
    end,
    ?assertMatch(
        {ok, #{total_jobs := 2, completed_jobs := 2, state := ~"callback_completing"}},
        shigoto:get_batch(BatchId)
    ).

a_child_runs_after_its_parent_with_the_result(_Config) ->
    Parent = enqueue(~"parent"),
    Child = enqueue(~"child", #{depends_on => [Parent]}),
    ParentWorker = performing(~"parent"),
    ok = idle(~"child", 400),
    instruct(ParentWorker, {return, {ok, #{~"rows" => 3}}}),
    {ChildWorker, Args} = performing_with_args(~"child"),
    ?assertEqual(#{Parent => #{~"rows" => 3}}, maps:get(deps_results, Args)),
    instruct(ChildWorker, {return, ok}),
    _ = await(Child, ~"completed").

a_burst_of_jobs_all_complete(_Config) ->
    Tags = [iolist_to_binary([~"burst-", integer_to_binary(N)]) || N <- lists:seq(1, 40)],
    Ids = [enqueue(Tag) || Tag <- Tags],
    ok = answer_all(length(Tags)),
    [
        ?assertMatch(#{attempt := 1, errors := ~"[]"}, await(Id, ~"completed"))
     || Id <- Ids
    ],
    ok.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

-doc false.
forward(Event, Measurements, Metadata, Owner) ->
    Owner ! {telemetry, Event, Measurements, Metadata},
    ok.

enqueue(Tag) ->
    enqueue(Tag, #{}).

enqueue(Tag, Extra) ->
    Params = Extra#{
        worker => shigoto_lifecycle_worker,
        args => #{~"test" => list_to_binary(pid_to_list(self())), ~"tag" => Tag}
    },
    {ok, #{id := Id}} = shigoto:insert(Params),
    Id.

new_batch() ->
    {ok, #{id := BatchId}} = shigoto:new_batch(#{
        callback_worker => shigoto_batch_callback_worker,
        callback_args => #{~"test_pid" => list_to_binary(pid_to_list(self()))}
    }),
    BatchId.

performing(Tag) ->
    {Worker, _Args} = performing_with_args(Tag),
    Worker.

performing_with_args(Tag) ->
    receive
        {performing, Tag, Worker, Args} -> {Worker, Args}
    after 5000 -> ct:fail({never_performed, Tag})
    end.

idle(Tag, Ms) ->
    receive
        {performing, Tag, _Worker, _Args} -> ct:fail({performed, Tag})
    after Ms -> ok
    end.

instruct(Worker, Instruction) ->
    Worker ! {instruct, Instruction},
    ok.

answer_all(0) ->
    ok;
answer_all(Left) ->
    receive
        {performing, _Tag, Worker, _Args} ->
            instruct(Worker, {return, ok}),
            answer_all(Left - 1)
    after 10000 -> ct:fail({unanswered, Left})
    end.

row(Id) ->
    #{rows := [Row]} = shigoto_db:query(?POOL, select_job(), [Id]),
    Row.

select_job() ->
    ~"SELECT * FROM shigoto_jobs WHERE id = $1".

errors(#{errors := Errors}) ->
    json:decode(Errors).

archived(Id) ->
    #{rows := Rows} = shigoto_db:query(
        ?POOL, ~"SELECT id FROM shigoto_jobs_archive WHERE id = $1", [Id]
    ),
    Rows =/= [].

await(Id, State) ->
    await(Id, State, 200).

await(Id, State, 0) ->
    ct:fail({never_reached, State, row(Id)});
await(Id, State, Tries) ->
    case row(Id) of
        #{state := State} = Row ->
            Row;
        _Other ->
            timer:sleep(25),
            await(Id, State, Tries - 1)
    end.

wait_for(Check) ->
    wait_for(Check, 200).

wait_for(_Check, 0) ->
    ct:fail(condition_not_met);
wait_for(Check, Tries) ->
    case Check() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_for(Check, Tries - 1)
    end.

flush_polls() ->
    receive
        {telemetry, [shigoto, queue, poll], _, _} -> flush_polls()
    after 0 -> ok
    end.

polls_within(Ms) ->
    polls_until(erlang:monotonic_time(millisecond) + Ms, 0).

polls_until(Deadline, Count) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 ->
            receive
                {telemetry, [shigoto, queue, poll], _, _} -> polls_until(Deadline, Count + 1)
            after Left -> Count
            end;
        _Passed ->
            Count
    end.

seconds_from_now(Seconds) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(calendar:universal_time()) + Seconds
    ).

notifier_listening() ->
    case sys:get_state(shigoto_notifier) of
        {state, undefined} -> false;
        {state, _Listener} -> true
    end.

connection() ->
    #{
        host => "localhost",
        port => shigoto_test_repo:port(),
        database => "shigoto_test",
        user => "postgres",
        password => "root"
    }.

clean() ->
    [
        #{} = shigoto_db:query(?POOL, SQL, [])
     || SQL <- [
            ~"DELETE FROM shigoto_jobs",
            ~"DELETE FROM shigoto_jobs_archive",
            ~"DELETE FROM shigoto_batches"
        ]
    ],
    ok.
