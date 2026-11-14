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
    a_crash_in_perform_is_recorded_without_its_args/1,
    a_killed_worker_process_is_a_failure/1,
    a_perform_that_returns_nonsense_is_a_failure/1,
    cancelling_a_waiting_job_keeps_it_from_running/1,
    cancelling_a_running_job_stops_its_worker/1,
    a_cancel_from_another_node_stops_the_worker/1,
    a_killed_executor_takes_its_worker_down/1,
    stopping_the_application_stops_a_running_worker/1,
    a_dead_nodes_job_is_rescued_and_rerun/1,
    a_rescued_job_is_not_rescued_again_while_it_runs/1,
    a_job_that_kills_its_node_is_discarded_at_max_attempts/1,
    a_stale_executor_cannot_complete_a_reclaimed_job/1,
    a_superseded_run_is_stopped_at_the_next_heartbeat/1,
    a_heartbeat_keeps_a_live_job_from_rescue/1,
    a_burst_of_notifications_leaves_one_poll_timer/1,
    the_pruner_archives_old_finished_jobs/1,
    every_fanout_consumer_runs_a_job/1,
    an_unknown_worker_fails_the_job_not_the_queue/1,
    a_module_that_is_not_a_worker_fails_the_job/1,
    a_batch_callback_runs_after_its_jobs/1,
    a_cancelled_batch_job_still_finishes_the_batch/1,
    a_child_runs_after_its_parent_with_the_result/1,
    a_discarded_parent_follows_each_childs_policy/1,
    a_burst_of_jobs_all_complete/1,
    a_workers_gates_are_set_up_once/1
]).

-define(POOL, shigoto_test_pool).
-define(QUEUE, ~"default").
-define(FANOUT, ~"broadcast").
-define(ENV_KEYS, [
    queues,
    poll_interval,
    heartbeat_interval,
    rescue_interval,
    stage_interval,
    notifier,
    fanout_queues,
    shutdown_timeout
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
        a_crash_in_perform_is_recorded_without_its_args,
        a_killed_worker_process_is_a_failure,
        a_perform_that_returns_nonsense_is_a_failure,
        cancelling_a_waiting_job_keeps_it_from_running,
        cancelling_a_running_job_stops_its_worker,
        a_cancel_from_another_node_stops_the_worker,
        a_killed_executor_takes_its_worker_down,
        stopping_the_application_stops_a_running_worker,
        a_dead_nodes_job_is_rescued_and_rerun,
        a_rescued_job_is_not_rescued_again_while_it_runs,
        a_job_that_kills_its_node_is_discarded_at_max_attempts,
        a_stale_executor_cannot_complete_a_reclaimed_job,
        a_superseded_run_is_stopped_at_the_next_heartbeat,
        a_heartbeat_keeps_a_live_job_from_rescue,
        a_burst_of_notifications_leaves_one_poll_timer,
        the_pruner_archives_old_finished_jobs,
        every_fanout_consumer_runs_a_job,
        an_unknown_worker_fails_the_job_not_the_queue,
        a_module_that_is_not_a_worker_fails_the_job,
        a_batch_callback_runs_after_its_jobs,
        a_cancelled_batch_job_still_finishes_the_batch,
        a_child_runs_after_its_parent_with_the_result,
        a_discarded_parent_follows_each_childs_policy,
        a_burst_of_jobs_all_complete,
        a_workers_gates_are_set_up_once
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
            rescue_interval => 200,
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
overrides(a_cancel_from_another_node_stops_the_worker) ->
    #{heartbeat_interval => 300};
overrides(a_superseded_run_is_stopped_at_the_next_heartbeat) ->
    #{heartbeat_interval => 300};
overrides(a_heartbeat_keeps_a_live_job_from_rescue) ->
    #{heartbeat_interval => 300};
overrides(stopping_the_application_stops_a_running_worker) ->
    #{shutdown_timeout => 200};
overrides(every_fanout_consumer_runs_a_job) ->
    #{fanout_queues => [{?FANOUT, 5, #{window => 60}}]};
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

a_crash_in_perform_is_recorded_without_its_args(_Config) ->
    Id = enqueue(~"crash-191212121212"),
    instruct(performing(~"crash-191212121212"), no_clause),
    Failed = await(Id, ~"retryable"),
    Stored = maps:get(errors, Failed),
    ?assertMatch([#{~"error" := <<"error:function_clause", _/binary>>}], errors(Failed)),
    ?assertNotEqual(nomatch, binary:match(Stored, ~"only_absent")),
    ?assertEqual(nomatch, binary:match(Stored, ~"191212121212")),
    instruct(performing(~"crash-191212121212"), crash),
    Again = await(Id, ~"retryable"),
    ?assertMatch(
        [_, #{~"error" := <<"error:deliberate_crash", _/binary>>, ~"attempt" := 2}], errors(Again)
    ),
    instruct(performing(~"crash-191212121212"), {return, ok}),
    ?assertMatch(#{attempt := 3}, await(Id, ~"completed")).

a_killed_worker_process_is_a_failure(_Config) ->
    Id = enqueue(~"killed"),
    instruct(performing(~"killed"), die),
    Failed = await(Id, ~"retryable"),
    ?assertMatch([#{~"error" := ~"killed"}], errors(Failed)),
    instruct(performing(~"killed"), {return, ok}),
    _ = await(Id, ~"completed").

a_perform_that_returns_nonsense_is_a_failure(_Config) ->
    Id = enqueue(~"nonsense"),
    instruct(performing(~"nonsense"), {return, {done, ~"191212121212"}}),
    Failed = await(Id, ~"retryable"),
    ?assertMatch([#{~"error" := <<"error:function_clause", _/binary>>}], errors(Failed)),
    ?assertEqual(nomatch, binary:match(maps:get(errors, Failed), ~"191212121212")),
    instruct(performing(~"nonsense"), {return, ok}),
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

cancelling_a_running_job_stops_its_worker(_Config) ->
    Id = enqueue(~"cancelled-running"),
    Worker = performing(~"cancelled-running"),
    ok = shigoto:cancel(Id),
    ok = stopped(Worker, 2000),
    ok = wait_for(fun() -> executors_of(Id) =:= [] end),
    timer:sleep(300),
    ?assertMatch(#{state := ~"cancelled", attempt := 1, errors := ~"[]"}, row(Id)),
    %% The slot the cancelled job held is free again.
    [enqueue(Tag) || Tag <- slots()],
    [instruct(performing(Tag), {return, ok}) || Tag <- slots()],
    ok.

a_cancel_from_another_node_stops_the_worker(_Config) ->
    Id = enqueue(~"cancelled-elsewhere"),
    Worker = performing(~"cancelled-elsewhere"),
    %% What a cancel on another node amounts to here: the row changes and
    %% nothing on this node is told.
    ok = shigoto_repo:cancel_job(?POOL, Id),
    ok = stopped(Worker, 2000),
    ok = wait_for(fun() -> executors_of(Id) =:= [] end),
    ?assertMatch(#{state := ~"cancelled", errors := ~"[]"}, row(Id)).

stopping_the_application_stops_a_running_worker(_Config) ->
    Id = enqueue(~"shut-down"),
    Worker = performing(~"shut-down"),
    ok = application:stop(shigoto),
    ok = stopped(Worker, 2000),
    %% Nothing was recorded: the row waits for the stale-job rescue.
    ?assertMatch(#{state := ~"executing", attempt := 1, errors := ~"[]"}, row(Id)).

%%----------------------------------------------------------------------
%% A node that dies
%%----------------------------------------------------------------------

a_killed_executor_takes_its_worker_down(_Config) ->
    Id = enqueue(~"orphaned"),
    Worker = performing(~"orphaned"),
    [exit(Executor, kill) || Executor <- executors_of(Id)],
    ok = stopped(Worker, 2000).

a_dead_nodes_job_is_rescued_and_rerun(_Config) ->
    Id = enqueue(~"rescued"),
    _ = performing(~"rescued"),
    ok = node_dies(Id),
    ?assertMatch(#{state := ~"executing", attempt := 1}, row(Id)),
    instruct(performing(~"rescued"), {return, ok}),
    Row = await(Id, ~"completed"),
    ?assertMatch(#{attempt := 2}, Row),
    ?assertMatch([#{~"error" := ~"rescued", ~"attempt" := 1}], errors(Row)).

a_rescued_job_is_not_rescued_again_while_it_runs(_Config) ->
    Id = enqueue(~"rescued-once"),
    _ = performing(~"rescued-once"),
    ok = node_dies(Id),
    Second = performing(~"rescued-once"),
    #{heartbeat_at := Heartbeat, attempted_at := Attempted} = row(Id),
    ?assertEqual(Attempted, Heartbeat),
    ok = idle(~"rescued-once", 1000),
    ?assertMatch(#{state := ~"executing", attempt := 2}, row(Id)),
    instruct(Second, {return, ok}),
    ?assertMatch(#{attempt := 2}, await(Id, ~"completed")).

a_job_that_kills_its_node_is_discarded_at_max_attempts(_Config) ->
    Id = enqueue(~"poison", #{max_attempts => 2}),
    _ = performing(~"poison"),
    ok = node_dies(Id),
    _ = performing(~"poison"),
    ok = node_dies(Id),
    Row = await(Id, ~"discarded"),
    ?assertMatch(#{attempt := 2}, Row),
    ?assertNotEqual(null, maps:get(discarded_at, Row)),
    ?assertMatch([#{~"error" := ~"rescued"}, #{~"error" := ~"rescued"}], errors(Row)),
    receive
        {discarded, ~"poison", [_, _]} -> ok
    after 2000 -> ct:fail(on_discard_not_called)
    end,
    ok = idle(~"poison", 1000).

a_stale_executor_cannot_complete_a_reclaimed_job(_Config) ->
    ok = telemetry:attach(?MODULE, [shigoto, job, lost], fun ?MODULE:forward/4, self()),
    Id = enqueue(~"fenced"),
    First = performing(~"fenced"),
    %% The node holding the job goes quiet without dying: the job is rescued
    %% and claimed again while the first run is still going.
    ok = expire(Id),
    Second = performing(~"fenced"),
    instruct(First, {return, {ok, ~"stale"}}),
    receive
        {telemetry, [shigoto, job, lost], #{count := 1}, Meta} ->
            ?assertMatch(#{job_id := Id, attempt := 1, transition := completed}, Meta)
    after 2000 -> ct:fail(lost_transition_not_reported)
    end,
    ?assertMatch(#{state := ~"executing", attempt := 2, result := null}, row(Id)),
    instruct(Second, {return, {ok, ~"current"}}),
    Row = await(Id, ~"completed"),
    ?assertEqual(~"current", json:decode(maps:get(result, Row))).

a_superseded_run_is_stopped_at_the_next_heartbeat(_Config) ->
    Id = enqueue(~"superseded"),
    First = performing(~"superseded"),
    %% What a rescue on another node does to the row.
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET state = 'available', heartbeat_at = NULL WHERE id = $1", [
            Id
        ]
    ),
    Second = performing(~"superseded"),
    ok = stopped(First, 2000),
    ?assert(is_process_alive(Second)),
    instruct(Second, {return, ok}),
    ?assertMatch(#{attempt := 2, errors := ~"[]"}, await(Id, ~"completed")).

a_heartbeat_keeps_a_live_job_from_rescue(_Config) ->
    Id = enqueue(~"alive"),
    Worker = performing(~"alive"),
    ok = wait_for(fun() -> maps:get(heartbeat_at, row(Id)) > maps:get(attempted_at, row(Id)) end),
    #{heartbeat_at := Earlier} = row(Id),
    ok = wait_for(fun() -> maps:get(heartbeat_at, row(Id)) > Earlier end),
    %% Longer than the stale threshold, with a rescue pass every 200 ms.
    ok = idle(~"alive", 1500),
    ?assertMatch(#{state := ~"executing", attempt := 1}, row(Id)),
    instruct(Worker, {return, ok}),
    ?assertMatch(#{attempt := 1, errors := ~"[]"}, await(Id, ~"completed")).

a_workers_gates_are_set_up_once(_Config) ->
    First = enqueue(~"gates-first"),
    instruct(performing(~"gates-first"), {return, ok}),
    _ = await(First, ~"completed"),
    ok = wait_for(fun() -> executors_of(First) =:= [] end),
    %% The executor that set them up is gone; what it set up is remembered.
    ?assert(ets:member(shigoto_resilience_init, shigoto_lifecycle_worker)),
    ?assertEqual(whereis(shigoto_executor_sup), ets:info(shigoto_resilience_init, owner)),
    Second = enqueue(~"gates-second"),
    instruct(performing(~"gates-second"), {return, ok}),
    _ = await(Second, ~"completed").

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
%% Fanout
%%----------------------------------------------------------------------

every_fanout_consumer_runs_a_job(_Config) ->
    Id = enqueue(~"broadcast", #{queue => ?FANOUT}),
    First = performing(~"broadcast"),
    instruct(First, {return, {error, this_node_failed}}),
    ok = stopped(First, 2000),
    ok = wait_for(fun() -> executors_of(Id) =:= [] end),
    %% A second node's consumer, polling after the first one finished.
    {ok, Consumer} = shigoto_fanout_queue:start_link(?FANOUT, 5, #{window => 60}),
    try
        Second = performing(~"broadcast"),
        instruct(Second, {return, ok}),
        ok = stopped(Second, 2000),
        ok = wait_for(fun() -> executors_of(Id) =:= [] end),
        ok = idle(~"broadcast", 500),
        ?assertMatch(#{state := ~"available", attempt := 0, errors := ~"[]"}, row(Id))
    after
        unlink(Consumer),
        exit(Consumer, kill)
    end.

%%----------------------------------------------------------------------
%% Workers that cannot run
%%----------------------------------------------------------------------

an_unknown_worker_fails_the_job_not_the_queue(_Config) ->
    Queue = queue_pid(),
    Id = insert_row(~"shigoto_no_such_worker_module", ~"{}", 2),
    Failed = await(Id, ~"retryable"),
    ?assertMatch(
        [#{~"error" := ~"unknown_worker:<<\"shigoto_no_such_worker_module\">>"}], errors(Failed)
    ),
    %% No worker module, so the default backoff applies: up to half a minute.
    ok = due(Id),
    Row = await(Id, ~"discarded"),
    ?assertMatch(#{attempt := 2}, Row),
    ?assertMatch([_, _], errors(Row)),
    ?assertEqual(Queue, queue_pid()),
    Next = enqueue(~"after-unknown"),
    instruct(performing(~"after-unknown"), {return, ok}),
    _ = await(Next, ~"completed").

a_module_that_is_not_a_worker_fails_the_job(_Config) ->
    Id = insert_row(~"lists", ~"{\"ssn\": \"191212121212\"}", 1),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"error" := ~"unknown_worker:<<\"lists\">>"}], errors(Row)),
    ?assertEqual(nomatch, binary:match(maps:get(errors, Row), ~"191212121212")).

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

a_cancelled_batch_job_still_finishes_the_batch(_Config) ->
    BatchId = new_batch(),
    ok = shigoto:pause_queue(?QUEUE),
    Kept = enqueue(~"batch-kept", #{batch => BatchId}),
    Cancelled = enqueue(~"batch-cancelled", #{batch => BatchId}),
    ok = shigoto:cancel(Cancelled),
    ok = shigoto:resume_queue(?QUEUE),
    instruct(performing(~"batch-kept"), {return, ok}),
    _ = await(Kept, ~"completed"),
    receive
        {batch_callback, Args} -> ?assertMatch(#{~"_batch_event" := ~"discard"}, Args)
    after 5000 -> ct:fail(no_batch_callback)
    end,
    ?assertMatch(
        {ok, #{total_jobs := 2, completed_jobs := 1, discarded_jobs := 1}},
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

a_discarded_parent_follows_each_childs_policy(_Config) ->
    Parent = enqueue(~"policy-parent", #{max_attempts => 1}),
    Runs = enqueue(~"policy-run", #{depends_on => [Parent]}),
    Cancels = enqueue(~"policy-cancel", #{depends_on => [Parent], on_dependency_failure => cancel}),
    Discards = enqueue(
        ~"policy-discard", #{depends_on => [Parent], on_dependency_failure => discard}
    ),
    Grandchild = enqueue(
        ~"policy-grandchild", #{depends_on => [Cancels], on_dependency_failure => cancel}
    ),
    Released = enqueue(~"policy-released", #{depends_on => [Cancels]}),
    instruct(performing(~"policy-parent"), {return, {error, gone}}),
    _ = await(Parent, ~"discarded"),
    ?assertMatch(#{state := ~"cancelled", attempt := 0}, await(Cancels, ~"cancelled")),
    ?assertMatch(#{state := ~"cancelled", attempt := 0}, await(Grandchild, ~"cancelled")),
    DiscardedRow = await(Discards, ~"discarded"),
    ?assertMatch([#{~"error" := ~"dependency_failed"}], errors(DiscardedRow)),
    receive
        {discarded, ~"policy-discard", [_]} -> ok
    after 2000 -> ct:fail(on_discard_not_called)
    end,
    {RunWorker, Args} = performing_with_args(~"policy-run"),
    ?assertEqual(#{Parent => null}, maps:get(deps_results, Args)),
    instruct(RunWorker, {return, ok}),
    instruct(performing(~"policy-released"), {return, ok}),
    _ = await(Runs, ~"completed"),
    _ = await(Released, ~"completed"),
    ok = idle(~"policy-cancel", 300),
    ok = idle(~"policy-grandchild", 0),
    ok = idle(~"policy-discard", 0).

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

insert_row(Worker, Args, MaxAttempts) ->
    #{rows := [#{id := Id}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, max_attempts)
        VALUES ($1, $2, $3::jsonb, $4) RETURNING id
        """,
        [?QUEUE, Worker, Args, MaxAttempts]
    ),
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

stopped(Pid, Ms) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after Ms ->
        demonitor(Ref, [flush]),
        ct:fail({still_running, Pid})
    end.

slots() ->
    [iolist_to_binary([~"slot-", integer_to_binary(N)]) || N <- lists:seq(1, 5)].

%% The node running the job goes away: its queue and the job's executor die
%% with nothing written, and the row's heartbeat ages past the stale threshold.

node_dies(Id) ->
    exit(queue_pid(), kill),
    [exit(Executor, kill) || Executor <- executors_of(Id)],
    ok = wait_for(fun() -> executors_of(Id) =:= [] end),
    expire(Id).

expire(Id) ->
    #{} = shigoto_db:query(
        ?POOL,
        ~"""
        UPDATE shigoto_jobs
        SET heartbeat_at = now() - interval '1 hour', attempted_at = now() - interval '1 hour'
        WHERE id = $1
        """,
        [Id]
    ),
    ok.

due(Id) ->
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET scheduled_at = now() WHERE id = $1", [Id]
    ),
    ok.

queue_pid() ->
    case lists:keyfind({shigoto_queue, ?QUEUE}, 1, supervisor:which_children(shigoto_queue_sup)) of
        {_, Pid, worker, _} when is_pid(Pid) -> Pid;
        _ -> ct:fail(no_queue_process)
    end.

executors_of(Id) ->
    [Pid || Pid <- shigoto_executor:running(Id), is_process_alive(Pid)].

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
