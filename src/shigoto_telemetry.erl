-module(shigoto_telemetry).
-moduledoc ~"""
Telemetry events and structured logging for Shigoto job lifecycle.

Emitted events:
- `[shigoto, job, completed]` — job finished successfully
- `[shigoto, job, failed]` — job failed (will retry or discard)
- `[shigoto, job, inserted]` — new job enqueued
""".

-export([job_completed/1, job_failed/2, job_inserted/1]).

-doc "Emit a job completed telemetry event.".
-spec job_completed(map()) -> ok.
job_completed(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, completed], #{count => 1}, Meta),
    logger:info("job completed", Meta).

-doc "Emit a job failed telemetry event.".
-spec job_failed(map(), term()) -> ok.
job_failed(Job, Reason) ->
    Meta = (job_meta(Job))#{reason => format_reason(Reason)},
    telemetry:execute([shigoto, job, failed], #{count => 1}, Meta),
    logger:warning("job failed", Meta).

-doc "Emit a job inserted telemetry event.".
-spec job_inserted(map()) -> ok.
job_inserted(Job) ->
    Meta = job_meta(Job),
    telemetry:execute([shigoto, job, inserted], #{count => 1}, Meta),
    logger:info("job inserted", Meta).

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
