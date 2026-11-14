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
-export([forward/4, span_event/4]).
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
    a_retried_job_does_not_finish_its_batch_early/1,
    a_batch_left_unsettled_is_settled_by_the_sweep/1,
    a_job_waiting_on_an_ended_job_is_released_by_the_sweep/1,
    a_job_runs_in_the_context_it_was_inserted_in/1,
    every_attempt_gets_the_same_context/1,
    a_job_inserted_by_a_job_carries_on_from_it/1,
    a_released_dependent_keeps_its_own_context/1,
    a_bulk_and_a_transactional_insert_carry_the_context/1,
    a_batch_callback_carries_on_from_the_job_that_finished_the_batch/1,
    a_cron_job_gets_what_the_scheduler_injects/1,
    a_crash_ends_the_attempt_with_an_exception_event/1,
    a_propagator_that_misbehaves_fails_nothing/1,
    without_a_propagator_nothing_is_carried/1,
    a_child_runs_after_its_parent_with_the_result/1,
    a_discarded_parent_follows_each_childs_policy/1,
    a_burst_of_jobs_all_complete/1,
    a_workers_gates_are_set_up_once/1,
    a_declared_gate_is_not_skipped_without_seki/1,
    a_snoozed_job_gives_its_place_in_the_load_shedder_back/1,
    a_backlog_drains_without_waiting_for_the_poll_timer/1,
    cancelling_a_finished_job_reports_nothing/1,
    a_result_that_looks_like_a_frame_reaches_its_dependent/1
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
    shutdown_timeout,
    encryption_key,
    encryption_write_format,
    load_shedding,
    propagator
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
        a_retried_job_does_not_finish_its_batch_early,
        a_batch_left_unsettled_is_settled_by_the_sweep,
        a_job_waiting_on_an_ended_job_is_released_by_the_sweep,
        a_job_runs_in_the_context_it_was_inserted_in,
        every_attempt_gets_the_same_context,
        a_job_inserted_by_a_job_carries_on_from_it,
        a_released_dependent_keeps_its_own_context,
        a_bulk_and_a_transactional_insert_carry_the_context,
        a_batch_callback_carries_on_from_the_job_that_finished_the_batch,
        a_cron_job_gets_what_the_scheduler_injects,
        a_crash_ends_the_attempt_with_an_exception_event,
        a_propagator_that_misbehaves_fails_nothing,
        without_a_propagator_nothing_is_carried,
        a_child_runs_after_its_parent_with_the_result,
        a_discarded_parent_follows_each_childs_policy,
        a_burst_of_jobs_all_complete,
        a_workers_gates_are_set_up_once,
        a_declared_gate_is_not_skipped_without_seki,
        a_snoozed_job_gives_its_place_in_the_load_shedder_back,
        a_backlog_drains_without_waiting_for_the_poll_timer,
        cancelling_a_finished_job_reports_nothing,
        a_result_that_looks_like_a_frame_reaches_its_dependent
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

overrides(without_a_propagator_nothing_is_carried) ->
    #{};
overrides(TestCase) when
    TestCase =:= a_job_runs_in_the_context_it_was_inserted_in;
    TestCase =:= every_attempt_gets_the_same_context;
    TestCase =:= a_job_inserted_by_a_job_carries_on_from_it;
    TestCase =:= a_released_dependent_keeps_its_own_context;
    TestCase =:= a_bulk_and_a_transactional_insert_carry_the_context;
    TestCase =:= a_batch_callback_carries_on_from_the_job_that_finished_the_batch;
    TestCase =:= a_cron_job_gets_what_the_scheduler_injects;
    TestCase =:= a_crash_ends_the_attempt_with_an_exception_event;
    TestCase =:= a_propagator_that_misbehaves_fails_nothing
->
    #{propagator => shigoto_fake_propagator};
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
overrides(a_snoozed_job_gives_its_place_in_the_load_shedder_back) ->
    #{load_shedding => #{target => 60000, max_in_flight => 100}};
overrides(a_backlog_drains_without_waiting_for_the_poll_timer) ->
    #{poll_interval => 3000};
overrides(a_result_that_looks_like_a_frame_reaches_its_dependent) ->
    #{encryption_key => binary:copy(<<7>>, 32), encryption_write_format => v1};
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

a_declared_gate_is_not_skipped_without_seki(_Config) ->
    ok = telemetry:attach(
        ?MODULE, [shigoto, resilience, gate_failed], fun ?MODULE:forward/4, self()
    ),
    ok = application:stop(seki),
    Gated = enqueue(~"gated", #{worker => shigoto_gated_worker}),
    receive
        {telemetry, [shigoto, resilience, gate_failed], #{count := 1}, Meta} ->
            ?assertMatch(#{worker := shigoto_gated_worker, gate := setup}, Meta)
    after 2000 -> ct:fail(gate_failure_not_reported)
    end,
    ok = idle(~"gated", 500),
    %% Snoozed, which gives the attempt back and records no error.
    ?assertMatch(
        #{state := ~"available", attempt := 1, max_attempts := 4, errors := ~"[]"}, row(Gated)
    ),
    %% A worker that declares no gate has none to lose.
    Plain = enqueue(~"ungated"),
    instruct(performing(~"ungated"), {return, ok}),
    _ = await(Plain, ~"completed"),
    {ok, _} = application:ensure_all_started(seki),
    ok = due(Gated),
    instruct(performing(~"gated"), {return, ok}),
    ?assertMatch(#{attempt := 2}, await(Gated, ~"completed")).

a_snoozed_job_gives_its_place_in_the_load_shedder_back(_Config) ->
    %% The worker's bulkhead holds two; the third job is put back by it.
    Tags = [~"shed-one", ~"shed-two", ~"shed-three"],
    Ids = [enqueue(Tag, #{worker => shigoto_gated_worker}) || Tag <- Tags],
    Running = [performing_any(Tags), performing_any(Tags)],
    ok = wait_for(fun() ->
        [Row || Id <- Ids, #{state := ~"available", attempt := 1} = Row <- [row(Id)]] =/= []
    end),
    ?assertEqual(2, shed_in_flight()),
    %% A snooze the worker asks for ends its run as well.
    [First, Second] = Running,
    instruct(First, {return, {snooze, 60}}),
    instruct(Second, {return, ok}),
    ok = wait_for(fun() -> shed_in_flight() =:= 0 end).

shed_in_flight() ->
    maps:get(in_flight, seki_shed:status(shigoto_load_shedder)).

performing_any(Tags) ->
    receive
        {performing, Tag, Worker, _Args} ->
            ?assert(lists:member(Tag, Tags)),
            Worker
    after 5000 -> ct:fail({never_performed, Tags})
    end.

%%----------------------------------------------------------------------
%% Context
%%----------------------------------------------------------------------

a_job_runs_in_the_context_it_was_inserted_in(_Config) ->
    ok = spans_to_self(),
    Id = in_trace(~"trace-1", fun() -> enqueue(~"traced") end),
    ?assertEqual(#{~"traceparent" => ~"trace-1"}, stored_carrier(Id)),
    Worker = performing(~"traced"),
    ?assertEqual(~"trace-1", trace_seen_by(Worker, ~"traced")),
    instruct(Worker, {return, ok}),
    _ = await(Id, ~"completed"),
    Carrier = #{~"traceparent" => ~"trace-1"},
    ?assertMatch({#{system_time := _}, #{job_id := Id, carrier := Carrier}}, span(start)),
    ?assertMatch(
        {#{duration := _}, #{job_id := Id, carrier := Carrier, outcome := completed}}, span(stop)
    ),
    %% The test process was never attached to.
    ?assertEqual(undefined, shigoto_fake_propagator:trace()).

every_attempt_gets_the_same_context(_Config) ->
    ok = spans_to_self(),
    Id = in_trace(~"trace-retried", fun() -> enqueue(~"traced-retry") end),
    First = performing(~"traced-retry"),
    ?assertEqual(~"trace-retried", trace_seen_by(First, ~"traced-retry")),
    instruct(First, {return, {error, first_try}}),
    _ = await(Id, ~"retryable"),
    Second = performing(~"traced-retry"),
    ?assertEqual(~"trace-retried", trace_seen_by(Second, ~"traced-retry")),
    instruct(Second, {return, {snooze, 1}}),
    Third = performing(~"traced-retry"),
    ?assertEqual(~"trace-retried", trace_seen_by(Third, ~"traced-retry")),
    instruct(Third, {return, ok}),
    _ = await(Id, ~"completed"),
    ?assertMatch({_, #{attempt := 1}}, span(start)),
    ?assertMatch({_, #{attempt := 1, outcome := failed}}, span(stop)),
    ?assertMatch({_, #{outcome := snoozed}}, span(stop)),
    ?assertMatch({_, #{outcome := completed}}, span(stop)).

a_job_inserted_by_a_job_carries_on_from_it(_Config) ->
    Parent = in_trace(~"trace-parent", fun() -> enqueue(~"traced-parent") end),
    Worker = performing(~"traced-parent"),
    Me = list_to_binary(pid_to_list(self())),
    instruct(
        Worker,
        {insert, #{
            worker => shigoto_lifecycle_worker,
            args => #{~"test" => Me, ~"tag" => ~"traced-child"}
        }}
    ),
    Child =
        receive
            {inserted, ~"traced-parent", Id} -> Id
        after 5000 -> ct:fail(no_child_inserted)
        end,
    ?assertEqual(#{~"traceparent" => ~"trace-parent"}, stored_carrier(Child)),
    instruct(Worker, {return, ok}),
    _ = await(Parent, ~"completed"),
    ChildWorker = performing(~"traced-child"),
    ?assertEqual(~"trace-parent", trace_seen_by(ChildWorker, ~"traced-child")),
    instruct(ChildWorker, {return, ok}),
    _ = await(Child, ~"completed").

a_released_dependent_keeps_its_own_context(_Config) ->
    Parent = in_trace(~"trace-first", fun() -> enqueue(~"traced-first") end),
    Child = in_trace(
        ~"trace-second", fun() -> enqueue(~"traced-second", #{depends_on => [Parent]}) end
    ),
    instruct(performing(~"traced-first"), {return, {ok, #{~"rows" => 1}}}),
    {Worker, Args} = performing_with_args(~"traced-second"),
    ?assertEqual(#{Parent => #{~"rows" => 1}}, maps:get(deps_results, Args)),
    ?assertEqual(~"trace-second", trace_seen_by(Worker, ~"traced-second")),
    instruct(Worker, {return, ok}),
    _ = await(Child, ~"completed").

a_bulk_and_a_transactional_insert_carry_the_context(_Config) ->
    Me = list_to_binary(pid_to_list(self())),
    Params = fun(Tag) ->
        #{worker => shigoto_lifecycle_worker, args => #{~"test" => Me, ~"tag" => Tag}}
    end,
    {ok, Bulk} = in_trace(~"trace-bulk", fun() ->
        shigoto:insert_all([Params(~"bulk-1"), Params(~"bulk-2")])
    end),
    [
        ?assertEqual(#{~"traceparent" => ~"trace-bulk"}, stored_carrier(Id))
     || #{id := Id} <- Bulk
    ],
    {ok, #{id := InTxn}} = in_trace(~"trace-txn", fun() ->
        shigoto:transaction(fun() -> shigoto:insert(Params(~"txn")) end)
    end),
    ?assertEqual(#{~"traceparent" => ~"trace-txn"}, stored_carrier(InTxn)),
    %% A carrier the caller put there itself is kept.
    {ok, #{id := Own}} = in_trace(~"trace-ignored", fun() ->
        shigoto:insert(
            (Params(~"own"))#{
                meta => #{shigoto_propagator:key() => #{~"traceparent" => ~"trace-own"}}
            }
        )
    end),
    ?assertEqual(#{~"traceparent" => ~"trace-own"}, stored_carrier(Own)),
    ok = answer_all(4).

a_batch_callback_carries_on_from_the_job_that_finished_the_batch(_Config) ->
    BatchId = new_batch(),
    Id = in_trace(~"trace-batch", fun() -> enqueue(~"traced-batch", #{batch => BatchId}) end),
    instruct(performing(~"traced-batch"), {return, ok}),
    _ = await(Id, ~"completed"),
    receive
        {batch_callback, _Args} -> ok
    after 5000 -> ct:fail(no_batch_callback)
    end,
    #{rows := [#{id := Callback}]} = shigoto_db:query(
        ?POOL, ~"SELECT id FROM shigoto_jobs WHERE worker = 'shigoto_batch_callback_worker'", []
    ),
    ?assertEqual(#{~"traceparent" => ~"trace-batch"}, stored_carrier(Callback)).

a_cron_job_gets_what_the_scheduler_injects(_Config) ->
    Me = list_to_binary(pid_to_list(self())),
    application:set_env(shigoto, cron, [
        {~"traced-cron", ~"* * * * *", shigoto_lifecycle_worker, #{
            ~"test" => Me, ~"tag" => ~"traced-cron"
        }}
    ]),
    try
        %% The pass runs in this process: with a context, as the scheduler
        %% would have one if the propagator gave it one, and without.
        _ = in_trace(~"trace-cron", fun shigoto_cron:schedule_once/0),
        {Worker, _} = performing_with_args(~"traced-cron"),
        ?assertEqual(~"trace-cron", trace_seen_by(Worker, ~"traced-cron")),
        instruct(Worker, {return, ok}),
        #{rows := [#{id := Id}]} = shigoto_db:query(
            ?POOL, ~"SELECT id FROM shigoto_jobs WHERE worker = 'shigoto_lifecycle_worker'", []
        ),
        ?assertEqual(#{~"traceparent" => ~"trace-cron"}, stored_carrier(Id))
    after
        application:unset_env(shigoto, cron),
        shigoto_db:query(?POOL, ~"DELETE FROM shigoto_cron", [])
    end.

a_crash_ends_the_attempt_with_an_exception_event(_Config) ->
    ok = spans_to_self(),
    Id = in_trace(~"trace-crash", fun() -> enqueue(~"traced-crash", #{max_attempts => 1}) end),
    instruct(performing(~"traced-crash"), crash),
    _ = await(Id, ~"discarded"),
    Carrier = #{~"traceparent" => ~"trace-crash"},
    ?assertMatch({_, #{job_id := Id, carrier := Carrier}}, span(start)),
    ?assertMatch(
        {#{duration := _}, #{
            job_id := Id,
            carrier := Carrier,
            kind := error,
            reason := <<"error:deliberate_crash", _/binary>>
        }},
        span(exception)
    ).

a_propagator_that_misbehaves_fails_nothing(_Config) ->
    ok = spans_to_self(),
    Raised = in_trace(raise, fun() -> enqueue(~"inject-raises") end),
    ?assertEqual(#{}, stored_carrier(Raised)),
    Oversized = in_trace(oversized, fun() -> enqueue(~"inject-oversized") end),
    ?assertEqual(#{}, stored_carrier(Oversized)),
    Unattachable = in_trace(~"unattachable", fun() -> enqueue(~"attach-raises") end),
    ?assertEqual(#{~"traceparent" => ~"unattachable"}, stored_carrier(Unattachable)),
    ok = answer_all(3),
    [_ = await(Id, ~"completed") || Id <- [Raised, Oversized, Unattachable]],
    %% What a writer to the table put where a carrier goes is not attached.
    Me = list_to_binary(pid_to_list(self())),
    #{rows := [#{id := Forged}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, meta)
        VALUES ($1, 'shigoto_lifecycle_worker', $2::jsonb, $3::jsonb) RETURNING id
        """,
        [
            ?QUEUE,
            iolist_to_binary(json:encode(#{~"test" => Me, ~"tag" => ~"forged"})),
            ~"{\"_shigoto_carrier\": {\"traceparent\": 7}}"
        ]
    ),
    Worker = performing(~"forged"),
    ?assertEqual(undefined, trace_seen_by(Worker, ~"forged")),
    instruct(Worker, {return, ok}),
    _ = await(Forged, ~"completed").

without_a_propagator_nothing_is_carried(_Config) ->
    ok = spans_to_self(),
    Id = in_trace(~"trace-unused", fun() -> enqueue(~"untraced") end),
    ?assertEqual(#{}, stored_carrier(Id)),
    ?assertMatch(#{meta := ~"{}"}, row(Id)),
    Worker = performing(~"untraced"),
    ?assertEqual(undefined, trace_seen_by(Worker, ~"untraced")),
    instruct(Worker, {return, ok}),
    _ = await(Id, ~"completed"),
    ?assertMatch({_, #{job_id := Id, carrier := #{}}}, span(start)),
    ?assertMatch({_, #{job_id := Id, carrier := #{}, outcome := completed}}, span(stop)).

in_trace(Trace, Insert) ->
    _ = shigoto_fake_propagator:trace(Trace),
    try
        Insert()
    after
        shigoto_fake_propagator:clear()
    end.

stored_carrier(Id) ->
    shigoto_propagator:carrier(row(Id)).

trace_seen_by(Worker, Tag) ->
    instruct(Worker, report_trace),
    receive
        {trace, Tag, Trace} -> Trace
    after 5000 -> ct:fail({no_trace_reported, Tag})
    end.

spans_to_self() ->
    telemetry:attach_many(
        ?MODULE,
        [[shigoto, job, start], [shigoto, job, stop], [shigoto, job, exception]],
        fun ?MODULE:span_event/4,
        self()
    ).

span_event([shigoto, job, Edge], Measurements, Metadata, Owner) when is_pid(Owner) ->
    Owner ! {span, Edge, Measurements, Metadata},
    ok.

span(Edge) ->
    receive
        {span, Edge, Measurements, Metadata} -> {Measurements, Metadata}
    after 5000 -> ct:fail({no_span_event, Edge})
    end.

%%----------------------------------------------------------------------
%% Waking up
%%----------------------------------------------------------------------

a_backlog_drains_without_waiting_for_the_poll_timer(_Config) ->
    %% Three times what the queue runs at once, polling alone, every three
    %% seconds. One claim per tick would take three ticks; a queue that
    %% claims again when a job finishes is done soon after the first.
    ?assertEqual(undefined, whereis(shigoto_notifier)),
    Tags = [iolist_to_binary([~"backlog-", integer_to_binary(N)]) || N <- lists:seq(1, 15)],
    Started = erlang:monotonic_time(millisecond),
    Ids = [enqueue(Tag) || Tag <- Tags],
    ok = answer_all(length(Tags)),
    [?assertMatch(#{attempt := 1}, await(Id, ~"completed")) || Id <- Ids],
    Took = erlang:monotonic_time(millisecond) - Started,
    ?assert(Took < 5500, Took).

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

cancelling_a_finished_job_reports_nothing(_Config) ->
    Done = enqueue(~"finished"),
    instruct(performing(~"finished"), {return, ok}),
    _ = await(Done, ~"completed"),
    Waiting = enqueue(~"cancel-reported", #{scheduled_at => seconds_from_now(3600)}),
    ok = telemetry:attach(?MODULE, [shigoto, job, cancelled], fun ?MODULE:forward/4, self()),
    ?assertEqual(ok, shigoto:cancel(Done)),
    ?assertEqual(ok, shigoto:cancel(Done + 1000000)),
    receive
        {telemetry, [shigoto, job, cancelled], _, Unexpected} ->
            ct:fail({cancel_reported, Unexpected})
    after 300 -> ok
    end,
    ?assertMatch(#{state := ~"completed"}, row(Done)),
    ?assertEqual(ok, shigoto:cancel(Waiting)),
    receive
        {telemetry, [shigoto, job, cancelled], #{count := 1}, Meta} ->
            ?assertMatch(
                #{job_id := Waiting, worker := ~"shigoto_lifecycle_worker", queue := ?QUEUE}, Meta
            )
    after 2000 -> ct:fail(cancel_not_reported)
    end.

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
        [#{~"error" := ~"{unknown_worker,<<\"shigoto_no_such_worker_module\">>}"}], errors(Failed)
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
    ?assertMatch([#{~"error" := ~"{unknown_worker,<<\"lists\">>}"}], errors(Row)),
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

a_retried_job_does_not_finish_its_batch_early(_Config) ->
    BatchId = new_batch(),
    Retried = enqueue(~"batch-retried", #{batch => BatchId, max_attempts => 1}),
    Other = enqueue(~"batch-other", #{batch => BatchId}),
    Last = enqueue(~"batch-last", #{batch => BatchId}),
    RetriedWorker = performing(~"batch-retried"),
    OtherWorker = performing(~"batch-other"),
    LastWorker = performing(~"batch-last"),
    instruct(RetriedWorker, {return, {error, gone}}),
    _ = await(Retried, ~"discarded"),
    ?assertMatch({ok, #{discarded_jobs := 1}}, shigoto:get_batch(BatchId)),
    ok = shigoto:retry(Retried),
    ?assertMatch({ok, #{discarded_jobs := 0}}, shigoto:get_batch(BatchId)),
    instruct(performing(~"batch-retried"), {return, ok}),
    _ = await(Retried, ~"completed"),
    instruct(OtherWorker, {return, ok}),
    _ = await(Other, ~"completed"),
    receive
        {batch_callback, _} -> ct:fail(callback_with_a_job_still_running)
    after 400 -> ok
    end,
    instruct(LastWorker, {return, ok}),
    _ = await(Last, ~"completed"),
    receive
        {batch_callback, Args} -> ?assertNot(maps:is_key(~"_batch_event", Args))
    after 5000 -> ct:fail(no_batch_callback)
    end,
    ?assertMatch(
        {ok, #{total_jobs := 3, completed_jobs := 3, discarded_jobs := 0}},
        shigoto:get_batch(BatchId)
    ).

a_batch_left_unsettled_is_settled_by_the_sweep(_Config) ->
    BatchId = new_batch(),
    Id = enqueue(~"unsettled", #{batch => BatchId, scheduled_at => seconds_from_now(3600)}),
    %% What a node leaves that stopped right after its job's last statement:
    %% the job completed and counted, the batch not yet settled.
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET state = 'completed', completed_at = now() WHERE id = $1", [
            Id
        ]
    ),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_batches SET completed_jobs = 1 WHERE id = $1", [BatchId]
    ),
    receive
        {batch_callback, Args} -> ?assertNot(maps:is_key(~"_batch_event", Args))
    after 5000 -> ct:fail(no_batch_callback)
    end,
    ?assertMatch({ok, #{state := ~"callback_completing"}}, shigoto:get_batch(BatchId)),
    %% Once.
    receive
        {batch_callback, _} -> ct:fail(second_batch_callback)
    after 600 -> ok
    end.

a_job_waiting_on_an_ended_job_is_released_by_the_sweep(_Config) ->
    Parent = enqueue(~"raced-parent"),
    instruct(performing(~"raced-parent"), {return, {ok, #{~"rows" => 3}}}),
    _ = await(Parent, ~"completed"),
    Failed = enqueue(~"raced-failed", #{max_attempts => 1}),
    instruct(performing(~"raced-failed"), {return, {error, gone}}),
    _ = await(Failed, ~"discarded"),
    Missing = Failed + 1000000,
    %% What an insert that raced its dependency's last statement leaves: a job
    %% waiting on one that has already ended. The last waits on no job at all.
    Runs = waiting_on(~"raced-child", [Parent], null),
    Cancels = waiting_on(~"raced-cancelled", [Failed], ~"cancel"),
    Released = waiting_on(~"raced-released", [Failed], ~"run"),
    Orphan = waiting_on(~"raced-orphan", [Missing], null),
    {RunsWorker, RunsArgs} = performing_with_args(~"raced-child"),
    ?assertEqual(#{Parent => #{~"rows" => 3}}, maps:get(deps_results, RunsArgs)),
    {ReleasedWorker, ReleasedArgs} = performing_with_args(~"raced-released"),
    ?assertEqual(#{Failed => null}, maps:get(deps_results, ReleasedArgs)),
    {OrphanWorker, OrphanArgs} = performing_with_args(~"raced-orphan"),
    ?assertEqual(#{Missing => null}, maps:get(deps_results, OrphanArgs)),
    [instruct(Worker, {return, ok}) || Worker <- [RunsWorker, ReleasedWorker, OrphanWorker]],
    [_ = await(Id, ~"completed") || Id <- [Runs, Released, Orphan]],
    ?assertMatch(#{attempt := 0}, await(Cancels, ~"cancelled")),
    ok = idle(~"raced-cancelled", 300).

waiting_on(Tag, DependsOn, Policy) ->
    Args = iolist_to_binary(
        json:encode(#{~"test" => list_to_binary(pid_to_list(self())), ~"tag" => Tag})
    ),
    #{rows := [#{id := Id}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, depends_on, on_dependency_failure)
        VALUES ($1, 'shigoto_lifecycle_worker', $2::jsonb, $3, $4) RETURNING id
        """,
        [?QUEUE, Args, DependsOn, Policy]
    ),
    Id.

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

a_result_that_looks_like_a_frame_reaches_its_dependent(_Config) ->
    Parent = enqueue(~"framelike-parent"),
    Child = enqueue(~"framelike-child", #{depends_on => [Parent]}),
    instruct(performing(~"framelike-parent"), {return, {ok, ~"enc:hello"}}),
    {ChildWorker, Args} = performing_with_args(~"framelike-child"),
    ?assertEqual(#{Parent => ~"enc:hello"}, maps:get(deps_results, Args)),
    instruct(ChildWorker, {return, {ok, ~"enc:v2:world"}}),
    _ = await(Child, ~"completed"),
    {ok, #{result := ParentResult}} = shigoto:get_job(Parent),
    {ok, #{result := ChildResult}} = shigoto:get_job(Child),
    ?assertEqual(~"enc:hello", json:decode(ParentResult)),
    ?assertEqual(~"enc:v2:world", json:decode(ChildResult)).

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
    Params = maps:merge(
        #{
            worker => shigoto_lifecycle_worker,
            args => #{~"test" => list_to_binary(pid_to_list(self())), ~"tag" => Tag}
        },
        Extra
    ),
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
        State when is_tuple(State) -> element(2, State) =/= undefined
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
