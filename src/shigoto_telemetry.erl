-module(shigoto_telemetry).
-moduledoc """
Telemetry events for Shigoto job lifecycle, queue operations, and resilience.

Every event is emitted through `telemetry:execute/3`. The tables below are the
stable event contract: attach a handler to any of these event names to feed a
metrics reporter (`telemetry_metrics`, Prometheus, StatsD, ...). See the
[Telemetry](telemetry.md) guide for a worked `telemetry_metrics` example.

Measurement units:

- `count` is always `1` (increment a counter/sum).
- `duration` is in **native** time units (`erlang:monotonic_time/0` deltas).
- `duration_ms`, `queue_wait_ms`, `retry_after_ms` are **milliseconds**.
- `progress` is a **percentage** (`0..100`).
- `claimed` is a **job count** (jobs claimed by that poll).

Every event carries `domain => [shigoto]` in its metadata (used by the OTP
logger for filtering); it is omitted from the tables below for brevity.

No event carries a job's `args`, `meta`, `result` or `deps_results`, apart from
the carrier a propagator put in `meta` (`start`, `stop`, `exception`). The
`reason` of `[shigoto, job, failed]` is text written by `shigoto_error:text/1`:
at most 1024 bytes, and with an encryption key configured only the shape
of the failure, with every value that is not an atom replaced by `'_'`.

## Job Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, job, inserted]` | `count` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, claimed]` | `count, queue_wait_ms` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, start]` | `system_time, monotonic_time` | job_id, worker, queue, attempt, priority, carrier |
| `[shigoto, job, stop]` | `duration, monotonic_time` | job_id, worker, queue, attempt, priority, carrier, outcome |
| `[shigoto, job, exception]` | `duration, monotonic_time` | job_id, worker, queue, attempt, priority, carrier, kind, reason |
| `[shigoto, job, completed]` | `count, duration, duration_ms, queue_wait_ms` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, failed]` | `count, duration, duration_ms, queue_wait_ms` | job_id, worker, queue, attempt, priority, reason |
| `[shigoto, job, snoozed]` | `count` | job_id, worker, queue, attempt, priority, snooze_reason |
| `[shigoto, job, discarded]` | `count` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, cancelled]` | `count` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, progress]` | `progress` | job_id, worker, queue, attempt, priority, progress |
| `[shigoto, job, lost]` | `count` | job_id, worker, queue, attempt, priority, transition |
| `[shigoto, job, transition_failed]` | `count` | job_id, worker, queue, attempt, priority, transition, reason |
| `[shigoto, job, rescued]` | `count` | job_id, worker, queue, attempt, priority |

`start`, `stop` and `exception` bracket one attempt, in the shape
`telemetry:span/3` gives: `start` before the gates and `perform/1`, then
exactly one of `stop` (`outcome`: `completed`, `failed` for an `{error, _}`
answer, `snoozed`, or `stopped`) or `exception` (`kind` is `error`, `exit` or
`throw`; `reason` is text as for `failed`). They fire before the outcome is
written, so `completed`, `failed` or `snoozed` still follows, or `lost`.
`carrier` is the job's context as `m:shigoto_propagator` stored it at insert,
`#{}` without one. A job that cannot be run (unknown worker, a column that does
not open) has no `start`.

`lost` fires when a run's claim no longer held: the job had been rescued and
claimed again, or cancelled on another node, while this run was going. Either
the run finished and its outcome (`transition`: `completed`, `failed` or
`snoozed`) was not written, or the heartbeat noticed first and the run was
stopped (`transition`: `stopped`), or the node was stopping and the claim it
tried to give back was no longer its own (`transition`: `released`). No `completed`, `failed` or `snoozed` event
fires for that run. A steady rate of it
means jobs outlive the stale threshold (`heartbeat_interval * 2`) without a
heartbeat.

`rescued` fires when the stale-job sweep takes a job from an owner that stopped
heartbeating. `attempt` is the attempt that was lost. The job runs again, or is
discarded when that was its last attempt (a `discarded` event follows).

`transition_failed` fires when writing the outcome failed for any other reason
(`reason` is the database error, cut down by `shigoto_db:reduced/1`). The row
stays `executing` and the stale-job rescue returns it to the queue, so the job
runs again.

A run stopped because its node is stopping ends with `[shigoto, job, stop]`
and `outcome` `stopped`, and its claim is given back: the job is `available`
again and no attempt is used. `transition` is `released` in `lost` and
`transition_failed` when that write did not go through.

## Queue Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, queue, poll]` | `count, claimed` | queue |
| `[shigoto, queue, paused]` | `count` | queue |
| `[shigoto, queue, resumed]` | `count` | queue |
| `[shigoto, queue, start_failed]` | `count` | queue, reason |

`start_failed` fires when `m:shigoto_migrator` starts the configured queues
after a late migration and one of them fails to start (it is also logged as
`shigoto_queue_start_failed`). The other queues still start.

## Resilience Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, resilience, rate_limited]` | `count, retry_after_ms` | worker |
| `[shigoto, resilience, circuit_open]` | `count` | worker |
| `[shigoto, resilience, bulkhead_full]` | `count` | worker |
| `[shigoto, resilience, load_shed]` | `count` | priority |
| `[shigoto, resilience, gate_failed]` | `count` | worker, gate, reason |

`gate_failed` fires when a gate could not be checked: its seki primitive is
missing, a worker callback raised, the database refused the global concurrency
count, or the advisory lock for it was not free within
`advisory_lock_timeout` (`reason` is `lock_timeout`). `gate` is `rate_limit`,
`bulkhead`, `circuit`, `global_concurrency`, `load` or `setup`. The job is
snoozed, not run: a gate that cannot answer does not admit.

## Batch Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, batch, completed]` | `count` | batch_id, total_jobs, completed_jobs, discarded_jobs |

## Cron Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, cron, scheduled]` | `count` | name, worker, schedule |
| `[shigoto, cron, skipped]` | `count` | name, worker, reason |

`skipped` fires each pass for an entry that cannot be scheduled: its schedule
does not parse, its args do not encode as JSON, or its worker's `queue/0`,
`priority/0` or `max_attempts/0` answers a value the jobs table cannot hold.
The matching `shigoto_cron_entry_skipped` warning is logged only once per entry
and reason on each node, so alert on this event rather than on the log.

## Leader Lock Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, leader_lock, unavailable]` | `count, consecutive_misses` | lock |

Emitted with the `shigoto_cron_lock_held_elsewhere`,
`shigoto_stager_lock_held_elsewhere` and `shigoto_rescuer_lock_held_elsewhere`
warnings: `lock` (`cron`, `stager` or `rescuer`) has been taken by something
other than a pass of this node for `consecutive_misses` passes in a row.

## Migration Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, migration, pending]` | `count` | reason |

Emitted with the `shigoto_migration_pending` error, when boot could not bring
the schema up to date and the queues are held back (see `m:shigoto_migrator`),
and on each failed background retry.

## Testing Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, testing, mode_armed]` | `count` | mode |

Emitted once at boot when a non-production `testing` mode (`inline`/`manual`) is
armed. Its presence in a production metrics stream is a red flag — test-only
insert behaviour is active. See `shigoto_config:testing_mode/0`.
""".

-export([
    %% Job events
    job_inserted/1,
    job_claimed/1,
    job_start/2,
    job_stop/4,
    job_exception/4,
    job_completed/2,
    job_failed/3,
    job_snoozed/2,
    job_discarded/1,
    job_cancelled/1,
    job_progress/2,
    job_lost/2,
    job_transition_failed/3,
    job_rescued/1,
    %% Queue events
    queue_poll/2,
    queue_paused/1,
    queue_resumed/1,
    queue_start_failed/2,
    %% Resilience events
    resilience_rate_limited/2,
    resilience_circuit_open/1,
    resilience_bulkhead_full/1,
    resilience_load_shed/1,
    resilience_gate_failed/3,
    %% Batch events
    batch_completed/1,
    %% Cron events
    cron_scheduled/3,
    cron_entry_skipped/3,
    %% Leader lock events
    leader_lock_unavailable/2,
    %% Migration events
    migration_pending/1,
    %% Testing events
    testing_mode_armed/1
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

-spec job_start(map(), shigoto_propagator:carrier()) -> ok.
job_start(Job, Carrier) ->
    telemetry:execute(
        [shigoto, job, start],
        #{system_time => erlang:system_time(), monotonic_time => erlang:monotonic_time()},
        (job_meta(Job))#{carrier => Carrier}
    ).

-spec job_stop(
    map(), shigoto_propagator:carrier(), integer(), completed | failed | snoozed | stopped
) ->
    ok.
job_stop(Job, Carrier, Duration, Outcome) ->
    telemetry:execute(
        [shigoto, job, stop],
        #{duration => Duration, monotonic_time => erlang:monotonic_time()},
        (job_meta(Job))#{carrier => Carrier, outcome => Outcome}
    ).

-spec job_exception(map(), shigoto_propagator:carrier(), integer(), {atom(), term()}) -> ok.
job_exception(Job, Carrier, Duration, {Class, Reason}) ->
    telemetry:execute(
        [shigoto, job, exception],
        #{duration => Duration, monotonic_time => erlang:monotonic_time()},
        (job_meta(Job))#{
            carrier => Carrier, kind => Class, reason => shigoto_error:text({Class, Reason})
        }
    ).

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
    Meta = (job_meta(Job))#{reason => shigoto_error:text(Reason)},
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

-spec job_lost(map(), completed | failed | snoozed | released | stopped) -> ok.
job_lost(Job, Transition) ->
    Meta = (job_meta(Job))#{transition => Transition},
    telemetry:execute([shigoto, job, lost], #{count => 1}, Meta).

-spec job_rescued(map()) -> ok.
job_rescued(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, rescued], #{count => 1}, Meta),
    logger:warning(~"job rescued", Meta).

-spec job_transition_failed(map(), completed | failed | snoozed | released, term()) -> ok.
job_transition_failed(Job, Transition, Reason) ->
    Meta = (job_meta(Job))#{transition => Transition, reason => Reason},
    telemetry:execute([shigoto, job, transition_failed], #{count => 1}, Meta).

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

-spec resilience_gate_failed(module(), atom(), term()) -> ok.
resilience_gate_failed(Worker, Gate, Reason) ->
    telemetry:execute(
        [shigoto, resilience, gate_failed],
        #{count => 1},
        #{worker => Worker, gate => Gate, reason => Reason, domain => [shigoto]}
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

-spec leader_lock_unavailable(cron | stager | rescuer, pos_integer()) -> ok.
leader_lock_unavailable(Lock, Misses) ->
    telemetry:execute(
        [shigoto, leader_lock, unavailable],
        #{count => 1, consecutive_misses => Misses},
        #{lock => Lock, domain => [shigoto]}
    ).

-spec queue_start_failed(binary(), term()) -> ok.
queue_start_failed(Queue, Reason) ->
    telemetry:execute(
        [shigoto, queue, start_failed],
        #{count => 1},
        #{queue => Queue, reason => Reason, domain => [shigoto]}
    ).

-spec migration_pending(term()) -> ok.
migration_pending(Reason) ->
    telemetry:execute(
        [shigoto, migration, pending], #{count => 1}, #{reason => Reason, domain => [shigoto]}
    ).

-spec cron_entry_skipped(binary(), term(), term()) -> ok.
cron_entry_skipped(Name, Worker, Reason) ->
    telemetry:execute(
        [shigoto, cron, skipped],
        #{count => 1},
        #{name => Name, worker => Worker, reason => Reason, domain => [shigoto]}
    ).

-spec cron_scheduled(atom() | binary(), module(), binary()) -> ok.
cron_scheduled(Name, Worker, Schedule) ->
    Meta = #{name => Name, worker => Worker, schedule => Schedule, domain => [shigoto]},
    telemetry:execute([shigoto, cron, scheduled], #{count => 1}, Meta),
    logger:info(~"cron job scheduled", Meta).

%%----------------------------------------------------------------------
%% Testing events
%%----------------------------------------------------------------------

-spec testing_mode_armed(inline | manual) -> ok.
testing_mode_armed(Mode) ->
    telemetry:execute(
        [shigoto, testing, mode_armed], #{count => 1}, #{mode => Mode, domain => [shigoto]}
    ).

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
