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

## Cycle Detection

Shigoto validates dependencies on insert:

- **Missing IDs**: Returns `{error, {missing_dependencies, [Id, ...]}}` if
  any dependency ID doesn't exist.
- **Cycles**: Returns `{error, dependency_cycle}` if the new job's dependencies
  would create a circular dependency (e.g., A depends on B, B depends on A).

```erlang
%% This would fail with {error, dependency_cycle}
{ok, X} = shigoto:insert(#{worker => w, args => #{}}),
{ok, Y} = shigoto:insert(#{worker => w, args => #{}, depends_on => [maps:get(id, X)]}),
{error, dependency_cycle} = shigoto:insert(#{
    worker => w,
    args => #{},
    depends_on => [maps:get(id, X), maps:get(id, Y)]
}).
```

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
