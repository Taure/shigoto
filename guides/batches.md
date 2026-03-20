# Batches

Batches group jobs together with completion callbacks. When all jobs in a
batch finish, a callback worker is automatically invoked.

## Creating a Batch

### Erlang

```erlang
{ok, Batch} = shigoto:new_batch(#{
    callback_worker => my_batch_callback,
    callback_args => #{<<"report_id">> => 42}
}),
BatchId = maps:get(id, Batch),

%% Add jobs to the batch
shigoto:insert(#{worker => step_one, args => #{<<"n">> => 1}, batch => BatchId}),
shigoto:insert(#{worker => step_two, args => #{<<"n">> => 2}, batch => BatchId}).
```

### Elixir

```elixir
{:ok, batch} = :shigoto.new_batch(%{
  callback_worker: MyBatchCallback,
  callback_args: %{"report_id" => 42}
})
batch_id = batch.id

:shigoto.insert(%{worker: StepOne, args: %{"n" => 1}, batch: batch_id})
:shigoto.insert(%{worker: StepTwo, args: %{"n" => 2}, batch: batch_id})
```

## Batch Callbacks

When all jobs complete, the callback worker receives the `callback_args`:

```erlang
-module(my_batch_callback).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"report_id">> := ReportId}) ->
    generate_report(ReportId),
    ok.
```

If any job is discarded, the callback receives an extra `<<"_batch_event">> => <<"discard">>` key.

## Batch States

| State | Description |
|-------|-------------|
| `active` | Jobs are still processing |
| `callback_completing` | All jobs done, callback inserted |
| `callback_discarding` | Some jobs discarded, callback inserted |
| `finished` | Batch complete (no callback configured) |

## Monitoring Batches

```erlang
{ok, Batch} = shigoto:get_batch(BatchId).
%% #{total_jobs => 10, completed_jobs => 7, discarded_jobs => 1, state => <<"active">>}
```

## Bulk Insert into Batches

```erlang
{ok, Batch} = shigoto:new_batch(#{callback_worker => report_worker}),
BatchId = maps:get(id, Batch),
shigoto:insert_all([
    #{worker => process_item, args => #{<<"id">> => I}, batch => BatchId}
 || I <- lists:seq(1, 1000)
]).
```
