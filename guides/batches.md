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

If any job was discarded or cancelled, the callback receives an extra
`<<"_batch_event">> => <<"discard">>` key, whichever job finished last.

## When a Batch Finishes

A batch finishes when `completed_jobs + discarded_jobs` reaches `total_jobs`.
`discarded_jobs` counts every job that ended without completing: discarded
after its last attempt, discarded by hand, or cancelled (`shigoto:cancel/1`,
`shigoto:cancel_by/1`). A cancelled job therefore does not hold its batch open.

A job is counted in the statement that ends it, and the callback job is
inserted in the transaction that moves the batch out of `active`, so a batch
neither misses a job nor runs its callback twice. If a node stops between the
two, the batch is settled by the next `rescue_interval` sweep.

`total_jobs` goes up in the statement that inserts a job, so a batch only knows
about the jobs inserted so far. **Insert a batch's jobs together**, with
`shigoto:insert_all/1` or inside one `shigoto:transaction/1`. Inserted one
statement at a time, the first job can finish while it is still the only one in
the batch, and the callback fires before the rest exist.

With `encryption_write_format` `v2`, `callback_args` are encrypted like job
args. The callback worker is checked like any worker before the callback is
inserted: a batch row naming a module that is not a worker gets no callback,
logs `shigoto_batch_callback_unrunnable`, and does not affect the outcome of
the job that finished the batch.

## Batch States

| State | Description |
|-------|-------------|
| `active` | Jobs are still processing |
| `callback_completing` | All jobs done, callback inserted |
| `callback_discarding` | All jobs done, some discarded or cancelled, callback inserted |
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
