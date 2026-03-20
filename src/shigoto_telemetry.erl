-module(shigoto_telemetry).
-moduledoc """
Telemetry events and structured logging for Shigoto job lifecycle.

Emitted events:
- `[shigoto, job, completed]` — job finished successfully
  - Measurements: `#{count => 1, duration => NativeTime}`
- `[shigoto, job, failed]` — job failed (will retry or discard)
  - Measurements: `#{count => 1, duration => NativeTime}`
  - Metadata includes `reason`
- `[shigoto, job, inserted]` — new job enqueued
- `[shigoto, job, snoozed]` — job rescheduled (rate limit, circuit open, etc.)
- `[shigoto, job, discarded]` — job permanently discarded
- `[shigoto, job, cancelled]` — job cancelled
- `[shigoto, job, progress]` — job progress updated
- `[shigoto, batch, completed]` — all batch jobs finished
""".

-export([
    job_completed/2,
    job_failed/3,
    job_inserted/1,
    job_snoozed/2,
    job_discarded/1,
    job_cancelled/1,
    job_progress/2,
    batch_completed/1
]).

-doc "Emit a job completed telemetry event with execution duration.".
-spec job_completed(map(), integer()) -> ok.
job_completed(Job, Duration) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, completed], #{count => 1, duration => Duration}, Meta),
    logger:info("job completed", Meta).

-doc "Emit a job failed telemetry event with execution duration.".
-spec job_failed(map(), term(), integer()) -> ok.
job_failed(Job, Reason, Duration) ->
    Meta = (job_meta(Job))#{reason => format_reason(Reason)},
    telemetry:execute([shigoto, job, failed], #{count => 1, duration => Duration}, Meta),
    logger:warning("job failed", Meta).

-doc "Emit a job inserted telemetry event.".
-spec job_inserted(map()) -> ok.
job_inserted(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, inserted], #{count => 1}, Meta),
    logger:info("job inserted", Meta).

-doc "Emit a job snoozed telemetry event.".
-spec job_snoozed(map(), binary()) -> ok.
job_snoozed(Job, Reason) ->
    Meta = (job_meta(Job))#{snooze_reason => Reason},
    telemetry:execute([shigoto, job, snoozed], #{count => 1}, Meta),
    logger:info("job snoozed", Meta).

-doc "Emit a job discarded telemetry event.".
-spec job_discarded(map()) -> ok.
job_discarded(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, discarded], #{count => 1}, Meta),
    logger:warning("job discarded", Meta).

-doc "Emit a job cancelled telemetry event.".
-spec job_cancelled(map()) -> ok.
job_cancelled(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, cancelled], #{count => 1}, Meta),
    logger:info("job cancelled", Meta).

-doc "Emit a job progress telemetry event.".
-spec job_progress(map(), 0..100) -> ok.
job_progress(Job, Progress) ->
    Meta = (job_meta(Job))#{progress => Progress},
    telemetry:execute([shigoto, job, progress], #{progress => Progress}, Meta).

-doc "Emit a batch completed telemetry event.".
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
    logger:info("batch completed", Meta).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

job_meta(Job) ->
    #{
        job_id => maps:get(id, Job, undefined),
        worker => maps:get(worker, Job),
        queue => maps:get(queue, Job),
        attempt => maps:get(attempt, Job, 0),
        domain => [shigoto]
    }.

format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
