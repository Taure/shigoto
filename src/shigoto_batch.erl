-module(shigoto_batch).
-moduledoc """
Batch/workflow system for Shigoto. Groups jobs into batches with
completion and discard callbacks.

## Usage

```erlang
%% Create a batch with a callback worker
{ok, Batch} = shigoto:new_batch(#{
    callback_worker => my_batch_callback,
    callback_args => #{<<\"report_id\">> => 42}
}),
BatchId = maps:get(id, Batch),

%% Insert jobs into the batch
shigoto:insert(#{worker => step_one, args => #{}, batch => BatchId}),
shigoto:insert(#{worker => step_two, args => #{}, batch => BatchId}),

%% When all jobs have finished, my_batch_callback:perform/1 is called
%% with the callback_args. If any job was discarded or cancelled, the
%% batch state changes to 'callback_discarding' and the callback is
%% called with an added <<\"_batch_event\">> => <<\"discard\">> key.
```

## When a batch is finished

A batch finishes when `completed_jobs + discarded_jobs` reaches `total_jobs`.
`discarded_jobs` counts every job that ended without completing: discarded
after its last attempt, discarded by hand, or cancelled.

## The callback

The callback worker is checked like the worker of any job
(`shigoto_job:worker/1`) before its args are read: a batch row naming a module
that is not a worker gets no callback job, `shigoto_batch_callback_unrunnable`
is logged, and the batch stays in its `callback_*` state. `callback_args` are
stored encrypted when an encryption key is configured and the write format is
`v2` (`m:shigoto_crypto`), bound to the callback worker.

## Counting and settling

A job is counted by its batch in the statement that ends it
(`shigoto_repo:complete_job/3` and the statements that discard or cancel), so
the counts never miss a job that ended. `settle/2` then finishes a batch whose
count is full: in one transaction it moves the batch out of `active` and
inserts the callback job, so neither happens without the other. If the node
stops between the count and the settling, the batch is still `active` with a
full count, and `settle_finished/1`, which the queues run every
`rescue_interval`, settles it.

A job that is retried (`shigoto:retry/1`, `shigoto:retry_by/1`) leaves the
discarded count and is counted again when it ends. A batch that has already
settled does not run its callback a second time.

`total_jobs` goes up in the statement that inserts a job, so the batch only
knows about the jobs inserted so far. Insert a batch's jobs together, with
`shigoto:insert_all/1` or inside one `shigoto:transaction/1`: inserted one
statement at a time, the first job can finish while it is still the only one,
and the callback fires before the rest exist.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    create/2,
    increment_total/2,
    job_completed/2,
    job_discarded/2,
    jobs_discarded/3,
    settle/2,
    settle_finished/1,
    get/2,
    readable/1
]).

-doc "Create a new batch.".
-spec create(atom(), map()) -> {ok, map()} | {error, term()}.
create(Pool, Opts) ->
    Worker = maps:get(callback_worker, Opts, undefined),
    WorkerBin =
        case Worker of
            undefined -> null;
            W when is_atom(W) -> atom_to_binary(W, utf8);
            W when is_binary(W) -> W
        end,
    Args = shigoto_crypto:seal(
        encode_json(maps:get(callback_args, Opts, #{})), {callback_args, bound_to(WorkerBin)}
    ),
    SQL = <<
        "INSERT INTO shigoto_batches (callback_worker, callback_args) "
        "VALUES ($1, $2) RETURNING *"
    >>,
    case query(Pool, SQL, [WorkerBin, Args]) of
        #{rows := [Row]} -> {ok, Row};
        {error, _} = Err -> Err
    end.

-doc "Increment total job count for a batch.".
-spec increment_total(atom(), integer()) -> ok | {error, term()}.
increment_total(Pool, BatchId) ->
    SQL = ~"UPDATE shigoto_batches SET total_jobs = total_jobs + 1 WHERE id = $1",
    case query(Pool, SQL, [BatchId]) of
        #{command := update} -> ok;
        {error, _} = Err -> Err
    end.

-doc """
Count one more completed job in the batch, then settle it if that was its last.
shigoto counts a completed job in the statement that completes it; this is for
callers that move jobs by hand.
""".
-spec job_completed(atom(), integer()) -> ok | {error, term()}.
job_completed(Pool, BatchId) ->
    SQL = ~"UPDATE shigoto_batches SET completed_jobs = completed_jobs + 1 WHERE id = $1",
    case query(Pool, SQL, [BatchId]) of
        #{num_rows := _} -> settle(Pool, BatchId);
        {error, _} = Err -> Err
    end.

-doc "Record a discarded job in the batch. May trigger callback.".
-spec job_discarded(atom(), integer()) -> ok | {error, term()}.
job_discarded(Pool, BatchId) ->
    jobs_discarded(Pool, BatchId, 1).

-doc """
Count `Count` more jobs of the batch that ended without completing, discarded
or cancelled, then settle it if those were its last. As with `job_completed/2`,
shigoto itself counts in the statement that ends the jobs.
""".
-spec jobs_discarded(atom(), integer(), pos_integer()) -> ok | {error, term()}.
jobs_discarded(Pool, BatchId, Count) ->
    SQL = ~"UPDATE shigoto_batches SET discarded_jobs = discarded_jobs + $2 WHERE id = $1",
    case query(Pool, SQL, [BatchId, Count]) of
        #{num_rows := _} -> settle(Pool, BatchId);
        {error, _} = Err -> Err
    end.

-doc """
Finish the batch if every job it knows of has ended and it is still `active`.

One transaction moves it to `finished` (no callback worker),
`callback_completing` or `callback_discarding` (a job was discarded or
cancelled) and inserts the callback job. Only one caller makes the move, so
the callback is enqueued once. When the callback cannot be enqueued the move
is rolled back, `shigoto_batch_settle_failed` is logged and the answer is
`{error, settle_failed}`; `settle_finished/1` tries again.
""".
-spec settle(atom(), integer()) -> ok | {error, settle_failed}.
settle(Pool, BatchId) ->
    try shigoto:transaction(fun() -> settled(Pool, BatchId) end, #{pool => Pool}) of
        {settled, Batch} ->
            _ = shigoto_telemetry:batch_completed(Batch),
            ok;
        unsettled ->
            ok
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                msg => ~"shigoto_batch_settle_failed",
                batch_id => BatchId,
                reason => shigoto_error:shape({Class, Reason}),
                note => ~"the batch stays active; the next sweep settles it"
            }),
            {error, settle_failed}
    end.

-doc """
Settle the batches that are still `active` although every job has ended: what
a node that stopped between counting a batch's last job and settling it left
behind. Answers how many it looked at.
""".
-spec settle_finished(atom()) -> {ok, non_neg_integer()} | {error, term()}.
settle_finished(Pool) ->
    SQL =
        ~"""
        SELECT id FROM shigoto_batches
        WHERE state = 'active' AND total_jobs > 0
        AND completed_jobs + discarded_jobs >= total_jobs
        ORDER BY id LIMIT 100
        """,
    case query(Pool, SQL, []) of
        #{rows := Rows} ->
            _ = [settle(Pool, BatchId) || #{id := BatchId} <- Rows, is_integer(BatchId)],
            {ok, length(Rows)};
        {error, _} = Err ->
            Err
    end.

-doc "Get a batch by ID, with its `callback_args` decrypted for reading.".
-spec get(atom(), integer()) -> {ok, map()} | {error, not_found | term()}.
get(Pool, BatchId) ->
    SQL = ~"SELECT * FROM shigoto_batches WHERE id = $1",
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Row]} -> {ok, readable(Row)};
        #{rows := []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% Runs inside the transaction `settle/2` opened. Anything that keeps the
%% callback from being enqueued raises, which rolls the move back.
-spec settled(atom(), integer()) -> {settled, map()} | unsettled.
settled(Pool, BatchId) ->
    SQL =
        ~"""
        UPDATE shigoto_batches SET
          state = CASE
            WHEN callback_worker IS NULL THEN 'finished'
            WHEN discarded_jobs > 0 THEN 'callback_discarding'
            ELSE 'callback_completing'
          END,
          completed_at = CASE WHEN callback_worker IS NULL THEN now() ELSE completed_at END
        WHERE id = $1 AND state = 'active' AND total_jobs > 0
        AND completed_jobs + discarded_jobs >= total_jobs
        RETURNING *
        """,
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Batch]} ->
            ok = called_back(Batch),
            {settled, Batch};
        #{rows := []} ->
            unsettled;
        {error, Reason} ->
            error({?MODULE, shigoto_db:reduced(Reason)})
    end.

%% The event is `discard` when any job of the batch was discarded or
%% cancelled, whichever job happened to finish last. The worker is checked
%% before the args are opened, as for a job.
called_back(#{callback_worker := null}) ->
    ok;
called_back(#{callback_worker := Name, discarded_jobs := Discarded} = Batch) ->
    Event =
        case Discarded > 0 of
            true -> discard;
            false -> complete
        end,
    case shigoto_job:worker(Name) of
        {ok, Worker} ->
            case callback_args(Batch) of
                {ok, Args} when is_map(Args) ->
                    enqueued(shigoto:insert(#{worker => Worker, args => with_event(Args, Event)}));
                {ok, _NotAMap} ->
                    callback_unrunnable(Batch, invalid_callback_args);
                {error, Reason} ->
                    callback_unrunnable(Batch, Reason)
            end;
        {error, {unknown_worker, _Name}} ->
            callback_unrunnable(Batch, unknown_worker)
    end.

enqueued({ok, _JobOrConflict}) -> ok;
enqueued({error, _Reason}) -> error({?MODULE, callback_not_enqueued}).

with_event(Args, complete) -> Args;
with_event(Args, discard) -> Args#{~"_batch_event" => ~"discard"}.

callback_unrunnable(Batch, Reason) ->
    ?LOG_ERROR(#{
        msg => ~"shigoto_batch_callback_unrunnable",
        batch_id => maps:get(id, Batch, undefined),
        callback_worker => maps:get(callback_worker, Batch, undefined),
        reason => Reason
    }),
    ok.

-spec callback_args(map()) -> {ok, term()} | {error, term()}.
callback_args(#{callback_args := Args}) when is_map(Args) ->
    {ok, Args};
callback_args(#{callback_args := Stored, callback_worker := Worker}) when is_binary(Stored) ->
    case shigoto_crypto:open(Stored, {callback_args, bound_to(Worker)}) of
        {ok, Plain} ->
            try
                {ok, json:decode(Plain)}
            catch
                _:_ -> {error, invalid_callback_args}
            end;
        {error, _} = Failed ->
            Failed
    end;
callback_args(_Batch) ->
    {ok, #{}}.

-doc """
A batch as it is shown to someone reading it: `callback_args` decrypted, still
JSON text. Args that do not open are replaced by the JSON string of the reason.
""".
-spec readable(map()) -> map().
readable(#{callback_args := Stored, callback_worker := Worker} = Batch) when is_binary(Stored) ->
    case shigoto_crypto:open(Stored, {callback_args, bound_to(Worker)}) of
        {ok, Plain} -> Batch#{callback_args => Plain};
        {error, plaintext_refused} -> Batch;
        {error, Reason} -> Batch#{callback_args => iolist_to_binary(json:encode(Reason))}
    end;
readable(Batch) ->
    Batch.

bound_to(Worker) when is_binary(Worker) -> Worker;
bound_to(_NoWorker) -> <<>>.

query(Pool, SQL, Params) ->
    shigoto_db:query(Pool, SQL, Params).

encode_json(Map) when is_map(Map) ->
    iolist_to_binary(json:encode(Map));
encode_json(Bin) when is_binary(Bin) ->
    Bin.
