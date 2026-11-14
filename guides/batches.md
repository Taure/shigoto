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

%% Add the batch's jobs, all in one call
{ok, _Jobs} = shigoto:insert_all([
    #{worker => step_one, args => #{<<"n">> => 1}, batch => BatchId},
    #{worker => step_two, args => #{<<"n">> => 2}, batch => BatchId}
]).
```

### Elixir

```elixir
{:ok, batch} = :shigoto.new_batch(%{
  callback_worker: MyBatchCallback,
  callback_args: %{"report_id" => 42}
})
batch_id = batch.id

{:ok, _jobs} =
  :shigoto.insert_all([
    %{worker: StepOne, args: %{"n" => 1}, batch: batch_id},
    %{worker: StepTwo, args: %{"n" => 2}, batch: batch_id}
  ])
```

### Insert a batch's jobs together

A batch knows only the jobs inserted so far: `total_jobs` goes up in the
statement that inserts a job. So the jobs of a batch have to arrive together,
in one `shigoto:insert_all/1,2` or inside one `shigoto:transaction/1`:

```erlang
shigoto:transaction(fun() ->
    {ok, _} = shigoto:insert(#{worker => step_one, args => #{}, batch => BatchId}),
    {ok, _} = shigoto:insert(#{worker => step_two, args => #{}, batch => BatchId})
end).
```

Two `shigoto:insert/1` calls on their own are two statements. The first job can
finish while it is still the only one in the batch, and the callback then runs
before the second job exists. Nothing can be added to a batch once it has left
`active`: a job inserted later runs, and the callback does not run again.

A job for a [fanout queue](fanout-queues.md) cannot be in a batch
(`{error, {fanout_job_in_batch, Queue}}`): it never ends.

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
`_batch_event` and every key that starts with `_shigoto` are reserved in
`callback_args`: shigoto may add them, so do not use them for your own values.

## When a Batch Finishes

A batch finishes when `completed_jobs + discarded_jobs` reaches `total_jobs`.
`discarded_jobs` counts every job that ended without completing: discarded
after its last attempt, discarded by hand, or cancelled (`shigoto:cancel/1`,
`shigoto:cancel_by/1`). A cancelled job therefore does not hold its batch open.

A job is counted in the statement that ends it, and the callback job is
inserted in the transaction that moves the batch out of `active`, so a batch
neither misses a job nor runs its callback twice. If a node stops between the
two, the batch is settled by the next `rescue_interval` sweep.

A discarded or cancelled job that is retried (`shigoto:retry/1`,
`shigoto:retry_by/1`) leaves `discarded_jobs` and is counted again when it
ends. Retrying a job of a batch that has already run its callback does not run
it again.

With `encryption_write_format` `v2`, `callback_args` are encrypted like job
args. With `v1`, the default, they are stored in the clear, as in 1.10.

### A callback a node cannot run

The callback worker is checked like any worker, and the `callback_args` are
read, before the batch is touched. A node that cannot run the callback (it does
not have the module, as during a rolling deploy, or cannot read the args)
writes nothing: the batch stays `active`, the job that finished it keeps its
own outcome, and `shigoto_batch_callback_unrunnable` is logged. Every node
looks at the batch again each `rescue_interval`, and the first that can run the
callback settles it. So a batch is in a `callback_*` state only together with
its callback job, and a callback is late rather than lost.

A batch no node can settle (its worker was removed, its key is gone) stays
`active` and is reported at every sweep. Deploy the worker, or delete the row.

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
