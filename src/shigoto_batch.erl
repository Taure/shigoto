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

%% When all jobs complete, my_batch_callback:perform/1 is called
%% with the callback_args. If any job is discarded, the batch
%% state changes to 'callback_discarding' and the callback is
%% called with an added <<\"_batch_event\">> => <<\"discard\">> key.
```
""".

-export([
    create/2,
    increment_total/2,
    job_completed/2,
    job_discarded/2,
    get/2
]).

-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

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
    Args = encode_json(maps:get(callback_args, Opts, #{})),
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

-doc "Record a completed job in the batch. May trigger callback.".
-spec job_completed(atom(), integer()) -> ok | {error, term()}.
job_completed(Pool, BatchId) ->
    SQL = <<
        "UPDATE shigoto_batches SET completed_jobs = completed_jobs + 1 "
        "WHERE id = $1 RETURNING *"
    >>,
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Batch]} -> maybe_fire_callback(Pool, BatchId, Batch, complete);
        {error, _} = Err -> Err
    end.

-doc "Record a discarded job in the batch. May trigger callback.".
-spec job_discarded(atom(), integer()) -> ok | {error, term()}.
job_discarded(Pool, BatchId) ->
    SQL = <<
        "UPDATE shigoto_batches SET discarded_jobs = discarded_jobs + 1 "
        "WHERE id = $1 RETURNING *"
    >>,
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Batch]} -> maybe_fire_callback(Pool, BatchId, Batch, discard);
        {error, _} = Err -> Err
    end.

-doc "Get a batch by ID.".
-spec get(atom(), integer()) -> {ok, map()} | {error, not_found | term()}.
get(Pool, BatchId) ->
    SQL = ~"SELECT * FROM shigoto_batches WHERE id = $1",
    case query(Pool, SQL, [BatchId]) of
        #{rows := [Row]} -> {ok, Row};
        #{rows := []} -> {error, not_found};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

maybe_fire_callback(Pool, BatchId, Batch, Event) ->
    #{
        total_jobs := Total,
        completed_jobs := Completed,
        discarded_jobs := Discarded,
        callback_worker := CallbackWorkerBin
    } = Batch,
    AllDone = (Completed + Discarded) >= Total,
    case {AllDone, CallbackWorkerBin} of
        {true, null} ->
            %% Atomically transition to finished — only one concurrent caller wins
            case try_transition(Pool, BatchId, ~"active", ~"finished") of
                ok ->
                    shigoto_telemetry:batch_completed(Batch),
                    finish_batch(Pool, Batch);
                already_transitioned ->
                    ok
            end;
        {true, _} ->
            NewState =
                case Event of
                    complete -> ~"callback_completing";
                    discard -> ~"callback_discarding"
                end,
            %% Atomically transition — only one concurrent caller wins
            case try_transition(Pool, BatchId, ~"active", NewState) of
                ok ->
                    shigoto_telemetry:batch_completed(Batch),
                    CallbackArgs0 = decode_callback_args(Batch),
                    CallbackArgs =
                        case Event of
                            complete -> CallbackArgs0;
                            discard -> CallbackArgs0#{~"_batch_event" => ~"discard"}
                        end,
                    CallbackWorker = binary_to_existing_atom(CallbackWorkerBin, utf8),
                    _ = shigoto:insert(#{
                        worker => CallbackWorker,
                        args => CallbackArgs
                    }),
                    ok;
                already_transitioned ->
                    ok
            end;
        {false, _} ->
            ok
    end.

try_transition(Pool, BatchId, FromState, ToState) ->
    SQL = ~"UPDATE shigoto_batches SET state = $3 WHERE id = $1 AND state = $2",
    case query(Pool, SQL, [BatchId, FromState, ToState]) of
        #{num_rows := 1} -> ok;
        #{num_rows := 0} -> already_transitioned;
        {error, _} -> already_transitioned
    end.

finish_batch(Pool, Batch) ->
    SQL = ~"UPDATE shigoto_batches SET state = 'finished', completed_at = now() WHERE id = $1",
    _ = query(Pool, SQL, [maps:get(id, Batch)]),
    ok.

decode_callback_args(#{callback_args := Args}) when is_map(Args) ->
    Args;
decode_callback_args(#{callback_args := Args}) when is_binary(Args) ->
    json:decode(Args);
decode_callback_args(_) ->
    #{}.

query(Pool, SQL, Params) ->
    pgo:query(SQL, Params, #{pool => Pool, decode_opts => ?DECODE_OPTS}).

encode_json(Map) when is_map(Map) ->
    iolist_to_binary(json:encode(Map));
encode_json(Bin) when is_binary(Bin) ->
    Bin.
