-module(shigoto).
-moduledoc """
Public API for the Shigoto background job system.

Shigoto (仕事, "work") is a PostgreSQL-backed job queue for the Nova ecosystem.
Jobs are claimed via `FOR UPDATE SKIP LOCKED` for safe multi-node operation.

## Quick Start

```erlang
%% Define a worker
-module(my_email_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<\"to\">> := To, <<\"subject\">> := Subject}) ->
    send_email(To, Subject),
    ok.
```

```erlang
%% Enqueue a job
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<\"to\">> => <<\"user@example.com\">>, <<\"subject\">> => <<\"Hello\">>}
}).
```

## Bulk Insert

```erlang
shigoto:insert_all([
    #{worker => my_worker, args => #{<<\"id\">> => 1}},
    #{worker => my_worker, args => #{<<\"id\">> => 2}},
    #{worker => my_worker, args => #{<<\"id\">> => 3}}
]).
```

## Batches

```erlang
{ok, Batch} = shigoto:new_batch(#{
    callback_worker => my_batch_callback,
    callback_args => #{<<\"report\">> => 1}
}),
BatchId = maps:get(id, Batch),
shigoto:insert(#{worker => step1, args => #{}, batch => BatchId}),
shigoto:insert(#{worker => step2, args => #{}, batch => BatchId}).
```
""".

-export([
    insert/1,
    insert/2,
    insert_all/1,
    insert_all/2,
    cancel/2,
    cancel_by/2,
    retry/2,
    retry_by/2,
    drain_queue/1,
    drain_queue/2,
    pause_queue/1,
    resume_queue/1,
    add_queue/2,
    remove_queue/1,
    new_batch/1,
    get_batch/1,
    report_progress/2,
    get_job/1,
    health/0
]).

-doc "Insert a job with default options.".
-spec insert(map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams) ->
    insert(JobParams, #{}).

-doc "Insert a job with options. Params: worker, args, queue, priority, scheduled_at, max_attempts, unique, tags, batch.".
-spec insert(map(), map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams, Opts) ->
    Pool = shigoto_config:pool(),
    case shigoto_repo:insert_job(Pool, JobParams, Opts) of
        {ok, Job} ->
            shigoto_telemetry:job_inserted(Job),
            {ok, Job};
        Other ->
            Other
    end.

-doc "Bulk insert multiple jobs with default options.".
-spec insert_all([map()]) -> {ok, [map()]} | {error, term()}.
insert_all(JobParamsList) ->
    insert_all(JobParamsList, #{}).

-doc "Bulk insert multiple jobs with options.".
-spec insert_all([map()], map()) -> {ok, [map()]} | {error, term()}.
insert_all(JobParamsList, Opts) ->
    Pool = shigoto_config:pool(),
    case shigoto_repo:insert_all(Pool, JobParamsList, Opts) of
        {ok, Jobs} ->
            lists:foreach(fun shigoto_telemetry:job_inserted/1, Jobs),
            {ok, Jobs};
        Other ->
            Other
    end.

-doc "Cancel a job by ID. Also stops executing jobs on this node.".
-spec cancel(atom(), integer()) -> ok | {error, term()}.
cancel(Pool, JobId) ->
    case ets:whereis(shigoto_executors) of
        undefined ->
            ok;
        _ ->
            case ets:lookup(shigoto_executors, JobId) of
                [{_, Pid}] -> exit(Pid, shutdown);
                [] -> ok
            end
    end,
    Result = shigoto_repo:cancel_job(Pool, JobId),
    case Result of
        ok ->
            shigoto_telemetry:job_cancelled(#{id => JobId, worker => unknown, queue => unknown});
        _ ->
            ok
    end,
    Result.

-doc "Cancel jobs matching a pattern. Filters: worker, queue, tags, args.".
-spec cancel_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
cancel_by(Pool, Filters) ->
    shigoto_repo:cancel_by(Pool, Filters).

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
    Result = with_queue_pid(Queue, fun shigoto_queue:pause/1),
    case Result of
        ok -> shigoto_telemetry:queue_paused(Queue);
        _ -> ok
    end,
    Result.

-doc "Resume a paused queue by name.".
-spec resume_queue(binary()) -> ok | {error, not_found}.
resume_queue(Queue) ->
    Result = with_queue_pid(Queue, fun shigoto_queue:resume/1),
    case Result of
        ok -> shigoto_telemetry:queue_resumed(Queue);
        _ -> ok
    end,
    Result.

-doc "Create a new batch for grouping jobs.".
-spec new_batch(map()) -> {ok, map()} | {error, term()}.
new_batch(Opts) ->
    Pool = shigoto_config:pool(),
    shigoto_batch:create(Pool, Opts).

-doc "Get a batch by ID.".
-spec get_batch(integer()) -> {ok, map()} | {error, term()}.
get_batch(BatchId) ->
    Pool = shigoto_config:pool(),
    shigoto_batch:get(Pool, BatchId).

-doc "Report job progress (0-100). Call from within a worker's perform/1.".
-spec report_progress(integer(), 0..100) -> ok | {error, term()}.
report_progress(JobId, Progress) when Progress >= 0, Progress =< 100 ->
    Pool = shigoto_config:pool(),
    Result = shigoto_repo:update_progress(Pool, JobId, Progress),
    shigoto_telemetry:job_progress(#{id => JobId, worker => unknown, queue => unknown}, Progress),
    Result.

-doc "Get a job by ID.".
-spec get_job(integer()) -> {ok, map()} | {error, term()}.
get_job(JobId) ->
    Pool = shigoto_config:pool(),
    shigoto_repo:get_job(Pool, JobId).

-doc "Retry all jobs matching a filter. Filters: worker, queue, state, tags.".
-spec retry_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
retry_by(Pool, Filters) ->
    shigoto_repo:retry_by(Pool, Filters).

-doc "Add a queue at runtime without restart.".
-spec add_queue(binary(), pos_integer()) -> {ok, pid()} | {error, term()}.
add_queue(Queue, Concurrency) ->
    ShutdownMs = shigoto_config:shutdown_timeout() + 1000,
    ChildSpec = #{
        id => {shigoto_queue, Queue},
        start => {shigoto_queue, start_link, [Queue, Concurrency]},
        type => worker,
        shutdown => ShutdownMs
    },
    case supervisor:start_child(shigoto_queue_sup, ChildSpec) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

-doc "Remove a queue at runtime. Waits for in-flight jobs to finish.".
-spec remove_queue(binary()) -> ok | {error, term()}.
remove_queue(Queue) ->
    ChildId = {shigoto_queue, Queue},
    case supervisor:terminate_child(shigoto_queue_sup, ChildId) of
        ok -> supervisor:delete_child(shigoto_queue_sup, ChildId);
        {error, _} = Err -> Err
    end.

-doc "Health check. Returns ok with stats or error with details.".
-spec health() -> {ok, map()} | {error, map()}.
health() ->
    Pool = shigoto_config:pool(),
    try
        {ok, Counts} = shigoto_dashboard:job_counts(),
        {ok, Stale} = shigoto_dashboard:stale_jobs(),
        StaleCount = length(Stale),
        Queues = shigoto_config:queues(),
        QueueStatuses = check_queue_health(Queues, []),
        DownQueues = [Q || {Q, down} <- QueueStatuses],
        Status =
            case {StaleCount, DownQueues} of
                {0, []} -> ok;
                _ -> degraded
            end,
        {ok, #{
            status => Status,
            pool => Pool,
            counts => Counts,
            stale_jobs => StaleCount,
            queues => maps:from_list(QueueStatuses)
        }}
    catch
        _:Reason ->
            {error, #{status => unhealthy, reason => Reason, pool => Pool}}
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

with_queue_pid(Queue, Fun) ->
    Children = supervisor:which_children(shigoto_queue_sup),
    case lists:keyfind({shigoto_queue, Queue}, 1, Children) of
        {_, Pid, worker, _} when is_pid(Pid) -> Fun(Pid);
        _ -> {error, not_found}
    end.

check_queue_health([], Acc) ->
    lists:reverse(Acc);
check_queue_health([{Queue, _Conc} | Rest], Acc) ->
    Status =
        case with_queue_pid(Queue, fun erlang:is_process_alive/1) of
            true -> healthy;
            _ -> down
        end,
    check_queue_health(Rest, [{Queue, Status} | Acc]).

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
