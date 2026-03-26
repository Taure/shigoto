# Background Job Systems: Comprehensive Comparison

Research into the most popular background job queue systems across languages to inform
the design of Shigoto.

---

## 1. Sidekiq (Ruby)

**Storage:** Redis (also supports Valkey, Dragonfly)
**Polling model:** Push via Redis BRPOP (blocking pop). Jobs are pushed to Redis lists, workers block-wait.
**Multi-node safety:** Redis-based. No database transactions. Jobs can be lost if Redis crashes before persistence. Reliable fetch (Pro) uses RPOPLPUSH for at-least-once.

### Worker/Job Definition

```ruby
class HardWorker
  include Sidekiq::Worker
  sidekiq_options queue: "critical", retry: 5

  def perform(name, count)
    # work
  end
end

HardWorker.perform_async("bob", 5)
```

### Scheduling
- **Delayed:** `HardWorker.perform_in(5.minutes, "bob")` or `perform_at(timestamp)`
- **Cron/Recurring:** Enterprise only. Defined in YAML config with cron expressions.

### Retry/Backoff
- Formula: `(retry_count^4) + 15 + (rand(10) * (retry_count + 1))` seconds
- Default: 25 retries over ~21 days
- Customizable per-worker via `sidekiq_retry_in` block (can vary by exception type)
- Dead job set after retries exhausted

### Concurrency Control
- **Per-process:** configurable thread count (default 10)
- **Capsules (7.0+):** independent thread pools per queue group within a single process. E.g., a capsule with concurrency=1 for serial queue processing. Each capsule gets its own Redis connection pool.
- **Global concurrency:** Not in OSS. Enterprise rate limiter provides window/bucket/concurrent limiters.

### Job Dependencies/Workflows
- **Pro Batches:** group jobs, fire callbacks on `complete` or `success`. Nested batches supported.
- No built-in DAG/workflow engine.

### Batch Processing
- Pro feature. Create batch, add jobs, define callbacks. Tracks overall batch status.

### Dashboard/UI
- Built-in Rack app. Pages: Dashboard (processed/failed counts, real-time graph), Queues (list, size, latency), Retries (list, retry/delete), Scheduled (upcoming jobs), Dead (exhausted retries), Busy (active workers/processes).
- Actions: retry, delete, kill individual jobs. Clear queues. View error backtraces.
- Pro: multi-shard monitoring, filtering, searching by class/args.

### Observability
- Middleware chain for custom instrumentation
- Sidekiq::Metrics for historical data (Enterprise)
- StatsD, Datadog, Prometheus exporters via community gems
- Logging with structured context (JID, queue, worker class)

### Unique Jobs
- Enterprise only. `sidekiq_options unique_for: 1.hour` prevents duplicate enqueue within window.
- Uniqueness based on worker class + args by default.

### Rate Limiting
- Enterprise only. Concurrent (max N at a time), window (N per time period), bucket (token bucket). Applied via middleware. Jobs reschedule on limit hit with ~5min linear backoff.

### Encryption at Rest
- Enterprise only. Transparently encrypts the last argument hash ("secret bag"). AES-256-GCM. Your code doesn't change.

### Multi-tenancy
- No built-in multi-tenancy. Common pattern: persist `tenant_id` in job payload via middleware. Multiple Redis instances for full isolation.

### Standout Feature
- Raw throughput. Multi-threaded Ruby with Redis means thousands of jobs/sec with low memory. Battle-tested at massive scale (Shopify, GitHub, GitLab). Capsules for fine-grained concurrency isolation.

### Known Limitations
- Redis dependency adds infrastructure. Jobs can be lost on Redis failure (without Pro reliable fetch).
- Most advanced features locked behind Pro ($995/yr) and Enterprise ($2,495/yr).
- No transactional enqueue (can't atomically commit DB change + enqueue job).

---

## 2. GoodJob (Ruby)

**Storage:** PostgreSQL (exclusively)
**Polling model:** Hybrid. LISTEN/NOTIFY for immediate notification + polling fallback.
**Multi-node safety:** PostgreSQL advisory locks (session-level) for run-once guarantees. ACID transactions for enqueue.

### Worker/Job Definition

```ruby
class MyJob < ApplicationJob
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  good_job_control_concurrency_with(
    total_limit: 2,
    key: -> { "MyJob-#{arguments.first}" }
  )

  def perform(user_id)
    # work
  end
end
```

### Scheduling
- **Delayed:** `MyJob.set(wait: 5.minutes).perform_later(user_id)`
- **Cron:** Built-in. Configured in Ruby hash: `{ my_job: { cron: "*/5 * * *", class: "MyJob" } }`. Runs in CLI or async in web process. Scheduled to the second.

### Retry/Backoff
- Delegates to ActiveJob retry mechanisms (`retry_on` with `:polynomially_longer`, fixed, or custom proc).
- Polynomially_longer: `(executions^4) + 2` seconds with jitter.

### Concurrency Control
- `total_limit`: max concurrent across enqueue + perform
- `enqueue_limit`: max jobs that can be enqueued
- `perform_limit`: max jobs executing simultaneously
- `enqueue_throttle`: `[N, :period]` for throttling enqueue rate
- Key-based: lambda for per-resource limiting (e.g., per API endpoint, per user)

### Job Dependencies/Workflows
- No built-in workflow/DAG support.

### Batch Processing
- Built-in batches with callbacks. Track batch completion.

### Dashboard/UI
- Mounted Rails Engine. Pages: Jobs (filterable by state: scheduled/queued/running/succeeded/retried/discarded), Cron (recurring schedule list), Batches, Processes (running workers), Performance.
- Actions: retry, discard, reschedule individual jobs.
- Dark mode. Customizable templates. Label-based search.

### Observability
- ActiveSupport::Notifications integration
- Structured logging
- Rails standard instrumentation hooks

### Unique Jobs
- Via concurrency controls with `enqueue_limit: 1` and a key function. Not a dedicated unique jobs feature but achieves the same result.

### Rate Limiting
- `enqueue_throttle` for throttling. `perform_limit` with key for concurrent limiting. No token-bucket style rate limiter.

### Encryption at Rest
- No built-in encryption.

### Multi-tenancy
- Works with Rails multi-database. Separate GoodJob tables per database. No built-in schema-based tenancy.

### Standout Feature
- Zero additional infrastructure. Uses your existing Postgres. LISTEN/NOTIFY for near-instant job pickup (<3ms latency achievable). Transactional enqueue: wrap `perform_later` in a DB transaction and the job only enqueues if the transaction commits.

### Known Limitations
- PostgreSQL only (by design).
- Advisory locks can accumulate with very high job volumes.
- Throughput ceiling lower than Redis-based solutions under extreme load.
- Fewer advanced features than Sidekiq Pro/Enterprise.

---

## 3. Oban (Elixir)

**Storage:** PostgreSQL (primary), SQLite3, MySQL
**Polling model:** Hybrid. Postgres LISTEN/NOTIFY for push notification + configurable polling interval.
**Multi-node safety:** Postgres row-level locks + advisory locks. ACID transactional enqueue via Ecto.Multi. Leader election for cron/pruning via database.

### Worker/Job Definition

```elixir
defmodule MyApp.EmailWorker do
  use Oban.Worker, queue: :mailers, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email}}) do
    MyApp.Mailer.send(email)
    :ok
  end
end

%{email: "user@example.com"}
|> MyApp.EmailWorker.new(schedule_in: 60)
|> Oban.insert()
```

### Scheduling
- **Delayed:** `schedule_in: seconds` or `scheduled_at: DateTime`
- **Cron:** Built-in plugin. `crontab: [{"*/5 * * * *", MyApp.CronWorker}]`. Leader-elected, no duplicates across nodes.
- **Pro Dynamic Cron:** Runtime-configurable cron across cluster, timezone overrides.

### Retry/Backoff
- Default: exponential `attempt^4` seconds
- Customizable per-worker via `backoff/1` callback returning seconds
- `max_attempts` per worker (default 20)
- Jobs move to `discarded` after max attempts
- `snooze` return value to re-schedule with custom delay

### Concurrency Control
- **Per-queue local:** `queues: [default: 10, mailers: 5]` (local concurrency per node)
- **Pro global concurrency:** limit across all nodes for a queue
- **Pro rate limiting:** max N jobs per time window, partitionable by worker/args/args keys
- **Pro queue partitioning:** subdivide a queue for isolated concurrency

### Job Dependencies/Workflows
- **Pro Workflows:** DAG of jobs with arbitrary dependencies. Fan-out, fan-in, sequential.
- **Pro Chains:** strict sequential execution with automatic dependency wiring.
- **Pro Relay:** insert job and await its result, even across nodes.

### Batch Processing
- **Pro Batches:** group related jobs, track progress, fire callbacks on completion. Works across nodes.

### Dashboard/UI (Oban Web)
- Phoenix LiveView integration. Fully real-time, no polling.
- Pages: Jobs (filterable by queue/state/node/worker/args/tags), Queues (depth, throughput, configuration), Charts (time-series: completed/failed/cancelled).
- Actions: cancel, delete, retry individual or bulk (all matching filter). Scale queue concurrency. Pause/resume queues. Edit rate limits.
- Dark mode. Authentication via `resolve_access/1`. Composable filters with autocomplete.

### Observability
- Telemetry events: `[:oban, :job, :start | :stop | :exception]`, `[:oban, :engine, ...]`, `[:oban, :plugin, ...]`
- Metadata: worker, queue, attempt, args, duration, queue_time
- OpenTelemetry integration via `opentelemetry_oban`
- Direct hooks to error reporters (Sentry, AppSignal, Honeybadger, ErrorTracker)

### Unique Jobs
- Per-worker configuration: `unique: [period: 120, fields: [:worker, :args], keys: [:url], states: [:available, :scheduled, :executing]]`
- Fields: `:args`, `:queue`, `:worker`, `:meta`
- Keys: specific keys within args/meta maps for partial matching
- Period: seconds or `:infinity`
- States: which job states to check against (can include `:cancelled`/`:discarded`)
- Enforced at insert time via database constraints.
- Pro: bulk unique inserts.

### Rate Limiting
- Pro only. `rate_limit: [allowed: 100, period: {1, :minute}]`
- Partitionable: `partition: [fields: [:worker], keys: [:account_id]]` for per-tenant rate limits.

### Encryption at Rest
- Pro Worker: `encrypted: [:ssn, :credit_card]` encrypts specified arg fields at rest in the database using application-level encryption.

### Multi-tenancy
- **Prefix-based:** run separate Oban instances with different Postgres schema prefixes, fully isolated.
- **Dynamic repos:** `get_dynamic_repo` callback for multi-database setups.
- Oban queries tagged with `oban: true` option for `prepare_query/3` compatibility.

### Standout Feature
- The combination of Postgres-backed ACID guarantees with Elixir/BEAM concurrency. Transactional enqueue means you never have ghost jobs or lost jobs. Pro's workflow engine with fan-out/fan-in is best-in-class. The LiveView dashboard is genuinely real-time (WebSocket, not polling). The telemetry integration is exemplary.

### Known Limitations
- Best features require Pro subscription ($295/yr individual, $890/yr business).
- Postgres-dependent (SQLite/MySQL support is newer, less battle-tested).
- Not suitable for extremely high-throughput fire-and-forget (Redis-based solutions win on raw speed).
- Multi-tenancy with foreign-key-based approaches requires workarounds.

---

## 4. River (Go)

**Storage:** PostgreSQL (exclusively)
**Polling model:** Hybrid. LISTEN/NOTIFY + leader-based polling. A "producer" within each process consolidates work.
**Multi-node safety:** Postgres row locks + leader election. Transactional enqueue within application transactions.

### Worker/Job Definition

```go
type SortArgs struct {
    Strings []string `json:"strings"`
}

func (SortArgs) Kind() string { return "sort" }

type SortWorker struct {
    river.WorkerDefaults[SortArgs]
}

func (w *SortWorker) Work(ctx context.Context, job *river.Job[SortArgs]) error {
    sort.Strings(job.Args.Strings)
    return nil
}
```

Generics provide strongly-typed, structured arguments. No reflection or string-based dispatch.

### Scheduling
- **Delayed:** `river.InsertOpts{ScheduledAt: time.Now().Add(5 * time.Minute)}`
- **Periodic/Cron:** Built-in periodic jobs with cron expressions. Leader-elected, no duplicates.

### Retry/Backoff
- Default: exponential backoff
- Customizable via `NextRetry()` method on worker
- `MaxAttempts` per job (default 25)

### Concurrency Control
- **Per-queue local:** configurable worker count per queue
- **Pro global concurrency:** limits across all nodes, partitionable
- **Pro queue pause:** pause/resume queues at runtime

### Job Dependencies/Workflows
- **Pro Workflows:** DAG with fan-out/fan-in. Jobs define dependencies, downstream jobs auto-trigger on completion.
- **Pro Sequences:** strict sequential execution.

### Batch Processing
- Batch insertion via `InsertMany` using Postgres COPY FROM for high throughput.
- No batch-as-a-unit tracking in OSS.

### Dashboard/UI (River UI)
- Self-hosted React + Go application.
- Pages: Jobs (filterable list, detail view with attempts/errors/logs), Queues (depth, throughput).
- Actions: cancel, retry, delete jobs. Pause queues, adjust concurrency (Pro).
- `riverlog` middleware for structured log viewing per job attempt.
- Args hidden by default option for security.

### Observability
- Event subscriptions for job state changes
- OpenTelemetry integration
- `riverlog` middleware captures structured logs per attempt
- Prometheus metrics via community packages

### Unique Jobs
- Built-in. Unique by: args, period, queue, state. Configurable per-insert.

### Rate Limiting
- Not yet in OSS. Pro concurrency limits serve as a partial substitute. Full rate limiting planned.

### Encryption at Rest
- No built-in encryption.

### Multi-tenancy
- No built-in multi-tenancy. Achievable via separate Postgres schemas or databases.

### Standout Feature
- Go-native design. Generics for type-safe job args (no `interface{}` casting). Leverages pgx binary protocol for minimal serialization overhead. Batch insert via COPY FROM. Transactional enqueue with application database changes. Single-binary deployment. Very strong Postgres-native design from authors experienced with Postgres internals.

### Known Limitations
- Relatively new (launched late 2023). Smaller ecosystem.
- Pro features required for workflows, global concurrency, queue pause.
- Go-only (no polyglot support).
- No built-in rate limiting yet.

---

## 5. Faktory (Go server, polyglot workers)

**Storage:** Redis (embedded)
**Polling model:** Push. Workers connect via TCP protocol (RESP-like), FETCH blocking command.
**Multi-node safety:** Server-centric. Single Faktory server (or Enterprise HA). Workers are stateless fetchers.

### Worker/Job Definition

Workers are defined in any language. Jobs are JSON payloads:
```json
{
  "jid": "abc123",
  "jobtype": "EmailJob",
  "args": ["user@example.com", "Welcome!"],
  "queue": "default",
  "retry": 5
}
```

Worker libraries exist for Ruby, Go, Python, Node.js, Rust, Elixir, PHP.

### Scheduling
- **Delayed:** `at` field in job payload (RFC3339 timestamp)
- **Cron:** Enterprise only. Configured in server TOML. Adds Web UI tab.

### Retry/Backoff
- Exponential backoff (same as Sidekiq formula, same author: Mike Perham)
- Default 25 retries over ~21 days
- Reserved jobs timeout after 30 minutes; un-ACK'd jobs requeue automatically

### Concurrency Control
- Per-worker process concurrency (number of goroutines/threads)
- No global concurrency controls in OSS

### Job Dependencies/Workflows
- Enterprise batches with callbacks (complete/success)
- No DAG/workflow engine

### Batch Processing
- Enterprise only. Batch API with callbacks.

### Dashboard/UI
- Built-in web UI (similar to Sidekiq's, same author).
- Pages: Dashboard, Queues, Retries, Scheduled, Dead, Busy.
- Enterprise adds Cron tab.

### Observability
- Middleware chain for custom hooks
- Job tracking API (Enterprise): query state of job by JID
- Basic metrics in web UI

### Unique Jobs
- Enterprise only. `unique_for` seconds. Locks based on jobtype + args. Unlock on success (default) or start.

### Rate Limiting
- Not available.

### Encryption at Rest
- Not available.

### Multi-tenancy
- Not built-in.

### Standout Feature
- Language-agnostic. Single server, workers in any language. Brings Sidekiq-like ergonomics to polyglot environments. Same creator as Sidekiq (Mike Perham), so proven design patterns.

### Known Limitations
- Single-server architecture (Enterprise adds HA but still centralized).
- Redis-based (same durability concerns as Sidekiq).
- Smaller community than Sidekiq.
- Many features Enterprise-only.

---

## 6. Celery (Python)

**Storage:** Broker: RabbitMQ (recommended), Redis, SQS. Result backend: Redis, database, memcached, etc.
**Polling model:** Push. AMQP consumers or Redis BRPOP.
**Multi-node safety:** Broker handles message delivery. Result backend for state. No transactional enqueue.

### Worker/Job Definition

```python
@app.task(bind=True, max_retries=3, retry_backoff=True)
def send_email(self, to, subject, body):
    try:
        mailer.send(to, subject, body)
    except ConnectionError as exc:
        raise self.retry(exc=exc, countdown=60)
```

### Scheduling
- **Delayed:** `send_email.apply_async(args=[...], countdown=300)` or `eta=datetime`
- **Cron:** Celery Beat scheduler. Configurable in Python or database. Runs as separate process.

### Retry/Backoff
- `self.retry(countdown=N)` for manual retry with specific delay
- `autoretry_for` + `retry_backoff=True` for automatic exponential backoff
- `retry_backoff`: base delay (True=1s), doubles each attempt
- `retry_backoff_max`: cap (default 600s/10min)
- `retry_jitter`: randomize delay (default True, random between 0 and computed delay)
- `max_retries`: per-task limit
- **Major gotcha:** default acks message on receive, not on completion. Configurable via `acks_late=True` but not default.

### Concurrency Control
- **Per-worker:** `-c` flag (number of child processes/threads/greenlets)
- **Pool types:** prefork (multiprocessing), eventlet, gevent, solo (single-threaded)
- No built-in global concurrency limits

### Job Dependencies/Workflows (Canvas)
- **chain:** sequential pipeline, result flows to next task
- **group:** parallel execution, collect all results
- **chord:** group + callback when all complete
- **map/starmap:** apply task to list of args
- **chunks:** split iterable into batched groups
- Canvas primitives are composable (chains of groups, groups of chains, etc.)

### Batch Processing
- `group` and `chunks` for parallel batch execution.
- No batch-as-a-unit tracking with callbacks (chord callback is the closest).

### Dashboard/UI (Flower)
- Separate process. Tornado web server.
- Pages: Dashboard (overview stats), Workers (online/offline, active tasks, pool info), Tasks (history with state/runtime/timestamps, filterable), Broker (queue depths, consumers), Monitor (real-time charts).
- Actions: shutdown/restart workers, revoke tasks, rate limit tasks, view exception tracebacks.
- Prometheus metrics endpoint built-in.
- REST API for programmatic management.

### Observability
- Celery signals (task_prerun, task_postrun, task_failure, etc.)
- Prometheus integration via Flower
- Custom logging per-task
- OpenTelemetry via community packages

### Unique Jobs
- No built-in unique jobs. Community solutions (celery-once, celery-singleton) use Redis locks.

### Rate Limiting
- Per-task rate limit: `@app.task(rate_limit='10/m')`. Limits how fast a worker processes a specific task type. Not global across workers.

### Encryption at Rest
- No built-in encryption. Messages in broker are plaintext.

### Multi-tenancy
- No built-in multi-tenancy. Common pattern: routing tasks to tenant-specific queues.

### Standout Feature
- Canvas workflow primitives (chain/group/chord) are powerful and composable. Massive ecosystem and community. Broker flexibility (RabbitMQ, Redis, SQS). Battle-tested at enormous scale (Instagram, Mozilla). The de facto standard for Python async task processing.

### Known Limitations
- Complexity. Configuration is sprawling with hundreds of settings.
- Default ack-on-receive can lose tasks on worker crash.
- Celery Beat is single-point-of-failure (no built-in distributed scheduler).
- Memory leaks with long-running workers if not configured with `--max-tasks-per-child`.
- Python GIL limits CPU-bound concurrency (must use prefork/multiprocessing).
- No built-in unique jobs or deduplication.

---

## 7. Dramatiq (Python)

**Storage:** RabbitMQ (primary) or Redis
**Polling model:** Push. AMQP consumers or Redis-based polling.
**Multi-node safety:** Broker-dependent. RabbitMQ provides stronger guarantees.

### Worker/Job Definition

```python
import dramatiq

@dramatiq.actor(max_retries=3, min_backoff=1000, max_backoff=300000)
def send_email(to, subject):
    mailer.send(to, subject)

send_email.send("user@example.com", "Hello")
send_email.send_with_options(delay=300000)  # 5 min delay in ms
```

### Scheduling
- **Delayed:** `send_with_options(delay=milliseconds)`
- **Cron:** No built-in scheduler. Use APScheduler or periodiq as companion.

### Retry/Backoff
- Exponential backoff between `min_backoff` and `max_backoff` (in milliseconds)
- Jitter added automatically
- `max_retries` per actor
- **Key difference from Celery:** tasks are only acked after successful completion (not on receive). This is not configurable -- it's always safe.

### Concurrency Control
- Per-worker process/thread count configuration
- No global concurrency controls
- Separate delayed queue prevents delayed tasks from consuming worker memory (unlike Celery)

### Job Dependencies/Workflows
- **Pipelines:** `pipeline = send_email.message("a") | process_result.message()` for sequential chaining
- **Groups:** `group = dramatiq.group([task.message(i) for i in range(10)])` for parallel execution with `.wait()` or `.run()`
- Less composable than Celery Canvas but simpler API

### Batch Processing
- Groups serve as basic batch mechanism.

### Dashboard/UI
- No official dashboard. Community: `dramatiq-dashboard` (basic, limited).

### Observability
- Middleware-based architecture. Built-in middleware: `Retries`, `TimeLimit`, `ShutdownNotifications`, `Callbacks`.
- Prometheus middleware available.
- Structured logging middleware.

### Unique Jobs
- No built-in. Use external locking (Redis locks).

### Rate Limiting
- `dramatiq.rate_limits` module with `ConcurrentRateLimiter` (max N concurrent) and `WindowRateLimiter` (max N per time window). Backed by Redis.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- No built-in.

### Standout Feature
- "Sane defaults" philosophy. Acks-after-completion by default (the safe choice Celery doesn't make). Delayed tasks on separate queue (don't consume worker memory). Simpler API than Celery. Middleware architecture is clean and composable.

### Known Limitations
- Much smaller ecosystem than Celery.
- No built-in scheduler (need external package).
- No official dashboard/UI.
- Fewer workflow primitives than Celery Canvas.
- Less suitable for very large-scale deployments.

---

## 8. ARQ (Python)

**Storage:** Redis
**Polling model:** Polling. Workers poll Redis on configurable interval.
**Multi-node safety:** Redis-based. Job IDs for deduplication.

### Worker/Job Definition

```python
async def send_email(ctx, to: str, subject: str):
    await mailer.send(to, subject)

class WorkerSettings:
    functions = [send_email]
    redis_settings = RedisSettings()
    max_jobs = 10
```

### Scheduling
- **Delayed:** `await arq_redis.enqueue_job('send_email', to, subject, _defer_by=timedelta(minutes=5))`
- **Cron:** `cron_jobs = [cron(cleanup, hour=3, minute=30)]` in WorkerSettings

### Retry/Backoff
- Raise `Retry(defer=seconds)` from within job for manual retry
- No automatic exponential backoff built-in
- Pessimistic execution: jobs stay in queue until completion

### Concurrency Control
- `max_jobs` per worker (concurrent asyncio tasks)
- No global concurrency limits

### Job Dependencies/Workflows
- No built-in workflow/pipeline support.

### Batch Processing
- No built-in batch support.

### Dashboard/UI
- No built-in dashboard. Health check via `arq.worker.check_health()` CLI command.

### Observability
- Health recording to Redis at intervals
- `on_startup`/`on_shutdown`/`after_job_end` hooks
- Basic logging

### Unique Jobs
- Built-in via `_job_id` parameter. A job with a given ID cannot be re-enqueued until its result expires.

### Rate Limiting
- No built-in.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- No built-in.

### Standout Feature
- asyncio-native. Minimal, clean API. Perfect for Python async applications. Very lightweight (~500 lines of core code). Type hints throughout.

### Known Limitations
- Very minimal feature set. No dashboard, no workflows, no automatic backoff.
- Small community.
- Redis-only.
- No automatic retry with backoff (must raise Retry manually).
- Not suitable for large-scale production without significant custom work.

---

## 9. BullMQ (Node.js)

**Storage:** Redis (uses Redis Streams internally)
**Polling model:** Push. Redis Streams with XREADGROUP blocking reads.
**Multi-node safety:** Redis Streams consumer groups. Lua scripts for atomicity.

### Worker/Job Definition

```typescript
import { Queue, Worker } from 'bullmq';

const queue = new Queue('email');
await queue.add('send', { to: 'user@example.com', subject: 'Hello' });

const worker = new Worker('email', async (job) => {
  await sendEmail(job.data.to, job.data.subject);
  return { sent: true };
}, { concurrency: 5 });
```

### Scheduling
- **Delayed:** `queue.add('name', data, { delay: 5000 })` (milliseconds)
- **Repeatable:** `queue.add('name', data, { repeat: { pattern: '*/5 * * * *' } })` or `{ every: 10000 }` for interval-based

### Retry/Backoff
- `attempts: 3` with `backoff: { type: 'exponential', delay: 1000 }` (doubles each attempt)
- Built-in types: `exponential`, `fixed`
- Custom backoff: provide a function returning delay in ms
- Failed jobs move to `failed` set after exhausting attempts

### Concurrency Control
- **Per-worker:** `concurrency` option (number of concurrent jobs per Worker instance)
- **Rate limiting:** `limiter: { max: 10, duration: 1000 }` (max N jobs per duration ms). Worker-level. Token bucket algorithm.
- **Pro Groups:** rate limiting per job group (e.g., per-tenant)
- **Global concurrency:** via `concurrency` on queue level

### Job Dependencies/Workflows (Flows)
- **FlowProducer:** parent-child job relationships. Parent waits for all children to complete.
- Children can return data accessible to parent via `job.getChildrenValues()`.
- Nested flows supported.
- Not a full DAG engine but covers parent-child trees.

### Batch Processing
- No built-in batch-with-callbacks. Flows serve similar purpose for related job groups.

### Dashboard/UI
- **bull-board:** community UI. Shows queues, jobs by state, job details. Basic actions (retry, remove).
- **Taskforce.sh:** commercial SaaS dashboard. Real-time monitoring, historical metrics, alerts.
- **Arena:** another community dashboard.

### Observability
- Event emitters on Queue and Worker: `completed`, `failed`, `progress`, `drained`
- Job progress reporting: `job.updateProgress(42)`
- Custom metrics via events
- Prometheus exporter community packages

### Unique Jobs / Deduplication
- `jobId` for idempotency. Same ID = same job (won't create duplicate).
- Debounce: `debounce: { id: 'key', ttl: 5000 }` -- only last job in window executes.
- Throttle patterns via `removeOnComplete` + custom IDs.

### Rate Limiting
- Worker-level: `limiter: { max: N, duration: ms }`. Token bucket.
- Pro: per-group rate limiting.

### Encryption at Rest
- No built-in. Redis data is plaintext.

### Multi-tenancy
- Pro Groups: partition jobs by group (tenant). Each group gets independent rate limiting and concurrency.

### Standout Feature
- Redis Streams foundation (more robust than Redis lists used by Bull/Sidekiq). Flow system for parent-child job trees. TypeScript-first. Progress reporting. Sandboxed workers (run job processor in separate Node.js process for isolation).

### Known Limitations
- Redis dependency.
- No transactional enqueue with application database.
- Flow system is parent-child trees, not arbitrary DAGs.
- Dashboard ecosystem fragmented (multiple community options, no official).
- Pro features require commercial license for group-based rate limiting.

---

## 10. Graphile Worker (Node.js)

**Storage:** PostgreSQL
**Polling model:** Push. LISTEN/NOTIFY for near-instant notification.
**Multi-node safety:** `FOR UPDATE SKIP LOCKED` for row-level locking. Run-once guarantee.

### Worker/Job Definition

```typescript
// tasks/send_email.ts
const task: Task = async (payload, helpers) => {
  const { to, subject } = payload;
  await sendEmail(to, subject);
};
export default task;

// Enqueue from anywhere (even SQL):
// SELECT graphile_worker.add_job('send_email', json_build_object('to', 'user@example.com'));
```

### Scheduling
- **Delayed:** `run_at` parameter for future execution
- **Cron:** Via `graphile-scheduler` companion or `parseCronItems` in code

### Retry/Backoff
- Exponential backoff: `exp(least(10, attempt_count)) seconds` approximately
- Default max attempts: 25
- Customizable per task via `maxAttempts`

### Concurrency Control
- `concurrency` per worker pool (how many tasks run simultaneously in one Node process)
- No global concurrency controls across processes
- Horizontal scaling: run multiple worker processes

### Job Dependencies/Workflows
- No built-in workflow/DAG support. Enqueue next job from within task completion.

### Batch Processing
- `addJob` in bulk via SQL. No batch tracking.

### Dashboard/UI
- No built-in dashboard. Query the `graphile_worker.jobs` table directly.

### Observability
- Task events/hooks
- Standard Node.js logging
- Direct SQL queries against job tables

### Unique Jobs
- `jobKey` and `jobKeyMode`: prevent duplicate jobs. Modes: `replace` (update existing), `preserve_run_at` (keep original schedule), `unsafe_dedupe`.

### Rate Limiting
- No built-in.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- No built-in. Separate schemas achievable manually.

### Standout Feature
- Ultra-low latency: <3ms from enqueue to execution start. 99,600 jobs/sec enqueue throughput on 12-core DB. SQL API means any language can enqueue (even database triggers). Truly zero-infrastructure overhead -- just your existing Postgres.

### Known Limitations
- Very minimal feature set. No dashboard. No workflows. No rate limiting.
- Node.js only for workers.
- Small team/community compared to BullMQ.
- No built-in batch tracking or workflow orchestration.

---

## 11. Quartz (Java)

**Storage:** In-memory (RAMJobStore) or JDBC (any RDBMS)
**Polling model:** Internal scheduler thread + worker thread pool. Not a traditional job queue -- it's a scheduler.
**Multi-node safety:** JDBC JobStore with database row locks. Clustered mode with failover recovery.

### Worker/Job Definition

```java
public class EmailJob implements Job {
    @Override
    public void execute(JobExecutionContext context) throws JobExecutionException {
        String to = context.getJobDetail().getJobDataMap().getString("to");
        sendEmail(to);
    }
}

JobDetail job = JobBuilder.newJob(EmailJob.class)
    .withIdentity("email1", "group1")
    .usingJobData("to", "user@example.com")
    .build();
```

### Scheduling
- **Trigger types:**
  - `SimpleTrigger`: one-time or fixed-interval repeat
  - `CronTrigger`: full cron expressions
  - `CalendarIntervalTrigger`: every N weeks/months/years
  - `DailyTimeIntervalTrigger`: every N hours between time-of-day window
- Separates Job (what) from Trigger (when) -- very flexible composition.

### Retry/Backoff
- No automatic retry. Must implement in `execute()` method.
- `requestsRecovery` flag: if node fails, job re-executes on another node.
- Misfire instructions per trigger type (fire immediately, discard, reschedule).

### Concurrency Control
- Thread pool size per scheduler instance
- `@DisallowConcurrentExecution` annotation: prevents same JobDetail from running concurrently across cluster
- No rate limiting

### Job Dependencies/Workflows
- No built-in workflow/DAG. Must implement via job listeners and trigger chaining.

### Batch Processing
- No built-in batch concept.

### Dashboard/UI
- No built-in dashboard. Community: QuartzDesk (commercial), CrystalQuartz (open source panel).

### Observability
- `JobListener` and `TriggerListener` interfaces for lifecycle hooks
- `SchedulerListener` for scheduler events
- JMX integration
- Logging via SLF4J

### Unique Jobs
- Job identity (name + group) is naturally unique in the scheduler.

### Rate Limiting
- No built-in.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- No built-in. Run separate scheduler instances per tenant.

### Standout Feature
- The most mature scheduler in the JVM ecosystem (20+ years). Separating Job from Trigger is a powerful abstraction. Trigger types handle complex calendar-based scheduling that most job queues cannot. JDBC clustering with automatic failover and misfire recovery.

### Known Limitations
- Primarily a scheduler, not a job queue. No concept of enqueuing work from application code in the way Sidekiq/Oban work.
- No automatic retry/backoff.
- No built-in dashboard.
- API is verbose and dated.
- No workflows, batches, rate limiting, or modern job queue features.
- Scaling is limited by database lock contention.

---

## 12. JobRunr (Java)

**Storage:** RDBMS (Postgres, MySQL, Oracle, SQL Server, SQLite, DB2) or MongoDB
**Polling model:** Polling. BackgroundJobServer polls storage at configurable interval.
**Multi-node safety:** Optimistic locking on job table. Single execution guarantee.

### Worker/Job Definition

```java
// Fire and forget
BackgroundJob.enqueue(() -> emailService.send("user@example.com"));

// Delayed
BackgroundJob.schedule(Instant.now().plusHours(1),
    () -> emailService.send("user@example.com"));

// Recurring
BackgroundJob.scheduleRecurrently("email-digest", Cron.daily(8),
    () -> digestService.sendDailyDigest());
```

Uses Java 8 lambdas -- captures the method reference and serializes it as JSON. No special worker class needed.

### Scheduling
- **Delayed:** `BackgroundJob.schedule(instant, lambda)`
- **Recurring:** `Cron.daily()`, `Cron.weekly()`, or cron expressions. Unlimited in Pro.

### Retry/Backoff
- Default: 10 retries with exponential backoff (smart back-off policy)
- Configurable per-job via `@Job(retries = N)` annotation
- Pro: custom RetryPolicy per job type

### Concurrency Control
- `workerCount` per server instance
- Pro: Dynamic Queues for fair-use distribution across tenants
- No global concurrency limits in OSS

### Job Dependencies/Workflows
- No built-in workflow/DAG support in OSS.
- Pro: Job Chaining for sequential execution.

### Batch Processing
- Pro: Batch jobs. Pro v8.5.0 added Recurring Batch Jobs.

### Dashboard/UI
- Built-in (embedded web server on port 8000).
- Pages: Overview (enqueued count, processing estimate), Enqueued, Scheduled, Processing, Succeeded, Failed, Deleted, Recurring Jobs.
- Actions: requeue, delete jobs. Trigger recurring jobs manually.
- Pro: advanced filters, job history, retry with single click, audit logging (v8.5.0+), confirmation dialogs for destructive actions, multi-cluster dashboard.
- Dark theme in Pro.

### Observability
- SLF4J logging
- Micrometer metrics integration
- Dashboard provides visual monitoring
- Pro: audit logging of all dashboard actions

### Unique Jobs
- No built-in unique job support.

### Rate Limiting
- No built-in rate limiting.
- Pro: Dynamic Queues provide fair-use guarantees across tenants.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- Pro: Dynamic Queues guarantee fair processing across tenants. Tenant queues are created dynamically. Dashboard shows per-queue view.

### Standout Feature
- Lambda-based API is the simplest job definition of any system. No special worker class, no serialization concerns. Just write a method call and JobRunr captures + serializes it. Works with any IoC container (Spring, Micronaut, Quarkus). The dashboard is built-in and available without external dependencies.

### Known Limitations
- Polling-based (no LISTEN/NOTIFY), so latency depends on poll interval.
- Lambda serialization can be fragile (method signature changes break deserialization).
- No built-in unique jobs or rate limiting.
- Many features Pro-only ($500-$2000/yr).
- Smaller community than Quartz.

---

## 13. Apalis (Rust)

**Storage:** Redis, PostgreSQL, SQLite, MySQL, in-memory (pluggable backends)
**Polling model:** Backend-dependent. Stream-based architecture: anything implementing `Stream` can be a job source.
**Multi-node safety:** Backend-dependent. Postgres uses row locks. Redis uses atomic operations.

### Worker/Job Definition

```rust
#[derive(Debug, Serialize, Deserialize)]
struct Email {
    to: String,
    subject: String,
}

async fn send_email(job: Email, ctx: JobContext) -> Result<(), Error> {
    mailer::send(&job.to, &job.subject).await?;
    Ok(())
}

// Register
Monitor::new()
    .register(WorkerBuilder::new("email-worker")
        .layer(RetryLayer::new(5))
        .backend(postgres_backend)
        .build_fn(send_email))
    .run()
    .await;
```

Macro-free API. Tower service model.

### Scheduling
- **Delayed:** schedule_at on job insertion
- **Cron:** `apalis-cron` crate. Cron expressions or natural language. Can persist to storage backend.

### Retry/Backoff
- Tower `RetryLayer` middleware. Configurable max retries.
- Custom retry logic via tower middleware.
- Timeout middleware available.

### Concurrency Control
- Per-worker concurrency via `WorkerBuilder`
- Tower `ConcurrencyLimit` middleware
- `LoadShed` middleware for overload protection

### Job Dependencies/Workflows
- Beta: "stepped tasks" for multi-step workflows.
- No built-in DAG/workflow engine.

### Batch Processing
- No built-in batch tracking.

### Dashboard/UI
- Optional web interface (basic). Prometheus metrics endpoint.
- Not comparable to Oban Web or Sidekiq UI in features.

### Observability
- Tower `tracing` middleware integration (OpenTelemetry compatible)
- Prometheus metrics layer
- Graceful shutdown support
- Comprehensive error reporting

### Unique Jobs
- No built-in unique jobs.

### Rate Limiting
- Tower `RateLimit` middleware.

### Encryption at Rest
- No built-in.

### Multi-tenancy
- No built-in.

### Standout Feature
- Tower middleware ecosystem integration. Composable middleware stack means you can add retry, tracing, rate limiting, concurrency control as layers. Runtime-agnostic (tokio, async-std). Multiple storage backends. Type-safe, zero-cost abstractions.

### Known Limitations
- Relatively young project. Smaller community.
- Dashboard is basic compared to established systems.
- Stepped tasks (workflows) are beta.
- Documentation is sparse.
- No unique jobs, encryption, or multi-tenancy built-in.

---

## Cross-System Comparison Matrix

| Feature | Sidekiq | GoodJob | Oban | River | Faktory | Celery | Dramatiq | ARQ | BullMQ | Graphile | Quartz | JobRunr | Apalis |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Storage** | Redis | Postgres | Postgres+ | Postgres | Redis | Broker+ | RabbitMQ/Redis | Redis | Redis | Postgres | RDBMS | RDBMS/Mongo | Multiple |
| **Txn Enqueue** | No | Yes | Yes | Yes | No | No | No | No | No | Yes | N/A | Yes | Depends |
| **Push/Poll** | Push | LISTEN/NOTIFY | LISTEN/NOTIFY | LISTEN/NOTIFY | Push | Push | Push | Poll | Push | LISTEN/NOTIFY | Internal | Poll | Stream |
| **Retry** | Exp(^4)+jitter | ActiveJob poly | Exp(^4) custom | Exp custom | Exp(^4)+jitter | Exp+jitter cfg | Exp min/max | Manual | Exp/fixed/custom | Exp | Manual | Exp smart | Tower middleware |
| **Cron** | Ent | Built-in | Built-in | Built-in | Ent | Beat (separate) | External | Built-in | Built-in | External | Core feature | Built-in | apalis-cron |
| **Workflows** | Pro batches | No | Pro DAG | Pro DAG | Ent batches | Canvas | Pipelines/Groups | No | Flows (tree) | No | No | Pro chains | Beta steps |
| **Batches** | Pro | Built-in | Pro | No | Ent | Groups | Groups | No | No | No | No | Pro | No |
| **Dashboard** | Built-in | Built-in | LiveView RT | React app | Built-in | Flower | Community | No | Community | No | Community | Built-in | Basic |
| **Unique Jobs** | Ent | Via concurrency | Built-in | Built-in | Ent | No | No | Built-in | Built-in | Built-in | Identity | No | No |
| **Rate Limit** | Ent | Throttle | Pro | Planned | No | Per-task | Built-in | No | Built-in | No | No | No | Tower MW |
| **Encryption** | Ent | No | Pro | No | No | No | No | No | No | No | No | No | No |
| **Multi-tenant** | No | No | Prefix/Dynamic | No | No | No | No | No | Pro groups | No | No | Pro queues | No |
| **Telemetry** | Middleware | AS::Notifications | Telemetry events | Subscriptions | Middleware | Signals | Middleware | Hooks | Events | Hooks | Listeners | Micrometer | Tower tracing |

---

## Key Architectural Patterns Observed

### 1. Storage Backend Determines Character
- **Redis-based** (Sidekiq, BullMQ, ARQ): highest throughput, lowest latency, but no transactional enqueue and durability concerns.
- **Postgres-based** (GoodJob, Oban, River, Graphile): transactional enqueue is the killer feature. LISTEN/NOTIFY provides near-Redis latency. ACID guarantees. Trade: lower ceiling on raw throughput.
- **Broker-based** (Celery, Dramatiq): most flexible topology but most complex infrastructure.

### 2. Transactional Enqueue is Transformative
Postgres-based systems can atomically commit a database change AND enqueue a job. This eliminates entire classes of distributed systems bugs:
- No "committed but job lost" scenarios
- No "job ran but commit failed" scenarios
- Oban's `Ecto.Multi`, GoodJob's `perform_later` in ActiveRecord transaction, River's `InsertTx` all leverage this.

### 3. LISTEN/NOTIFY is the Postgres Equalizer
Postgres-based systems using LISTEN/NOTIFY achieve sub-5ms enqueue-to-execution latency, making the "Postgres is slow for queuing" argument largely obsolete for typical workloads.

### 4. Commercial Features Cluster Around the Same Capabilities
Almost every system gates the same features behind commercial tiers:
- Global concurrency/rate limiting
- Workflows/DAGs
- Encryption at rest
- Batches with callbacks
- Unique jobs (though some include this in OSS)

### 5. Dashboard Quality Varies Enormously
- **Best:** Oban Web (real-time LiveView, composable filters, queue management, charts) and Sidekiq Web (battle-tested, comprehensive)
- **Good:** JobRunr (built-in, no deps), River UI (modern React), GoodJob (Rails engine)
- **Adequate:** Flower (Celery), bull-board, Faktory
- **Missing:** ARQ, Graphile Worker, Dramatiq, Quartz (need community/commercial additions)

### 6. Retry Strategies Have Converged
Most systems use exponential backoff with jitter. The Sidekiq formula (`attempt^4 + 15 + rand(10) * (attempt+1)`) has been influential. Key differentiator is whether backoff is customizable per-worker and whether the system acks-on-receive (dangerous default in Celery) or acks-on-completion (Dramatiq's philosophy, Oban, GoodJob).

### 7. Unique Jobs Implementation Varies
- **Database constraint** (Oban, River, Graphile): strongest guarantee, enforced at insert time
- **Redis lock** (Sidekiq Enterprise, BullMQ): fast but can have edge cases during Redis failover
- **Advisory lock** (GoodJob): uses Postgres advisory locks with concurrency controls
- **Job ID** (ARQ, BullMQ): application-provided idempotency key

---

## Lessons for Erlang/OTP Job Queue Design

1. **Postgres + LISTEN/NOTIFY** is the proven architecture for BEAM-based systems (Oban validates this).

2. **Telemetry events** at every lifecycle point (enqueue, start, stop, exception, retry) are table stakes.

3. **Transactional enqueue** should be a first-class feature, not an afterthought.

4. **Unique jobs** should be built into OSS with configurable fields, period, and states.

5. **Retry backoff** should be exponential by default with a per-worker customization callback.

6. **Cron** should be leader-elected with no duplicate scheduling across nodes.

7. **Dashboard** should be real-time (WebSocket/LiveView equivalent), not polling-based.

8. **Rate limiting** and **global concurrency** are the most requested "Pro" features across all ecosystems.

9. **Workflow/DAG** support is increasingly expected but can start as a Pro feature.

10. **Encryption at rest** for sensitive job args is a differentiator that few systems offer.

11. **Multi-tenancy** via schema prefixes or dynamic repos maps naturally to Postgres capabilities.

12. **Queue pause/resume/scale** at runtime (locally and globally) is expected operational capability.

---

## Sources

### Sidekiq
- [Sidekiq GitHub](https://github.com/sidekiq/sidekiq)
- [Sidekiq Official Site](https://sidekiq.org/)
- [Sidekiq Error Handling Wiki](https://github.com/sidekiq/sidekiq/wiki/Error-Handling)
- [Sidekiq Capsules Documentation](https://github.com/sidekiq/sidekiq/blob/main/docs/capsule.md)
- [Sidekiq Enterprise Rate Limiting](https://github.com/sidekiq/sidekiq/wiki/Ent-Rate-Limiting)
- [Sidekiq Enterprise Encryption](https://github.com/sidekiq/sidekiq/wiki/Ent-Encryption)
- [Sidekiq Enterprise Features](https://sidekiq.org/products/enterprise/)
- [Sidekiq Deep Dive](https://railsdrop.com/2025/06/06/sidekiq-deep-dive-the-ruby-background-job-processor-that-powers-modern-rails-applications/)
- [Sidekiq Retry Backoff Formula](https://gist.github.com/marcotc/39b0d5e8100f0f4cd4d38eff9f09dcd5)

### GoodJob
- [GoodJob GitHub](https://github.com/bensheldon/good_job)
- [GoodJob Better Stack Guide](https://betterstack.com/community/guides/scaling-ruby/goodjob-background-jobs/)
- [GoodJob v4 Introduction](https://island94.org/2024/07/introducing-goodjob-v4)
- [GoodJob, Solid Queue, Sidekiq in 2026](https://island94.org/2026/01/goodjob-solid-queue-sidekiq-active-job-in-2026)
- [Ruby Queue History - River Blog](https://riverqueue.com/blog/ruby-queue-history)

### Oban
- [Oban GitHub](https://github.com/oban-bg/oban)
- [Oban HexDocs](https://hexdocs.pm/oban/Oban.html)
- [Oban Pro Overview](https://oban.pro/docs/pro/overview.html)
- [Oban Unique Jobs](https://hexdocs.pm/oban/unique_jobs.html)
- [Oban Telemetry](https://hexdocs.pm/oban/Oban.Telemetry.html)
- [Oban Web GitHub](https://github.com/oban-bg/oban_web)
- [Oban Isolation (Multi-tenancy)](https://hexdocs.pm/oban/isolation.html)
- [OSS Oban Web and Oban v2.19](https://oban.pro/articles/oss-web-and-new-oban)

### River
- [River Official Site](https://riverqueue.com/)
- [River GitHub](https://github.com/riverqueue/river)
- [River Blog - Announcing River](https://riverqueue.com/blog/announcing-river)
- [River Pro](https://riverqueue.com/pro)
- [River UI GitHub](https://github.com/riverqueue/riverui)
- [River Concurrency Limits](https://riverqueue.com/docs/pro/concurrency-limits)
- [River Workflows](https://riverqueue.com/docs/pro/workflows)
- [River by Brandur](https://brandur.org/river)

### Faktory
- [Faktory GitHub](https://github.com/contribsys/faktory)
- [Faktory Official Site](https://contribsys.com/faktory/)
- [Faktory Enterprise Unique Jobs](https://github.com/contribsys/faktory/wiki/Ent-Unique-Jobs)
- [Faktory Enterprise Cron](https://github.com/contribsys/faktory/wiki/Ent-Cron)

### Celery
- [Celery Documentation](https://docs.celeryq.dev/)
- [Celery GitHub](https://github.com/celery/celery)
- [Celery Canvas Workflows](https://docs.celeryq.dev/en/stable/userguide/canvas.html)
- [Celery Tasks Documentation](https://docs.celeryq.dev/en/stable/userguide/tasks.html)
- [Flower GitHub](https://github.com/mher/flower)

### Dramatiq
- [Dramatiq Motivation](https://dramatiq.io/motivation.html)
- [Dramatiq Feature Comparison](https://groups.io/g/dramatiq-users/topic/task_queue_feature_comparison/80541067)

### ARQ
- [ARQ Documentation](https://arq-docs.helpmanual.io/)
- [ARQ GitHub](https://github.com/python-arq/arq)
- [ARQ vs Celery](https://leapcell.io/blog/celery-versus-arq-choosing-the-right-task-queue-for-python-applications)

### BullMQ
- [BullMQ Documentation](https://docs.bullmq.io/)
- [BullMQ Official Site](https://bullmq.io/)
- [BullMQ GitHub](https://github.com/taskforcesh/bullmq)
- [BullMQ Flows](https://docs.bullmq.io/guide/flows)
- [BullMQ Rate Limiting](https://docs.bullmq.io/bullmq-pro/groups/rate-limiting)

### Graphile Worker
- [Graphile Worker Site](https://worker.graphile.org/)
- [Graphile Worker GitHub](https://github.com/graphile/worker)
- [Graphile Worker Docs](https://worker.graphile.org/docs)

### Quartz
- [Quartz Scheduler Official](https://www.quartz-scheduler.org/)
- [Quartz JDBC Clustering](https://www.quartz-scheduler.org/documentation/quartz-2.3.0/configuration/ConfigJDBCJobStoreClustering.html)
- [Quartz on Baeldung](https://www.baeldung.com/quartz)

### JobRunr
- [JobRunr Official Site](https://www.jobrunr.io/en/)
- [JobRunr GitHub](https://github.com/jobrunr/jobrunr)
- [JobRunr Dashboard Docs](https://www.jobrunr.io/en/documentation/background-methods/dashboard/)
- [JobRunr Pro](https://www.jobrunr.io/en/pro/)
- [JobRunr Multi-Cluster Dashboard](https://www.jobrunr.io/en/documentation/pro/jobrunr-pro-multi-dashboard/)

### Apalis
- [Apalis GitHub](https://github.com/geofmureithi/apalis)
- [Apalis Crate](https://crates.io/crates/apalis)
- [Apalis Cron GitHub](https://github.com/apalis-dev/apalis-cron)
- [Apalis Docs.rs](https://docs.rs/apalis)
