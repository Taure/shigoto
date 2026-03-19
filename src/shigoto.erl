-module(shigoto).
-moduledoc ~"""
Public API for the Shigoto background job system.

Shigoto (仕事, "work") is a PostgreSQL-backed job queue for the Nova ecosystem.
Jobs are claimed via `FOR UPDATE SKIP LOCKED` for safe multi-node operation.

## Quick Start

```erlang
%% Define a worker
-module(my_email_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"to">> := To, <<"subject">> := Subject}) ->
    send_email(To, Subject),
    ok.
```

```erlang
%% Enqueue a job
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<"to">> => <<"user@example.com">>, <<"subject">> => <<"Hello">>}
}).
```
""".

-export([
    insert/1,
    insert/2,
    cancel/2,
    retry/2,
    drain_queue/1,
    drain_queue/2,
    pause_queue/1,
    resume_queue/1
]).

-doc "Insert a job with default options.".
-spec insert(map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams) ->
    insert(JobParams, #{}).

-doc "Insert a job with options. Params: worker, args, queue, priority, scheduled_at, max_attempts, unique.".
-spec insert(map(), map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams, Opts) ->
    Pool = shigoto_config:pool(),
    shigoto_repo:insert_job(Pool, JobParams, Opts).

-doc "Cancel a job by ID. Also stops executing jobs on this node.".
-spec cancel(atom(), integer()) -> ok | {error, term()}.
cancel(Pool, JobId) ->
    %% Kill the executor if running on this node
    case ets:whereis(shigoto_executors) of
        undefined ->
            ok;
        _ ->
            case ets:lookup(shigoto_executors, JobId) of
                [{_, Pid}] -> exit(Pid, shutdown);
                [] -> ok
            end
    end,
    shigoto_repo:cancel_job(Pool, JobId).

-doc "Retry a discarded or cancelled job.".
-spec retry(atom(), integer()) -> ok | {error, term()}.
retry(Pool, JobId) ->
    shigoto_repo:retry_job(Pool, JobId).

-doc "Drain a queue synchronously. Useful for testing.".
-spec drain_queue(binary()) -> ok.
drain_queue(Queue) ->
    drain_queue(Queue, #{}).

-doc "Drain a queue with options (e.g., `#{timeout => 5000}`).".
-spec drain_queue(binary(), map()) -> ok.
drain_queue(Queue, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    Pool = shigoto_config:pool(),
    drain_loop(Pool, Queue, Timeout).

-doc "Pause a queue by name — stops claiming new jobs.".
-spec pause_queue(binary()) -> ok | {error, not_found}.
pause_queue(Queue) ->
    with_queue_pid(Queue, fun shigoto_queue:pause/1).

-doc "Resume a paused queue by name.".
-spec resume_queue(binary()) -> ok | {error, not_found}.
resume_queue(Queue) ->
    with_queue_pid(Queue, fun shigoto_queue:resume/1).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

with_queue_pid(Queue, Fun) ->
    Children = supervisor:which_children(shigoto_queue_sup),
    case lists:keyfind({shigoto_queue, Queue}, 1, Children) of
        {_, Pid, worker, _} when is_pid(Pid) -> Fun(Pid);
        _ -> {error, not_found}
    end.

drain_loop(Pool, Queue, Timeout) ->
    case shigoto_repo:claim_jobs(Pool, Queue, 1) of
        {ok, []} ->
            ok;
        {ok, [Job]} ->
            _ = shigoto_executor:execute_sync(Job, Pool, Timeout),
            drain_loop(Pool, Queue, Timeout);
        {error, _} ->
            ok
    end.
