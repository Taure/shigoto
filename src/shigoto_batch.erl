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

%% Insert the batch's jobs, all in one call
{ok, _Jobs} = shigoto:insert_all([
    #{worker => step_one, args => #{}, batch => BatchId},
    #{worker => step_two, args => #{}, batch => BatchId}
]),

%% When all jobs have finished, my_batch_callback:perform/1 is called
%% with the callback_args. If any job was discarded or cancelled, the
%% batch state changes to 'callback_discarding' and the callback is
%% called with an added <<\"_batch_event\">> => <<\"discard\">> key.
```

## When a batch is finished

A batch finishes when `completed_jobs + discarded_jobs` reaches `total_jobs`.
`discarded_jobs` counts every job that ended without completing: discarded
after its last attempt, discarded by hand, or cancelled.

`total_jobs` is the number of jobs inserted so far, so a batch's jobs have to
be inserted together: in one `shigoto:insert_all/1,2`, or inside one
`shigoto:transaction/1`. Inserted one statement at a time, the first job can
finish while it is the only one in the batch, and the callback runs before the
others exist. A job inserted after the batch has left `active` runs, and the
callback does not run again. A job for a fanout queue is refused: it never
ends.

## The callback

The callback worker is checked like the worker of any job before its args are
read, and both before the batch is
touched. A node that cannot run the callback (it does not have the module, the
module is outside its `workers` list, or it cannot read the `callback_args`)
leaves the batch `active`, writes nothing and logs
`shigoto_batch_callback_unrunnable`. Every node looks at such a batch again
each `rescue_interval`, so the first node that can run the callback settles it:
during a rolling deploy that is a node with the new release. A batch is only
ever in a `callback_*` state together with its callback job. A batch no node
can settle stays `active` and keeps being reported until the worker is deployed
or the row is deleted.

`callback_args` are stored encrypted when an encryption key is configured and
the write format is `v2` (`m:shigoto_crypto`), bound to the callback worker.

## Counting and settling

A job is counted by its batch in the statement that ends it
(`shigoto_repo:complete_job/3` and the statements that discard or cancel), so
the counts never miss a job that ended. A batch whose count is full is then
settled: one transaction moves it out of `active` and inserts the callback job,
so neither happens without the other. If the node stops between the count and
the settling, the batch is still `active` with a full count, and the sweep a
node runs every `rescue_interval` settles it.

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
        #{} -> ok;
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

-doc false.
%% Count `Count` more jobs of the batch that ended without completing, discarded
%% or cancelled, then settle it if those were its last. As with `job_completed/2`,
%% shigoto itself counts in the statement that ends the jobs.
-spec jobs_discarded(atom(), integer(), pos_integer()) -> ok | {error, term()}.
jobs_discarded(Pool, BatchId, Count) ->
    SQL = ~"UPDATE shigoto_batches SET discarded_jobs = discarded_jobs + $2 WHERE id = $1",
    case query(Pool, SQL, [BatchId, Count]) of
        #{num_rows := _} -> settle(Pool, BatchId);
        {error, _} = Err -> Err
    end.

-doc false.
%% Finish the batch if every job it knows of has ended and it is still `active`.
%%
%% One transaction locks the batch row, moves it to `finished` (no callback
%% worker), `callback_completing` or `callback_discarding` (a job was discarded or
%% cancelled) and inserts the callback job. Only one caller makes the move, so
%% the callback is enqueued once.
%%
%% When this node cannot run the callback, nothing is written:
%% `shigoto_batch_callback_unrunnable` is logged, the batch stays `active` and the
%% answer is `ok`. When the callback job cannot be inserted the move is rolled
%% back, `shigoto_batch_settle_failed` is logged and the answer is
%% `{error, settle_failed}`. Either way `settle_finished/1` tries again.
-spec settle(atom(), integer()) -> ok | {error, settle_failed}.
settle(Pool, BatchId) ->
    case attempted(Pool, BatchId) of
        failed ->
            {error, settle_failed};
        {unrunnable, Why} ->
            ?LOG_ERROR(Why#{
                msg => ~"shigoto_batch_callback_unrunnable",
                note => ~"the batch stays active until a node that can run its callback settles it"
            }),
            ok;
        _Settled ->
            ok
    end.

-spec attempted(atom(), integer()) -> settled | unsettled | failed | {unrunnable, map()}.
attempted(Pool, BatchId) ->
    try shigoto:transaction(fun() -> settled(Pool, BatchId) end, #{pool => Pool}) of
        {settled, Batch} when is_map(Batch) ->
            _ = shigoto_telemetry:batch_completed(Batch),
            settled;
        unsettled ->
            unsettled;
        {unrunnable, Why} when is_map(Why) ->
            {unrunnable, Why}
    catch
        Class:Reason ->
            ?LOG_ERROR(#{
                msg => ~"shigoto_batch_settle_failed",
                batch_id => BatchId,
                reason => shigoto_error:shape({Class, Reason}),
                note => ~"the batch stays active; the next sweep settles it"
            }),
            failed
    end.

-doc false.
%% Settle the batches that are still `active` although every job has ended: what
%% a node that stopped between counting a batch's last job and settling it left
%% behind, and what a node that could not run the callback left for another.
%% Answers how many it looked at.
%%
%% It goes through all of them, a hundred at a time in id order, so batches this
%% node cannot settle do not keep it from the ones behind them. Those are
%% reported in one `shigoto_batch_callback_unrunnable` log per call, with their
%% number and the first ten.
-spec settle_finished(atom()) -> {ok, non_neg_integer()} | {error, term()}.
settle_finished(Pool) ->
    settle_finished(Pool, 0, 0, {0, []}).

settle_finished(Pool, After, Looked, Unrunnable) ->
    SQL =
        ~"""
        SELECT id FROM shigoto_batches
        WHERE state = 'active' AND total_jobs > 0
        AND completed_jobs + discarded_jobs >= total_jobs
        AND id > $1
        ORDER BY id LIMIT 100
        """,
    case query(Pool, SQL, [After]) of
        #{rows := Rows} ->
            case [BatchId || #{id := BatchId} <- Rows, is_integer(BatchId)] of
                [] ->
                    ok = report_unrunnable(Unrunnable),
                    {ok, Looked};
                BatchIds ->
                    Left = [
                        Why
                     || BatchId <- BatchIds, {unrunnable, Why} <- [attempted(Pool, BatchId)]
                    ],
                    settle_finished(
                        Pool,
                        lists:max(BatchIds),
                        Looked + length(BatchIds),
                        counted(Left, Unrunnable)
                    )
            end;
        {error, _} = Err ->
            Err
    end.

counted(Left, {Count, Sample}) ->
    {Count + length(Left), lists:sublist(Sample ++ Left, 10)}.

report_unrunnable({0, []}) ->
    ok;
report_unrunnable({Count, Sample}) ->
    ?LOG_ERROR(#{
        msg => ~"shigoto_batch_callback_unrunnable",
        batches => Count,
        first => Sample,
        note => ~"these batches stay active until a node that can run their callbacks settles them"
    }).

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

%% Runs inside the transaction `settle/2` opened. The batch row is locked and
%% its callback checked before anything is written, so a node that cannot run
%% the callback has nothing to undo, also when the transaction is one the
%% caller opened. After that, anything that keeps the callback from being
%% enqueued raises, which rolls the move back.
-spec settled(atom(), integer()) -> {settled, map()} | unsettled | {unrunnable, map()}.
settled(Pool, BatchId) ->
    SQL =
        ~"""
        SELECT * FROM shigoto_batches
        WHERE id = $1 AND state = 'active' AND total_jobs > 0
        AND completed_jobs + discarded_jobs >= total_jobs
        FOR UPDATE
        """,
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Batch]} ->
            case callback(Batch) of
                {error, Reason} ->
                    {unrunnable, #{
                        batch_id => BatchId,
                        callback_worker =>
                            shigoto_job:worker_name(maps:get(callback_worker, Batch, undefined)),
                        reason => Reason
                    }};
                Callback ->
                    Moved = moved(Pool, BatchId),
                    ok = enqueued(Callback),
                    {settled, Moved}
            end;
        #{rows := []} ->
            unsettled;
        {error, Reason} ->
            error({?MODULE, shigoto_db:reduced(Reason)})
    end.

moved(Pool, BatchId) ->
    SQL =
        ~"""
        UPDATE shigoto_batches SET
          state = CASE
            WHEN callback_worker IS NULL THEN 'finished'
            WHEN discarded_jobs > 0 THEN 'callback_discarding'
            ELSE 'callback_completing'
          END,
          completed_at = CASE WHEN callback_worker IS NULL THEN now() ELSE completed_at END
        WHERE id = $1
        RETURNING *
        """,
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Batch]} -> Batch;
        {error, Reason} -> error({?MODULE, shigoto_db:reduced(Reason)})
    end.

%% The callback job of a batch, when this node can run it. The event is
%% `discard` when any job of the batch was discarded or cancelled, whichever
%% job happened to finish last. The worker is checked before the args are
%% opened, as for a job.
-spec callback(map()) -> none | {job, map()} | {error, term()}.
callback(#{callback_worker := null}) ->
    none;
callback(#{callback_worker := Name, discarded_jobs := Discarded} = Batch) ->
    Event =
        case Discarded > 0 of
            true -> discard;
            false -> complete
        end,
    case shigoto_job:worker(Name) of
        {ok, Worker} ->
            case callback_args(Batch) of
                {ok, Args} when is_map(Args) ->
                    {job, #{worker => Worker, args => with_event(Args, Event)}};
                {ok, _NotAMap} ->
                    {error, invalid_callback_args};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, {unknown_worker, _Name}} ->
            {error, unknown_worker}
    end.

enqueued(none) ->
    ok;
enqueued({job, JobParams}) ->
    case shigoto:insert(JobParams) of
        {ok, _JobOrConflict} -> ok;
        {error, _Reason} -> error({?MODULE, callback_not_enqueued})
    end.

with_event(Args, complete) -> Args;
with_event(Args, discard) -> Args#{~"_batch_event" => ~"discard"}.

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

-doc false.
%% A batch as it is shown to someone reading it: `callback_args` decrypted, still
%% JSON text. Args that do not open are replaced by the JSON string of the reason.
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
