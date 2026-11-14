# Context Propagation

A job usually belongs to something larger: the request that enqueued it, the
job that enqueued it. A propagator carries that context, typically a trace,
from the process that inserts a job to the processes that run it, so the run
shows up in the same trace as the insert.

shigoto does not depend on a tracing library. It calls a module of yours.

## Setting it up

```erlang
{shigoto, [{propagator, my_app_job_context}]}.
```

The module implements `shigoto_propagator`. With OpenTelemetry:

```erlang
-module(my_app_job_context).
-behaviour(shigoto_propagator).
-export([inject/0, attach/1, detach/1]).

%% In the process that inserts: the current context as binaries.
inject() ->
    maps:from_list(otel_propagator_text_map:inject([])).

%% In the processes that run the job: make it the current context.
attach(Carrier) ->
    Ctx = otel_propagator_text_map:extract_to(otel_ctx:new(), maps:to_list(Carrier)),
    otel_ctx:attach(Ctx).

%% When the attempt is over, with what attach/1 answered.
detach(Token) ->
    otel_ctx:detach(Token).
```

The application does not start with a `propagator` that is not a loaded module
exporting all three.

## What is carried where

| Job | Context it runs in |
|---|---|
| `shigoto:insert/1,2`, also inside `shigoto:transaction/1` | the inserting process's |
| `shigoto:insert_all/1,2` | the inserting process's, one `inject/0` for the whole call |
| a retry, a snoozed job, a rescued job | the same as its first attempt |
| a job inserted from `perform/1` | the inserting job's |
| a batch callback | the job's that finished the batch |
| a job released by a dependency | its own, from its own insert |
| a cron job | what `inject/0` answers in the scheduler process, usually nothing |

The carrier is stored in the job's `meta` under `<<"_shigoto_carrier">>`, and
encrypted with it when an encryption key is configured. A job inserted with
that key already in its `meta` keeps it, which is how to hand over a context
by hand.

During an attempt the context is attached in the executor process, where
middleware, `backoff/2` and `on_discard/2` run, and in the process that runs
`perform/1`.

## Telemetry

Three events bracket each attempt and carry the carrier, so a handler can open
and close a span without reading the job:

| Event | Measurements | Metadata |
|---|---|---|
| `[shigoto, job, start]` | `system_time, monotonic_time` | job_id, worker, queue, attempt, priority, carrier |
| `[shigoto, job, stop]` | `duration, monotonic_time` | the same, and outcome |
| `[shigoto, job, exception]` | `duration, monotonic_time` | the same, and kind, reason |

`carrier` is `#{}` for a job without one. See [Telemetry](telemetry.md).

## Limits

- A carrier is a map of binaries to binaries: at most 32 entries, 4096 bytes
  of keys and values together. One outside that is dropped whole and
  `shigoto_carrier_dropped` is logged.
- A callback that raises is logged as `shigoto_propagator_failed`. The job is
  inserted, or run, without a context. A propagator cannot fail an insert or a
  job.
- A carrier is in telemetry metadata in the clear. Do not put secrets in it
  (baggage, for one).
- Without an encryption key, someone who can write to the jobs table can write
  a carrier. It is attached only if it is within the bounds above; treat a
  trace id from a job as you would one from a request header.
