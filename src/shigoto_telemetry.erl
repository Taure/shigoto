-module(shigoto_telemetry).
-moduledoc """
Telemetry events for Shigoto job lifecycle, queue operations, and resilience.

## Job Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, job, inserted]` | `count` | job_id, worker, queue, priority |
| `[shigoto, job, claimed]` | `count, queue_wait_ms` | job_id, worker, queue |
| `[shigoto, job, completed]` | `count, duration, queue_wait_ms` | job_id, worker, queue, attempt |
| `[shigoto, job, failed]` | `count, duration, queue_wait_ms` | job_id, worker, queue, attempt, reason |
| `[shigoto, job, snoozed]` | `count` | job_id, worker, queue, snooze_reason |
| `[shigoto, job, discarded]` | `count` | job_id, worker, queue, attempt |
| `[shigoto, job, cancelled]` | `count` | job_id, worker, queue |
| `[shigoto, job, progress]` | `progress` | job_id, worker, queue |

## Queue Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, queue, poll]` | `count, claimed` | queue |
| `[shigoto, queue, paused]` | `count` | queue |
| `[shigoto, queue, resumed]` | `count` | queue |

## Resilience Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, resilience, rate_limited]` | `count, retry_after_ms` | worker |
| `[shigoto, resilience, circuit_open]` | `count` | worker |
| `[shigoto, resilience, bulkhead_full]` | `count` | worker |
| `[shigoto, resilience, load_shed]` | `count` | priority |

## Batch Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, batch, completed]` | `count` | batch_id, total_jobs, completed_jobs, discarded_jobs |

## Cron Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, cron, scheduled]` | `count` | name, worker, schedule |
""".

-export([
    %% Job events
    job_inserted/1,
    job_claimed/1,
    job_completed/2,
    job_failed/3,
    job_snoozed/2,
    job_discarded/1,
    job_cancelled/1,
    job_progress/2,
    %% Queue events
    queue_poll/2,
    queue_paused/1,
    queue_resumed/1,
    %% Resilience events
    resilience_rate_limited/2,
    resilience_circuit_open/1,
    resilience_bulkhead_full/1,
    resilience_load_shed/1,
    %% Batch events
    batch_completed/1,
    %% Cron events
    cron_scheduled/3
]).

%%----------------------------------------------------------------------
%% Job events
%%----------------------------------------------------------------------

-spec job_inserted(map()) -> ok.
job_inserted(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, inserted], #{count => 1}, Meta),
    logger:info(~"job inserted", Meta).

-spec job_claimed(map()) -> ok.
job_claimed(Job) ->
    QueueWait = queue_wait_ms(Job),
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, claimed], #{count => 1, queue_wait_ms => QueueWait}, Meta).

-spec job_completed(map(), integer()) -> ok.
job_completed(Job, Duration) ->
    QueueWait = queue_wait_ms(Job),
    DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
    Meta = job_meta(Job),
    telemetry:execute(
        [shigoto, job, completed],
        #{count => 1, duration => Duration, duration_ms => DurationMs, queue_wait_ms => QueueWait},
        Meta
    ),
    logger:info(~"job completed", Meta#{duration_ms => DurationMs}).

-spec job_failed(map(), term(), integer()) -> ok.
job_failed(Job, Reason, Duration) ->
    QueueWait = queue_wait_ms(Job),
    DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
    Meta = (job_meta(Job))#{reason => format_reason(Reason)},
    telemetry:execute(
        [shigoto, job, failed],
        #{count => 1, duration => Duration, duration_ms => DurationMs, queue_wait_ms => QueueWait},
        Meta
    ),
    logger:warning(~"job failed", Meta#{duration_ms => DurationMs}).

-spec job_snoozed(map(), binary()) -> ok.
job_snoozed(Job, Reason) ->
    Meta = (job_meta(Job))#{snooze_reason => Reason},
    telemetry:execute([shigoto, job, snoozed], #{count => 1}, Meta),
    logger:info(~"job snoozed", Meta).

-spec job_discarded(map()) -> ok.
job_discarded(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, discarded], #{count => 1}, Meta),
    logger:warning(~"job discarded", Meta).

-spec job_cancelled(map()) -> ok.
job_cancelled(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, cancelled], #{count => 1}, Meta),
    logger:info(~"job cancelled", Meta).

-spec job_progress(map(), 0..100) -> ok.
job_progress(Job, Progress) ->
    Meta = (job_meta(Job))#{progress => Progress},
    telemetry:execute([shigoto, job, progress], #{progress => Progress}, Meta).

%%----------------------------------------------------------------------
%% Queue events
%%----------------------------------------------------------------------

-spec queue_poll(binary(), non_neg_integer()) -> ok.
queue_poll(Queue, Claimed) ->
    telemetry:execute(
        [shigoto, queue, poll],
        #{count => 1, claimed => Claimed},
        #{queue => Queue, domain => [shigoto]}
    ).

-spec queue_paused(binary()) -> ok.
queue_paused(Queue) ->
    telemetry:execute([shigoto, queue, paused], #{count => 1}, #{
        queue => Queue, domain => [shigoto]
    }),
    logger:notice(~"queue paused", #{queue => Queue}).

-spec queue_resumed(binary()) -> ok.
queue_resumed(Queue) ->
    telemetry:execute([shigoto, queue, resumed], #{count => 1}, #{
        queue => Queue, domain => [shigoto]
    }),
    logger:notice(~"queue resumed", #{queue => Queue}).

%%----------------------------------------------------------------------
%% Resilience events
%%----------------------------------------------------------------------

-spec resilience_rate_limited(module(), non_neg_integer()) -> ok.
resilience_rate_limited(Worker, RetryAfterMs) ->
    telemetry:execute(
        [shigoto, resilience, rate_limited],
        #{count => 1, retry_after_ms => RetryAfterMs},
        #{worker => Worker, domain => [shigoto]}
    ).

-spec resilience_circuit_open(module()) -> ok.
resilience_circuit_open(Worker) ->
    telemetry:execute(
        [shigoto, resilience, circuit_open],
        #{count => 1},
        #{worker => Worker, domain => [shigoto]}
    ).

-spec resilience_bulkhead_full(module()) -> ok.
resilience_bulkhead_full(Worker) ->
    telemetry:execute(
        [shigoto, resilience, bulkhead_full],
        #{count => 1},
        #{worker => Worker, domain => [shigoto]}
    ).

-spec resilience_load_shed(integer()) -> ok.
resilience_load_shed(Priority) ->
    telemetry:execute(
        [shigoto, resilience, load_shed],
        #{count => 1},
        #{priority => Priority, domain => [shigoto]}
    ).

%%----------------------------------------------------------------------
%% Batch events
%%----------------------------------------------------------------------

-spec batch_completed(map()) -> ok.
batch_completed(Batch) ->
    Meta = #{
        batch_id => maps:get(id, Batch, undefined),
        total_jobs => maps:get(total_jobs, Batch, 0),
        completed_jobs => maps:get(completed_jobs, Batch, 0),
        discarded_jobs => maps:get(discarded_jobs, Batch, 0),
        domain => [shigoto]
    },
    telemetry:execute([shigoto, batch, completed], #{count => 1}, Meta),
    logger:info(~"batch completed", Meta).

%%----------------------------------------------------------------------
%% Cron events
%%----------------------------------------------------------------------

-spec cron_scheduled(atom() | binary(), module(), binary()) -> ok.
cron_scheduled(Name, Worker, Schedule) ->
    Meta = #{name => Name, worker => Worker, schedule => Schedule, domain => [shigoto]},
    telemetry:execute([shigoto, cron, scheduled], #{count => 1}, Meta),
    logger:info(~"cron job scheduled", Meta).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

job_meta(Job) ->
    #{
        job_id => maps:get(id, Job, undefined),
        worker => maps:get(worker, Job, undefined),
        queue => maps:get(queue, Job, undefined),
        attempt => maps:get(attempt, Job, 0),
        priority => maps:get(priority, Job, 0),
        domain => [shigoto]
    }.

queue_wait_ms(Job) ->
    case {maps:get(scheduled_at, Job, undefined), maps:get(attempted_at, Job, undefined)} of
        {undefined, _} ->
            0;
        {_, undefined} ->
            0;
        {Scheduled, Attempted} ->
            try
                S = calendar:datetime_to_gregorian_seconds(to_datetime(Scheduled)),
                A = calendar:datetime_to_gregorian_seconds(to_datetime(Attempted)),
                max(0, (A - S) * 1000)
            catch
                _:_ -> 0
            end
    end.

to_datetime({{Y, Mo, D}, {H, Mi, S}}) when is_float(S) -> {{Y, Mo, D}, {H, Mi, trunc(S)}};
to_datetime({{_, _, _}, {_, _, _}} = DT) -> DT;
to_datetime(_) -> {{1970, 1, 1}, {0, 0, 0}}.

format_reason(Reason) ->
    iolist_to_binary(io_lib:format(~"~0p", [Reason])).
