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
    drain_queue/2
]).

-doc "Insert a job with default options.".
-spec insert(map()) -> {ok, map()} | {error, term()}.
insert(JobParams) ->
    insert(JobParams, #{}).

-doc "Insert a job with options. Params: worker, args, queue, priority, scheduled_at, max_attempts.".
-spec insert(map(), map()) -> {ok, map()} | {error, term()}.
insert(JobParams, Opts) ->
    RepoMod = shigoto_config:repo(),
    shigoto_repo:insert_job(RepoMod, JobParams, Opts).

-doc "Cancel a job by ID.".
-spec cancel(module(), integer()) -> ok | {error, term()}.
cancel(RepoMod, JobId) ->
    shigoto_repo:cancel_job(RepoMod, JobId).

-doc "Retry a discarded or cancelled job.".
-spec retry(module(), integer()) -> ok | {error, term()}.
retry(RepoMod, JobId) ->
    shigoto_repo:retry_job(RepoMod, JobId).

-doc "Drain a queue synchronously. Useful for testing.".
-spec drain_queue(binary()) -> ok.
drain_queue(Queue) ->
    drain_queue(Queue, #{}).

-doc "Drain a queue with options (e.g., `#{timeout => 5000}`).".
-spec drain_queue(binary(), map()) -> ok.
drain_queue(Queue, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    RepoMod = shigoto_config:repo(),
    drain_loop(RepoMod, Queue, Timeout).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

drain_loop(RepoMod, Queue, Timeout) ->
    case shigoto_repo:claim_jobs(RepoMod, Queue, 1) of
        {ok, []} ->
            ok;
        {ok, [Job]} ->
            shigoto_executor:execute_sync(Job, RepoMod, Timeout),
            drain_loop(RepoMod, Queue, Timeout);
        {error, _} ->
            ok
    end.
