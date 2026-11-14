# Job Dependencies

Jobs can declare dependencies on other jobs using `depends_on`. A dependent
job stays in `available` state but won't be claimed until all its dependencies
have completed, been discarded, or been cancelled.

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

When a job completes, gets discarded, or gets cancelled, shigoto automatically
removes its ID from all `depends_on` arrays. Once a job's `depends_on` array
is empty, it becomes claimable.

This means dependent jobs aren't permanently stuck if a parent fails — they
still execute after the parent reaches a terminal state.

A dependency that has already finished when the dependent job is inserted is
not waited for. Its result is put into the new job's `deps_results` straight
away, so depending on a job that completed a moment ago behaves like depending
on one that completes a moment later.

## Validation

Shigoto validates dependencies on insert:

- **Missing IDs**: Returns `{error, {missing_dependencies, [Id, ...]}}` if
  any dependency ID doesn't exist. A finished job that has been pruned or
  archived no longer exists.
- **Cycles**: A job gets its ID when it is inserted, so nothing can depend on
  it before then and inserting a job can never close a circle. Any shape of
  dependencies between existing jobs is accepted, including a diamond, or a job
  that waits both on a job and on that job's own dependency:

  ```erlang
  {ok, A} = shigoto:insert(#{worker => w, args => #{}}),
  {ok, B} = shigoto:insert(#{worker => w, args => #{}, depends_on => [maps:get(id, A)]}),
  {ok, _} = shigoto:insert(#{
      worker => w,
      args => #{},
      depends_on => [maps:get(id, A), maps:get(id, B)]
  }).
  ```

  `{error, dependency_cycle}` is returned only when the jobs depended on
  already wait for each other in a circle, which takes rows written to
  `depends_on` around this API. A job inserted behind such a circle would never
  run.

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
