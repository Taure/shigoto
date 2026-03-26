# Testing

Shigoto provides helpers for testing workers and job workflows without
running background queue processes.

## drain_queue

The primary testing tool is `shigoto:drain_queue/1`, which synchronously
claims and executes all available jobs in a queue:

```erlang
-include_lib("stdlib/include/assert.hrl").

my_test(_Config) ->
    %% Insert a job
    shigoto:insert(#{
        worker => my_email_worker,
        args => #{<<"to">> => <<"test@example.com">>}
    }),

    %% Execute all jobs synchronously
    ok = shigoto:drain_queue(<<"default">>),

    %% Assert the side effect happened
    ?assert(email_was_sent(<<"test@example.com">>)).
```

With a timeout:

```erlang
ok = shigoto:drain_queue(<<"emails">>, #{timeout => 10000}).
```

## Test Setup

A typical CT suite for shigoto tests:

```erlang
-module(my_jobs_SUITE).
-behaviour(ct_suite).
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([test_email_job/1]).

-define(POOL, my_test_pool).

all() -> [test_email_job].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pgo),
    {ok, _} = pgo:start_pool(?POOL, #{
        host => "localhost",
        port => 5432,
        database => "my_app_test",
        user => "postgres",
        password => "postgres",
        pool_size => 5
    }),
    application:set_env(shigoto, pool, ?POOL),
    ok = shigoto_migration:up(?POOL),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    pgo:query(<<"DELETE FROM shigoto_jobs">>, [], #{pool => ?POOL}),
    ok.

test_email_job(_Config) ->
    {ok, Job} = shigoto:insert(#{
        worker => my_email_worker,
        args => #{<<"to">> => <<"user@test.com">>}
    }),
    ?assertEqual(<<"available">>, maps:get(state, Job)),
    ok = shigoto:drain_queue(<<"default">>).
```

## Testing Workers Directly

For unit testing worker logic without the job queue:

```erlang
test_worker_logic(_Config) ->
    Args = #{<<"to">> => <<"test@example.com">>, <<"subject">> => <<"Test">>},
    ?assertEqual(ok, my_email_worker:perform(Args)).
```

## Testing with Dependencies

```erlang
test_pipeline(_Config) ->
    {ok, Step1} = shigoto:insert(#{
        worker => extract_worker, args => #{}
    }),
    {ok, _Step2} = shigoto:insert(#{
        worker => transform_worker, args => #{},
        depends_on => [maps:get(id, Step1)]
    }),
    %% First drain executes Step1
    ok = shigoto:drain_queue(<<"default">>),
    %% Second drain executes Step2 (deps resolved)
    ok = shigoto:drain_queue(<<"default">>).
```

## Testing Batches

```erlang
test_batch_completion(_Config) ->
    {ok, Batch} = shigoto:new_batch(#{
        callback_worker => my_callback,
        callback_args => #{<<"report">> => 1}
    }),
    BatchId = maps:get(id, Batch),
    shigoto:insert(#{worker => my_worker, args => #{}, batch => BatchId}),
    shigoto:insert(#{worker => my_worker, args => #{}, batch => BatchId}),

    %% Drain executes both jobs + the callback
    ok = shigoto:drain_queue(<<"default">>),

    {ok, Final} = shigoto:get_batch(BatchId),
    ?assertEqual(<<"finished">>, maps:get(state, Final)).
```

## Testing Unique Jobs

```erlang
test_unique_prevents_duplicate(_Config) ->
    Opts = #{unique => #{keys => [worker, args]}},
    {ok, Job1} = shigoto:insert(
        #{worker => my_worker, args => #{<<"x">> => 1}}, Opts
    ),
    {ok, {conflict, Job2}} = shigoto:insert(
        #{worker => my_worker, args => #{<<"x">> => 1}}, Opts
    ),
    ?assertEqual(maps:get(id, Job1), maps:get(id, Job2)).
```

## Docker Compose for Tests

Use Docker Compose for PostgreSQL in CI and local testing:

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: root
      POSTGRES_DB: shigoto_test
    ports:
      - "5556:5432"
```
