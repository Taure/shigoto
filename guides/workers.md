# Workers

## The shigoto_worker Behaviour

Every worker must implement the `shigoto_worker` behaviour with a single
callback:

```erlang
-callback perform(Args :: map()) -> ok | {error, term()}.
```

## Basic Worker

```erlang
-module(notification_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"user_id">> := UserId, <<"message">> := Message}) ->
    send_push_notification(UserId, Message),
    ok.
```

## Args Format

Job args are stored as JSONB in PostgreSQL. When your worker receives them,
they are a decoded map with binary keys:

```erlang
%% Inserting
shigoto:insert(#{
    worker => my_worker,
    args => #{<<"count">> => 42, <<"name">> => <<"test">>}
}).

%% In perform/1, args arrive as:
%% #{<<"count">> => 42, <<"name">> => <<"test">>}
```

Always use binary keys (`<<"key">>`) in args maps.

## Error Handling

Return `{error, Reason}` to indicate failure. The job will be retried if it
has remaining attempts:

```erlang
perform(#{<<"url">> := Url}) ->
    case httpc:request(get, {binary_to_list(Url), []}, [], []) of
        {ok, {{_, 200, _}, _, _Body}} ->
            ok;
        {ok, {{_, Status, _}, _, _}} ->
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.
```

If `perform/1` raises an exception (throw, error, or exit), the job is also
treated as a failure and retried.

## Max Attempts and Retries

The default `max_attempts` is **3**. Override it per job:

```erlang
shigoto:insert(#{
    worker => my_worker,
    args => #{},
    max_attempts => 10
}).
```

When a job fails:

1. If `attempt < max_attempts`, the job state changes to `retryable` and is
   rescheduled with exponential backoff.
2. If `attempt >= max_attempts`, the job state changes to `discarded`.

## Exponential Backoff

Retry delay is calculated as:

```
delay = min(attempt^4 + random(0..30), 1800) seconds
```

| Attempt | Approximate Delay |
|---------|------------------|
| 1 | 1-31 seconds |
| 2 | 16-46 seconds |
| 3 | 81-111 seconds |
| 4 | 256-286 seconds |
| 5+ | capped at 1800 seconds (30 minutes) |

## Discarded and Cancelled Jobs

Discarded or cancelled jobs can be manually retried:

```erlang
shigoto:retry(my_app_db, JobId).
```

Cancel a pending job:

```erlang
shigoto:cancel(my_app_db, JobId).
```

## Stale Job Rescue

Jobs stuck in `executing` state for more than 5 minutes are automatically
rescued and made available for retry. This handles cases where a node crashes
mid-execution.
