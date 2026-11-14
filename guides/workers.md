# Workers

## The shigoto_worker Behaviour

Every worker implements the `shigoto_worker` behaviour. The only required
callback is `perform/1`:

```erlang
-callback perform(Args :: map()) -> ok | {error, term()} | {snooze, pos_integer()}.
```

## Basic Worker

### Erlang

```erlang
-module(notification_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"user_id">> := UserId, <<"message">> := Message}) ->
    send_push_notification(UserId, Message),
    ok.
```

### Elixir

```elixir
defmodule NotificationWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(%{"user_id" => user_id, "message" => message}) do
    send_push_notification(user_id, message)
    :ok
  end
end
```

## Args Format

Job args are stored as JSONB in PostgreSQL. They always arrive as a map with
**binary keys**:

```erlang
%% Insert with binary keys
shigoto:insert(#{worker => my_worker, args => #{<<"count">> => 42}}).

%% In perform/1: #{<<"count">> => 42}
```

```elixir
# Elixir string keys work directly
:shigoto.insert(%{worker: MyWorker, args: %{"count" => 42}})

# In perform/1: %{"count" => 42}
```

## Return Values

| Return | Effect |
|--------|--------|
| `ok` | Job marked as completed |
| `{error, Reason}` | Job failed, retried with backoff if attempts remain |
| `{snooze, Seconds}` | Job rescheduled for later without counting as a failure |

Exceptions (throw, error, exit) are treated as failures.

## Optional Callbacks

Workers can export optional callbacks to configure defaults:

| Callback | Default | Description |
|----------|---------|-------------|
| `max_attempts/0` | `3` | Maximum retry attempts |
| `queue/0` | `<<"default">>` | Default queue name |
| `priority/0` | `0` | Default priority (higher = claimed first) |
| `timeout/0` | `300000` | Execution timeout in milliseconds |
| `unique/0` | none | Uniqueness constraints |
| `tags/0` | `[]` | Default tags for this worker |
| `backoff/2` | exponential | Custom backoff strategy |
| `rate_limit/0` | none | Per-worker rate limiting via seki |
| `concurrency/0` | none | Max concurrent executions across all queues |
| `middleware/0` | `[]` | Worker-specific middleware list |
| `on_discard/2` | none | Called when a job is permanently discarded |

### Erlang Example

```erlang
-module(api_sync_worker).
-behaviour(shigoto_worker).
-export([perform/1, max_attempts/0, queue/0, priority/0, timeout/0, tags/0]).

perform(#{<<"endpoint">> := Endpoint}) ->
    case httpc:request(binary_to_list(Endpoint)) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

max_attempts() -> 5.
queue() -> <<"api">>.
priority() -> 3.
timeout() -> 60000.
tags() -> [<<"api">>, <<"sync">>].
```

### Elixir Example

```elixir
defmodule ApiSyncWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(%{"endpoint" => endpoint}) do
    case HTTPoison.get(endpoint) do
      {:ok, %{status_code: 200}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def max_attempts, do: 5
  def queue, do: "api"
  def priority, do: 3
  def timeout, do: 60_000
  def tags, do: ["api", "sync"]
end
```

## Custom Backoff

Override the default exponential backoff (`min(attempt^4 + rand(0..30), 1800)`):

```erlang
-module(gentle_worker).
-behaviour(shigoto_worker).
-export([perform/1, backoff/2]).

perform(_Args) -> {error, try_later}.

%% Linear backoff: 10 seconds per attempt, max 5 minutes
backoff(Attempt, _Error) ->
    min(Attempt * 10, 300).
```

```elixir
defmodule GentleWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(_args), do: {:error, :try_later}

  def backoff(attempt, _error), do: min(attempt * 10, 300)
end
```

## on_discard Callback

Called when a job exhausts all attempts and is permanently discarded:

```erlang
-module(critical_worker).
-behaviour(shigoto_worker).
-export([perform/1, on_discard/2]).

perform(_Args) -> {error, still_broken}.

on_discard(Args, Errors) ->
    logger:error("critical job discarded", #{args => Args, errors => Errors}),
    alert_ops_team(Args).
```

It also runs for a job discarded because a job it waited on failed
(`on_dependency_failure => discard`) and for one the stale-job rescue discards.

The callback runs in a process of its own, after the job has been discarded:
not in the queue, and not in the process whose `shigoto:cancel/1` ended a job
others were waiting on. It may take up to `on_discard_timeout` (60000 ms) and is
stopped after that (`shigoto_on_discard_timeout` is logged). One that raises is
logged as `shigoto_on_discard_failed`, with the shape of the reason and none
of its values. At most 10 run at a time on a node and up to 10000 wait their
turn; past that, callbacks are not run and `shigoto_on_discard_dropped` says
how many. It is a notification, not a step of the job: a node that stops
between the discard and the callback does not run it. Work that must happen
belongs in a job.

## A Job Whose Worker Is Missing

A job row names its worker module. When the node that claims it cannot run that
module (it is not loaded there, or it has no `perform/1`), the attempt fails
with `unknown_worker` and the job follows the normal path: it is retried with
the default backoff and discarded at `max_attempts`. During a rolling deploy
that gives a node on the new release the chance to claim a job whose worker the
old release does not have. A worker that was renamed or removed with jobs still
queued ends up discarded, with the reason in its `errors`. The node logs
`shigoto_job_unknown_worker` each time.

## Snoozing Jobs

Return `{snooze, Seconds}` to reschedule a job without counting as a failure:

```erlang
perform(#{<<"api_key">> := Key}) ->
    case check_rate_limit(Key) of
        ok -> do_work(Key);
        rate_limited -> {snooze, 60}  %% Try again in 60 seconds
    end.
```

Claiming a job counts an attempt, so a snooze raises the job's `max_attempts` by
one to give it back: a job that snoozes is never discarded for it. `attempt`
keeps counting runs, snoozed ones included, and is what the default backoff
uses.

## Unique Jobs

Prevent duplicate jobs via the `unique/0` callback or per-insert options:

```erlang
unique() ->
    #{
        keys => [worker, args],         %% Fields to check
        states => [available, executing, retryable],  %% States to check against
        period => 300,                  %% Seconds (or infinity)
        replace => [priority],          %% Fields to update on conflict
        debounce => 5                   %% Reset scheduled_at on conflict (seconds)
    }.
```

The `debounce` option is useful for "run N seconds after the *last* trigger":

```erlang
%% Each call resets the timer to 5 seconds from now
shigoto:insert(
    #{worker => search_indexer, args => #{<<"table">> => <<"users">>}},
    #{unique => #{keys => [worker, args], debounce => 5}}
).
```

## Tags

Tag jobs for filtering and bulk operations:

```erlang
%% Via worker callback
tags() -> [<<"email">>, <<"marketing">>].

%% Via insert params
shigoto:insert(#{worker => my_worker, args => #{}, tags => [<<"urgent">>]}).

%% Cancel by tag
shigoto:cancel_by(my_pool, #{tags => [<<"marketing">>]}).
```

## Progress Tracking

Report progress from within `perform/1`:

```erlang
perform(#{<<"job_id">> := JobId, <<"items">> := Items}) ->
    Total = length(Items),
    lists:foldl(
        fun(Item, Idx) ->
            process(Item),
            shigoto:report_progress(JobId, (Idx * 100) div Total),
            Idx + 1
        end,
        1,
        Items
    ),
    ok.
```

## Job Dependencies

Jobs can depend on other jobs completing first:

```erlang
{ok, Job1} = shigoto:insert(#{worker => step_one, args => #{}}),
{ok, Job2} = shigoto:insert(#{worker => step_two, args => #{}}),
Job1Id = maps:get(id, Job1),
Job2Id = maps:get(id, Job2),

%% This job won't run until Job1 and Job2 complete
shigoto:insert(#{
    worker => final_step,
    args => #{},
    depends_on => [Job1Id, Job2Id]
}).
```

If `Job1` or `Job2` is discarded or cancelled instead, the waiting job runs
without it by default. Set `on_dependency_failure => cancel` or `discard` on
the waiting job to have it go the same way. See the
[Dependencies](dependencies.md) guide.

## Partitioned Queues

For multi-tenant fairness, set a `partition_key` so no single tenant starves others:

```erlang
shigoto:insert(#{
    worker => tenant_sync,
    args => #{<<"tenant_id">> => <<"acme">>},
    partition_key => <<"acme">>
}).
```

Use `shigoto_repo:claim_jobs_fair/3` for round-robin partition claiming.
