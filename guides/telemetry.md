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
| `[shigoto, job, completed]` | `count, duration, duration_ms, queue_wait_ms` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, failed]` | `count, duration, duration_ms, queue_wait_ms` | job_id, worker, queue, attempt, priority, reason |
| `[shigoto, job, snoozed]` | `count` | job_id, worker, queue, attempt, priority, snooze_reason |
| `[shigoto, job, discarded]` | `count` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, cancelled]` | `count` | job_id, worker, queue, attempt, priority |
| `[shigoto, job, progress]` | `progress` | job_id, worker, queue, attempt, priority, progress |

### Queue Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, queue, poll]` | `count, claimed` | queue |
| `[shigoto, queue, paused]` | `count` | queue |
| `[shigoto, queue, resumed]` | `count` | queue |

### Resilience Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, resilience, rate_limited]` | `count, retry_after_ms` | worker |
| `[shigoto, resilience, circuit_open]` | `count` | worker |
| `[shigoto, resilience, bulkhead_full]` | `count` | worker |
| `[shigoto, resilience, load_shed]` | `count` | priority |

### Batch Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, batch, completed]` | `count` | batch_id, total_jobs, completed_jobs, discarded_jobs |

### Cron Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[shigoto, cron, scheduled]` | `count` | name, worker, schedule |

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
