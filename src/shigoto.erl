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
shigoto:insert_all([
    #{worker => step1, args => #{}, batch => BatchId},
    #{worker => step2, args => #{}, batch => BatchId}
]).
```

Insert a batch's jobs in one `insert_all/1,2` or one `transaction/1`: a batch
only knows the jobs inserted so far, so its callback can run before a job
that is inserted later. See `m:shigoto_batch`.

## Transactional Enqueue

Enqueue jobs atomically with your own database writes. With `{repo, Repo}`
configured, shigoto runs on the kura repo's minato pool and shares its
transactions: a job inserted inside `Repo:transaction/1` commits or rolls back
with it, and kura writes inside `transaction/1` join shigoto's transaction. So a
job is never orphaned by a failed transaction, nor lost after a successful one.

```erlang
shigoto:transaction(fun() ->
    {ok, User} = my_app_repo:insert(UserChangeset),
    {ok, _Job} = shigoto:insert(#{
        worker => welcome_email_worker,
        args => #{~"user_id" => maps:get(id, User)}
    }),
    User
end).
```

`repo` must equal the name of the minato pool kura started for the repo: the
repo module, or the repo's `pool` key when kura's config sets one. Jobs inserted
inside a kura transaction on a pool of the same name join it whether shigoto is
configured with `repo` or `pool`; only kura writes joining `transaction/1` need
`repo`. `job_inserted` telemetry fires after the commit inside `transaction/1`,
but on insert inside `Repo:transaction/1`, so use `transaction/1` as the outer
boundary when telemetry has to be commit-accurate. See `m:shigoto_db` for how
the two share a connection.

## Returned jobs

Jobs returned by `insert/1,2`, `insert_all/1,2` and `get_job/1` are the stored
row as a map. The JSONB columns (`args`, `meta`, `errors`, `result`,
`deps_results`) are JSON text binaries; decode them with `json:decode/1`.
`perform/1` always gets `args` decoded.

## Reserved keys

In a job's `meta` and in a batch's `callback_args`, every key that starts with
`_shigoto` belongs to shigoto, as does `_batch_event` in `callback_args`. Do
not set them, apart from handing over a carrier by hand (`m:shigoto_propagator`),
and do not rely on ones that are not documented.
""".

-define(TXN_KEY, '$shigoto_txn').

-export([
    insert/1,
    insert/2,
    insert_all/1,
    insert_all/2,
    perform_job/2,
    perform_job/3,
    transaction/1,
    transaction/2,
    cancel/1,
    cancel/2,
    cancel_by/1,
    cancel_by/2,
    retry/1,
    retry/2,
    retry_by/1,
    retry_by/2,
    drain_queue/1,
    drain_queue/2,
    pause_queue/1,
    resume_queue/1,
    paused_queues/0,
    add_queue/2,
    remove_queue/1,
    new_batch/1,
    get_batch/1,
    report_progress/2,
    get_job/1,
    reencrypt/0,
    reencrypt/1,
    health/0
]).

-export_type([reencrypt_counts/0]).

-doc """
What `reencrypt/0,1` did to the values of one table: `rewritten` in the current
form, `skipped` because the row changed while it was read, `failed` because the
value does not open under any configured key. `scanned` counts rows.
""".
-type reencrypt_counts() :: #{
    scanned := non_neg_integer(),
    rewritten := non_neg_integer(),
    skipped := non_neg_integer(),
    failed := non_neg_integer()
}.

-doc "Insert a job with default options.".
-spec insert(map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams) ->
    insert(JobParams, #{}).

-doc "Insert a job with options. Params: worker, args, meta, queue, priority, scheduled_at, max_attempts, unique, tags, batch, depends_on, on_dependency_failure. `meta` keys that start with `_shigoto` are reserved.".
-spec insert(map(), map()) -> {ok, map()} | {ok, {conflict, map()}} | {error, term()}.
insert(JobParams, Opts) ->
    case shigoto_config:testing_mode() of
        disabled ->
            Pool = txn_pool(),
            case shigoto_repo:insert_job(Pool, JobParams, Opts) of
                {ok, {conflict, _}} = Conflict ->
                    Conflict;
                {ok, Job} ->
                    emit_or_defer(Job),
                    {ok, Job};
                Other ->
                    Other
            end;
        Mode ->
            shigoto_testing:handle_insert(JobParams, Mode)
    end.

-doc "Bulk insert multiple jobs with default options.".
-spec insert_all([map()]) -> {ok, [map()]} | {error, term()}.
insert_all(JobParamsList) ->
    insert_all(JobParamsList, #{}).

-doc """
Bulk insert multiple jobs with options. Answers one job per job given, in the
order given.

A job that is unique (its worker exports `unique/0`, or `Opts` has a `unique`
map) is inserted as `insert/1,2` inserts it, and the call is then one
transaction: all of it is inserted or none of it. Where such a job is a
duplicate, the answer holds the job that is already there in its place, and no
`[shigoto, job, inserted]` is emitted for it. `unique => false` in `Opts`
inserts every job without looking.
""".
-spec insert_all([map()], map()) -> {ok, [map()]} | {error, term()}.
insert_all(JobParamsList, Opts) ->
    case shigoto_config:testing_mode() of
        disabled ->
            Pool = txn_pool(),
            case shigoto_repo:placed_all(Pool, JobParamsList, Opts) of
                {ok, Placed} ->
                    _ = [emit_or_defer(Job) || {inserted, Job} <- Placed],
                    {ok, [Job || {_Outcome, Job} <- Placed]};
                {error, _} = Refused ->
                    Refused
            end;
        Mode ->
            shigoto_testing:handle_insert_all(JobParamsList, Mode)
    end.

-doc """
Run a worker through Shigoto's real perform path with no database, for unit
tests. Returns the raw worker result. See `m:shigoto_testing`.
""".
-spec perform_job(module(), map()) ->
    ok | {ok, term()} | {error, term()} | {snooze, pos_integer()}.
perform_job(Worker, Args) ->
    shigoto_testing:perform_job(Worker, Args).

-doc "Like `perform_job/2` with extra job context (`deps_results`, `attempt`, ...).".
-spec perform_job(module(), map(), map()) ->
    ok | {ok, term()} | {error, term()} | {snooze, pos_integer()}.
perform_job(Worker, Args, Opts) ->
    shigoto_testing:perform_job(Worker, Args, Opts).

-doc """
Run `Fun` inside a database transaction on the Shigoto pool.

Jobs enqueued with `insert/1,2` or `insert_all/1,2` from within `Fun` commit
atomically with any other work done on the same pool: if `Fun` raises, the
transaction rolls back and no jobs are enqueued. `job_inserted` telemetry fires
only after a successful commit.

To roll back, raise an exception. If a statement inside `Fun` fails and aborts the
transaction, the commit is rejected and `transaction_rolled_back` is raised — no
jobs are enqueued and no telemetry fires. Returns the value of `Fun`.
""".
-spec transaction(fun(() -> Result)) -> Result when Result :: term().
transaction(Fun) ->
    transaction(Fun, #{}).

-doc "Like `transaction/1`, on a specific pool via `#{pool => Pool}`. Nested calls inherit the outer pool.".
-spec transaction(fun(() -> Result), map()) -> Result when Result :: term().
transaction(Fun, Opts) when is_function(Fun, 0) ->
    case get(?TXN_KEY) of
        undefined ->
            Pool = maps:get(pool, Opts, shigoto_config:pool()),
            put(?TXN_KEY, {Pool, []}),
            try
                Result = shigoto_db:transaction(Pool, Fun),
                _ = [shigoto_telemetry:job_inserted(Job) || Job <- take_deferred()],
                Result
            catch
                Class:Reason:Stack ->
                    _ = take_deferred(),
                    erlang:raise(Class, Reason, Stack)
            end;
        {Pool, _} when is_atom(Pool) ->
            %% Nested: inherit the outer pool; the outermost transaction owns
            %% commit and the telemetry flush.
            shigoto_db:transaction(Pool, Fun)
    end.

-doc """
Cancel a job by ID.

A job that is waiting will not run. A job that is running is stopped: its
worker process is shut down (`shutdown`, then `kill` after five seconds if it
traps exits and has not gone) and nothing it did is recorded. On the node that
runs it this happens at once; from another node it happens at that node's next
heartbeat, so within `heartbeat_interval`. `perform/1` may be cut off at any
point, like any other crash, and the job is not retried.

Answers `ok` also when there is nothing to cancel: no such job, or one that
has already finished. `[shigoto, job, cancelled]` is only emitted for a job
this call cancelled, with that job's worker and queue.

Not transaction-aware: the process stop and `job_cancelled` telemetry fire
immediately, so this always uses the configured pool rather than an enclosing
`transaction/1,2` pool.
""".
-spec cancel(integer()) -> ok | {error, term()}.
cancel(JobId) ->
    cancel(shigoto_config:pool(), JobId).

-doc "Cancel a job by ID on the given pool. See `cancel/1`.".
-spec cancel(atom(), integer()) -> ok | {error, term()}.
cancel(Pool, JobId) ->
    case shigoto_repo:cancelled_job(Pool, JobId) of
        {ok, {cancelled, Job}} ->
            _ = [
                shigoto_executor:stop(Executor, cancelled)
             || Executor <- shigoto_executor:running(JobId)
            ],
            shigoto_telemetry:job_cancelled(Job);
        {ok, unchanged} ->
            ok;
        {error, _} = Err ->
            Err
    end.

-doc "Cancel available or retryable jobs matching a pattern. Uses the active transaction's pool, or the configured pool. Filters: worker, queue, tags, args, state. With an encryption key configured an `args` filter answers `{error, args_filter_unsupported_with_encryption}`, since stored args are ciphertext.".
-spec cancel_by(map()) -> {ok, non_neg_integer()} | {error, term()}.
cancel_by(Filters) ->
    cancel_by(txn_pool(), Filters).

-doc "Cancel available or retryable jobs matching a pattern. Filters: worker, queue, tags, args, state. With an encryption key configured an `args` filter answers `{error, args_filter_unsupported_with_encryption}`, since stored args are ciphertext.".
-spec cancel_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
cancel_by(Pool, Filters) ->
    shigoto_repo:cancel_by(Pool, Filters).

-doc """
Retry a discarded or cancelled job. Uses the active transaction's pool, or the
configured pool. A job that ended while it waited on other jobs waits on them
again: see the Retrying section of the Job Dependencies guide.
""".
-spec retry(integer()) -> ok | {error, term()}.
retry(JobId) ->
    retry(txn_pool(), JobId).

-doc "Retry a discarded or cancelled job.".
-spec retry(atom(), integer()) -> ok | {error, term()}.
retry(Pool, JobId) ->
    shigoto_repo:retry_job(Pool, JobId).

-doc "Drain a queue synchronously: claim and run its due jobs until none are left. Useful for testing.".
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

-doc """
The queues paused on this node.

Pause is per-node process state, so this reports what the local queue
processes are doing, not a cluster-wide view.
""".
-spec paused_queues() -> [binary()].
paused_queues() ->
    case whereis(shigoto_queue_sup) of
        undefined ->
            [];
        Sup when is_pid(Sup) ->
            [
                Queue
             || {{shigoto_queue, Queue}, Pid, worker, _} <- supervisor:which_children(Sup),
                is_binary(Queue),
                is_pid(Pid),
                shigoto_queue:is_paused(Pid)
            ]
    end.

-doc "Create a new batch for grouping jobs.".
-spec new_batch(map()) -> {ok, map()} | {error, term()}.
new_batch(Opts) ->
    shigoto_batch:create(txn_pool(), Opts).

-doc "Get a batch by ID.".
-spec get_batch(integer()) -> {ok, map()} | {error, term()}.
get_batch(BatchId) ->
    shigoto_batch:get(txn_pool(), BatchId).

-doc "Report job progress (0-100). Call from within a worker's perform/1.".
-spec report_progress(integer(), 0..100) -> ok | {error, term()}.
report_progress(JobId, Progress) when Progress >= 0, Progress =< 100 ->
    Result = shigoto_repo:update_progress(txn_pool(), JobId, Progress),
    shigoto_telemetry:job_progress(#{id => JobId, worker => unknown, queue => unknown}, Progress),
    Result.

-doc """
Get a job by ID. JSONB columns come back as JSON text; see the moduledoc. With
an encryption key configured `args`, `meta`, `result` and `deps_results` are
decrypted; a column that does not open is the JSON string of the reason
(`"decrypt_failed"`), never ciphertext.
""".
-spec get_job(integer()) -> {ok, map()} | {error, term()}.
get_job(JobId) ->
    shigoto_repo:get_job(txn_pool(), JobId).

-doc """
Rewrite stored job data in the form the current encryption settings write:
under the newest key, in the configured `encryption_write_format`, and
encrypted where it is still plaintext.

Run it after changing what is written: after setting
`encryption_write_format` to `v2`, after putting a new key first in
`encryption_keys`, or after configuring a key for a table that already holds
plaintext jobs. It walks `shigoto_jobs`, `shigoto_jobs_archive` and
`shigoto_batches` by id and, for every value that is not already in the
current form, decrypts it and encrypts it again: `args`, `meta`, `result`,
each entry of `deps_results`, and a batch's `callback_args`.

It also moves the `unique_key` of every row in `shigoto_jobs` to the digest
under the current key: a key stored in the clear before encryption was turned
on, and one stored under an older key. A unique insert looks for a job under
every listed key, and in the clear while `require_encrypted` is not set, so
duplicates are found before, during and after the run. Once it reports
`failed => 0` and `skipped => 0` an old key can be removed and
`require_encrypted` set. A `unique_key` written under a key that is no longer
listed cannot be moved and is counted as `failed`. Archived jobs are not looked
up by a unique insert, and their keys are left as they are.

It is safe while the queue runs. Rows are read in batches without a lock, and
each value is written back with a compare-and-swap, so a row that changed in
the meantime is left alone and counted as `skipped`; run it again to pick
those up. A running job is not affected by its row being rewritten. It can be
stopped and started again at any point, and running it twice changes nothing
the second time.

A v1 ciphertext is bound to nothing, so this is also the moment a v1 value
that was moved between rows gets bound to the row it was moved to. Run it once
every node writes `v2`, then drop `v1` from `encryption_read_formats`.
""".
-spec reencrypt() ->
    {ok, #{
        jobs := reencrypt_counts(),
        archive := reencrypt_counts(),
        batches := reencrypt_counts()
    }}
    | {error, term()}.
reencrypt() ->
    reencrypt(#{}).

-doc "Like `reencrypt/0` with options: `pool`, and `batch_size` (rows read per statement, default 500).".
-spec reencrypt(map()) ->
    {ok, #{
        jobs := reencrypt_counts(),
        archive := reencrypt_counts(),
        batches := reencrypt_counts()
    }}
    | {error, term()}.
reencrypt(Opts) ->
    shigoto_reencrypt:run(maps:get(pool, Opts, shigoto_config:pool()), Opts).

-doc "Retry discarded or cancelled jobs matching a filter. Uses the active transaction's pool, or the configured pool. Filters: worker, queue, state, tags, args. With an encryption key configured an `args` filter answers `{error, args_filter_unsupported_with_encryption}`, since stored args are ciphertext.".
-spec retry_by(map()) -> {ok, non_neg_integer()} | {error, term()}.
retry_by(Filters) ->
    retry_by(txn_pool(), Filters).

-doc "Retry discarded or cancelled jobs matching a filter. Filters: worker, queue, state (`discarded`, `cancelled` or a list), tags, args. With an encryption key configured an `args` filter answers `{error, args_filter_unsupported_with_encryption}`, since stored args are ciphertext.".
-spec retry_by(atom(), map()) -> {ok, non_neg_integer()} | {error, term()}.
retry_by(Pool, Filters) ->
    shigoto_repo:retry_by(Pool, Filters).

-doc """
Add a queue at runtime without restart.

Answers `{error, migration_pending}` while `m:shigoto_migrator` holds the queues
back; the configured queues start once the migration succeeds.
""".
-spec add_queue(binary(), pos_integer()) -> {ok, pid()} | {error, term()}.
add_queue(Queue, Concurrency) ->
    case shigoto_migrator:pending() of
        true ->
            {error, migration_pending};
        false ->
            case
                supervisor:start_child(
                    shigoto_queue_sup, shigoto_queue_sup:queue_spec(Queue, Concurrency)
                )
            of
                {ok, Pid} when is_pid(Pid) -> {ok, Pid};
                {error, {already_started, Pid}} when is_pid(Pid) -> {ok, Pid};
                {error, _} = Err -> Err
            end
    end.

-doc "Remove a queue at runtime. Waits for in-flight jobs to finish.".
-spec remove_queue(binary()) -> ok | {error, term()}.
remove_queue(Queue) ->
    ChildId = {shigoto_queue, Queue},
    case supervisor:terminate_child(shigoto_queue_sup, ChildId) of
        ok -> supervisor:delete_child(shigoto_queue_sup, ChildId);
        {error, _} = Err -> Err
    end.

-doc """
Health check. Returns ok with stats or error with details.

While `m:shigoto_migrator` holds the queues back it answers
`{error, #{status => unhealthy, reason => migration_pending, pool => Pool}}`.
""".
-spec health() -> {ok, map()} | {error, map()}.
health() ->
    Pool = shigoto_config:pool(),
    case shigoto_migrator:pending() of
        true -> {error, #{status => unhealthy, reason => migration_pending, pool => Pool}};
        false -> checked_health(Pool)
    end.

checked_health(Pool) ->
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

txn_pool() ->
    case get(?TXN_KEY) of
        {Pool, _} -> Pool;
        undefined -> shigoto_config:pool()
    end.

emit_or_defer(Job) ->
    case get(?TXN_KEY) of
        undefined ->
            shigoto_telemetry:job_inserted(Job);
        {Pool, Deferred} when is_list(Deferred) ->
            put(?TXN_KEY, {Pool, [Job | Deferred]}),
            ok
    end.

take_deferred() ->
    case erase(?TXN_KEY) of
        undefined ->
            [];
        {_Pool, Deferred} when is_list(Deferred) ->
            [Job || Job <- lists:reverse(Deferred), is_map(Job)]
    end.

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
        {ok, Jobs} ->
            executed(Pool, Jobs, Timeout),
            drain_loop(Pool, Queue, Timeout);
        {error, _} ->
            ok
    end.

executed(_Pool, [], _Timeout) ->
    ok;
executed(Pool, [Job | Jobs], Timeout) ->
    _ = shigoto_executor:execute_sync(Job, Pool, Timeout),
    executed(Pool, Jobs, Timeout).
