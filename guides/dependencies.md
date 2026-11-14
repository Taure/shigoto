# Job Dependencies

Jobs can declare dependencies on other jobs using `depends_on`. A dependent
job stays in `available` state but won't be claimed until all its dependencies
have finished. What it does when one of them fails instead of completing is up
to the job: see [When a Dependency Fails](#when-a-dependency-fails).

## Basic Usage

```erlang
{ok, Step1} = shigoto:insert(#{
    worker => extract_worker,
    args => #{<<"source">> => <<"s3://bucket/data.csv">>}
}),

{ok, Step2} = shigoto:insert(#{
    worker => transform_worker,
    args => #{<<"format">> => <<"parquet">>},
    depends_on => [maps:get(id, Step1)]
}),

{ok, _Step3} = shigoto:insert(#{
    worker => load_worker,
    args => #{<<"table">> => <<"results">>},
    depends_on => [maps:get(id, Step2)]
}).
```

Step2 won't execute until Step1 completes. Step3 won't execute until Step2
completes. This creates an ETL pipeline that executes in order.

## Fan-in (Multiple Parents)

A job can depend on multiple parent jobs:

```erlang
{ok, A} = shigoto:insert(#{worker => fetch_api_a, args => #{}}),
{ok, B} = shigoto:insert(#{worker => fetch_api_b, args => #{}}),
{ok, C} = shigoto:insert(#{worker => fetch_api_c, args => #{}}),

{ok, _Merge} = shigoto:insert(#{
    worker => merge_results,
    args => #{},
    depends_on => [maps:get(id, A), maps:get(id, B), maps:get(id, C)]
}).
```

The merge job only runs after all three fetch jobs finish.

## Dependency Resolution

When a job completes, shigoto removes its ID from all `depends_on` arrays and
adds its result to each dependent's `deps_results`. Once a job's `depends_on`
array is empty, it becomes claimable.

## When a Dependency Fails

A dependency has failed when it is discarded (out of attempts, discarded by
hand, or rescued on its last attempt) or cancelled. What a job waiting on it
does then is the waiting job's choice, set with `on_dependency_failure`:

| Value | The waiting job |
|-------|-----------------|
| `run` (default) | Is released and runs without the failed job. Its `deps_results` holds `null` for it. |
| `cancel` | Is cancelled. |
| `discard` | Is discarded: `on_discard/2` runs, as for a job out of attempts. |

```erlang
{ok, Extract} = shigoto:insert(#{worker => extract_worker, args => #{}}),

%% Pointless without the extract: goes when the extract does.
{ok, _Load} = shigoto:insert(#{
    worker => load_worker,
    args => #{},
    depends_on => [maps:get(id, Extract)],
    on_dependency_failure => cancel
}),

%% Runs either way, and can tell from deps_results what happened.
{ok, _Report} = shigoto:insert(#{
    worker => report_worker,
    args => #{},
    depends_on => [maps:get(id, Extract)]
}).
```

A job that is cancelled or discarded this way has itself failed, so the jobs
waiting on *it* follow their own setting in turn, all the way down, in the same
database statement as the failure that started it. It never ran: its `attempt`
is unchanged, its `errors` gain a `dependency_failed` entry, and it counts as
discarded in its batch. A job waiting on several jobs goes as soon as one of
them fails.

The default for jobs that set nothing is the `on_dependency_failure`
application setting, `run` unless configured:

```erlang
{shigoto, [
    {on_dependency_failure, cancel}
]}
```

It is read when the dependency fails, on the node that records the failure, so
keep it the same on every node. Set the option on the job where the behaviour
matters.

With `cancel` or `discard`, a job cannot be inserted behind a dependency that
has already failed: `shigoto:insert/1` answers
`{error, {dependency_failed, [Id, ...]}}`.

A dependency that has already finished when the dependent job is inserted is
not waited for. Its result is put into the new job's `deps_results` straight
away, so depending on a job that completed a moment ago behaves like depending
on one that completes a moment later.

## Validation

Shigoto validates dependencies on insert:

- **Missing IDs**: Returns `{error, {missing_dependencies, [Id, ...]}}` if
  any dependency ID doesn't exist. A finished job that has been pruned or
  archived no longer exists.
- **Cycles**: there is nothing to check. A job gets its ID when it is
  inserted, so nothing can depend on it before then and inserting a job can
  never close a circle. Any shape of dependencies between existing jobs is
  accepted, including a diamond, or a job that waits both on a job and on that
  job's own dependency:

  ```erlang
  {ok, A} = shigoto:insert(#{worker => w, args => #{}}),
  {ok, B} = shigoto:insert(#{worker => w, args => #{}, depends_on => [maps:get(id, A)]}),
  {ok, _} = shigoto:insert(#{
      worker => w,
      args => #{},
      depends_on => [maps:get(id, A), maps:get(id, B)]
  }).
  ```

  Earlier versions refused that last insert with `{error, dependency_cycle}`.
  That error is no longer returned.

## Combining with Batches

Dependencies work well with batches for complex workflows:

```erlang
{ok, Batch} = shigoto:new_batch(#{
    callback_worker => pipeline_complete,
    callback_args => #{<<"pipeline">> => <<"etl_daily">>}
}),
BatchId = maps:get(id, Batch),

{ok, Extract} = shigoto:insert(#{
    worker => extract_worker, args => #{}, batch => BatchId
}),
{ok, _Transform} = shigoto:insert(#{
    worker => transform_worker, args => #{},
    batch => BatchId,
    depends_on => [maps:get(id, Extract)]
}).
```
