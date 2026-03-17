-module(shigoto_telemetry).
-moduledoc ~"""
Telemetry events for Shigoto job lifecycle.

Emitted events:
- `[shigoto, job, completed]` — job finished successfully
- `[shigoto, job, failed]` — job failed (will retry or discard)
- `[shigoto, job, inserted]` — new job enqueued
""".

-export([job_completed/1, job_failed/2, job_inserted/1]).

-doc "Emit a job completed telemetry event.".
-spec job_completed(map()) -> ok.
job_completed(Job) ->
    telemetry:execute(
        [shigoto, job, completed],
        #{count => 1},
        #{job => Job, worker => maps:get(worker, Job), queue => maps:get(queue, Job)}
    ).

-doc "Emit a job failed telemetry event.".
-spec job_failed(map(), term()) -> ok.
job_failed(Job, Reason) ->
    telemetry:execute(
        [shigoto, job, failed],
        #{count => 1},
        #{
            job => Job,
            worker => maps:get(worker, Job),
            queue => maps:get(queue, Job),
            reason => Reason
        }
    ).

-doc "Emit a job inserted telemetry event.".
-spec job_inserted(map()) -> ok.
job_inserted(Job) ->
    telemetry:execute(
        [shigoto, job, inserted],
        #{count => 1},
        #{job => Job, worker => maps:get(worker, Job), queue => maps:get(queue, Job)}
    ).
