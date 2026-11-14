# Telemetry

Shigoto emits [telemetry](https://github.com/beam-telemetry/telemetry) events
across the job lifecycle, queue operations, resilience decisions, batches, and
cron scheduling. Every event is a stable contract: attach a handler to any event
name below and forward the measurements to a metrics reporter
(`telemetry_metrics`, Prometheus, StatsD, ...) or your logging pipeline.

All events are emitted via `telemetry:execute/3` from `shigoto_telemetry`.

## Event Reference

Measurement units:

- `count` is always `1` (increment a counter/sum).
- `duration` is in **native** time units (`erlang:monotonic_time/0` deltas).
- `duration_ms`, `queue_wait_ms`, `retry_after_ms` are **milliseconds**.
- `progress` is a **percentage** (`0..100`).
- `claimed` is a **job count** (jobs claimed by that poll).

Every event also carries `domain => [shigoto]` in its metadata (used by the OTP
logger for filtering); it is omitted from the tables below for brevity.

### Job Events

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

`start`, `stop` and `exception` bracket one attempt, as `telemetry:span/3`
would: `start`, then exactly one of `stop` (`outcome`: `completed`, `failed`,
`snoozed` or `stopped`) or `exception` (`kind`, `reason`). They fire before
the outcome is written, so `completed`, `failed` or `snoozed` still follows.
`carrier` is the job's context, see
[Context Propagation](context-propagation.md).

`lost` fires when a run's claim no longer held: the job had been rescued and
claimed again, or cancelled on another node, while this run was going. Either
the run finished and its outcome (`transition`: `completed`, `failed` or
`snoozed`) was not written, or the heartbeat noticed first and the run was
stopped (`transition`: `stopped`), or the node was stopping and the claim it
tried to give back was no longer its own (`transition`: `released`). No `completed`, `failed` or `snoozed` event
fires for that run. It comes with a
`shigoto_job_transition_lost` warning. A steady rate of it means jobs outlive
the stale threshold (`heartbeat_interval * 2`) without a heartbeat, and each of
them ran twice.

`rescued` fires when the stale-job sweep takes a job from an owner that stopped
heartbeating. `attempt` is the attempt that was lost. The job runs again, or is
discarded when that was its last attempt (a `discarded` event follows).

`transition_failed` fires when writing the outcome failed for any other reason
(`reason` is the database error). It comes with a `shigoto_job_transition_failed`
error log. The row stays `executing` until the stale-job rescue returns it to
the queue, so the job runs again.

A run stopped because its node is stopping ends with `[shigoto, job, stop]`
and `outcome` `stopped`, and its claim is given back: the job is `available`
again and no attempt is used. `transition` is `released` in `lost` and
`transition_failed` when that write did not go through.

The `reason` of `failed` is text. With an encryption key configured it is the
shape of the failure with every value removed, as in the `errors` column (see
[Security](security.md#what-is-recorded-about-a-failure)); it is at most 1024
bytes either way.

### Queue Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, queue, poll]` | `count, claimed` | queue |
| `[shigoto, queue, paused]` | `count` | queue |
| `[shigoto, queue, resumed]` | `count` | queue |
| `[shigoto, queue, start_failed]` | `count` | queue, reason |

`start_failed` fires when `shigoto_migrator` starts the configured queues after
a late migration and one of them fails to start. It comes with a
`shigoto_queue_start_failed` error log; the other queues still start. On a
normal boot a bad queue config fails the application start instead.

### Resilience Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, resilience, rate_limited]` | `count, retry_after_ms` | worker |
| `[shigoto, resilience, circuit_open]` | `count` | worker |
| `[shigoto, resilience, bulkhead_full]` | `count` | worker |
| `[shigoto, resilience, load_shed]` | `count` | priority |
| `[shigoto, resilience, gate_failed]` | `count` | worker, gate, reason |

`gate_failed` fires when a check could not be made: `gate` is `setup`, `load`,
`rate_limit`, `global_concurrency`, `bulkhead` or `circuit`. The job is snoozed
for 5 seconds rather than run unchecked, and `shigoto_resilience_gate_failed`
is logged. For `global_concurrency` the usual reason is `lock_timeout`: another
session holds the worker's advisory lock.

### Batch Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, batch, completed]` | `count` | batch_id, total_jobs, completed_jobs, discarded_jobs |

### Cron Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, cron, scheduled]` | `count` | name, worker, schedule |
| `[shigoto, cron, skipped]` | `count` | name, worker, reason |

`skipped` fires on every pass for an entry that cannot be scheduled: its
schedule does not parse, its args do not encode as JSON, its worker's defaults
do not fit the jobs table, or the entry is malformed (`malformed_entry`). The
matching `shigoto_cron_entry_skipped` warning is logged only once per entry and
reason on each node, so alert on this event rather than on the log (see the
[Cron](cron.md) guide).

### Leader Lock Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, leader_lock, unavailable]` | `count, consecutive_misses` | lock |

Emitted with the `shigoto_cron_lock_held_elsewhere` and
`shigoto_stager_lock_held_elsewhere` warnings, when `lock` (`cron` or
`stager`) has been taken by something other than a shigoto pass for
`consecutive_misses` passes in a row. See "Advisory locks" in the
[Cron](cron.md) guide.

### Migration Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, migration, pending]` | `count` | reason |

Emitted with the `shigoto_migration_pending` error when boot could not bring the
schema up to date and the queues are held back, and again on each failed
background retry (every 30 seconds, or on `shigoto_migrator:retry_now/0`).
While it keeps firing no job is processed on that node; alert on it. See "Run
the Migration" in the [Getting Started](getting-started.md) guide.

### Testing Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, testing, mode_armed]` | `count` | mode |

Emitted once at boot when a non-production `testing` mode (`inline`/`manual`) is
armed. Treat its presence in a production metrics stream as a red flag: inserts
are not persisting. See `shigoto_config:testing_mode/0`.

## Attaching a Raw Handler

The lowest-level integration is a plain `telemetry` handler:

```erlang
telemetry:attach_many(
    ~"shigoto-logger",
    [
        [shigoto, job, completed],
        [shigoto, job, failed]
    ],
    fun(Event, Measurements, Metadata, _Config) ->
        logger:info(~"shigoto event", #{
            event => Event,
            measurements => Measurements,
            metadata => Metadata
        })
    end,
    undefined
).
```

## Turning Events into Metrics

The example below wires the events into
[`telemetry_metrics`](https://hexdocs.pm/telemetry_metrics/) definitions. It is
illustration only; `telemetry_metrics` is **not** a dependency of Shigoto, so add
it to your own application if you want it.

```erlang
metrics() ->
    [
        %% Counters (each event carries count => 1)
        telemetry_metrics:counter(~"shigoto.job.completed.count"),
        telemetry_metrics:counter(~"shigoto.job.failed.count"),
        telemetry_metrics:counter(~"shigoto.job.discarded.count"),

        %% Job execution time, tagged by worker + queue
        telemetry_metrics:distribution(
            ~"shigoto.job.completed.duration_ms",
            #{tags => [worker, queue]}
        ),

        %% Time a job waited in the queue before being claimed
        telemetry_metrics:distribution(
            ~"shigoto.job.claimed.queue_wait_ms",
            #{tags => [queue]}
        ),

        %% Resilience signals, tagged by worker
        telemetry_metrics:counter(
            ~"shigoto.resilience.circuit_open.count",
            #{tags => [worker]}
        ),
        telemetry_metrics:counter(
            ~"shigoto.resilience.rate_limited.count",
            #{tags => [worker]}
        ),

        %% Queue throughput: sum of jobs claimed per poll
        telemetry_metrics:sum(~"shigoto.queue.poll.claimed", #{tags => [queue]})
    ].
```

Hand `metrics/0` to a reporter such as `telemetry_metrics_prometheus` to expose
the values, or `telemetry_metrics_statsd` to push them.

The equivalent in Elixir:

```elixir
import Telemetry.Metrics

def metrics do
  [
    counter("shigoto.job.completed.count"),
    counter("shigoto.job.failed.count"),
    distribution("shigoto.job.completed.duration_ms", tags: [:worker, :queue]),
    distribution("shigoto.job.claimed.queue_wait_ms", tags: [:queue]),
    counter("shigoto.resilience.circuit_open.count", tags: [:worker]),
    sum("shigoto.queue.poll.claimed", tags: [:queue])
  ]
end
```

## Seeing shigoto's own logs

Alongside each event, shigoto logs the job lifecycle (`job inserted`,
`job completed`, `job failed`, `job discarded`, ...) with `domain => [shigoto]`
in the metadata. OTP's `default` handler only passes events with no domain or
an `[otp, ...]` one, so out of the box these logs are dropped, failures
included. Let the shigoto domain through to see them:

```erlang
ok = logger:add_handler_filter(
    default, shigoto, {fun logger_filters:domain/2, {log, sub, [shigoto]}}
).
```

or in `sys.config`, as a filter on the handler that should show them. The
completed and inserted lines are at `info`, so the primary level must allow
`info` as well. Common Test redirects logging and shows these lines whatever
the filters, so a test run is not a reliable check.

While a job runs, its process carries `shigoto_job_id`, `shigoto_worker`,
`shigoto_queue` and `shigoto_attempt` in its logger metadata, so log lines a
worker writes from `perform/1` can be correlated with the job.
