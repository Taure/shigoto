# AGENTS.md

Working agreement for agents and contributors on **shigoto** (仕事, "work") -
PostgreSQL-backed background job processing for Erlang. Jobs live in Postgres
and are claimed with `FOR UPDATE SKIP LOCKED`, so any node with the DB pool is a
worker: no Redis, no external broker, no coordination. A small OTP library on
[minato](https://hex.pm/packages/minato) + [telemetry](https://hex.pm/packages/telemetry)
+ [seki](https://github.com/Taure/seki) (resilience). Bring your own app.

## Job-correctness scope (the pillars)

These invariants are load-bearing. Weakening any of them is a correctness
regression, not a refactor:

- **At-least-once + idempotent retry.** A claimed job that crashes or times out
  comes back. Delivery is at-least-once, so workers must be idempotent; retries
  re-run `perform/1`. Never design for exactly-once.
- **`FOR UPDATE SKIP LOCKED` claiming.** Each job is claimed by exactly one node
  with no cross-node coordination. The claim query (`shigoto_repo:claim_jobs/3`)
  is the heart of the system - do not replace the locking model.
- **Batch atomicity.** A batch counts a job in the statement that ends the job
  (`counted` in `complete_job/3`, `batch_counts` in `with_dependents/3`). The
  move out of `active` and the insert of the callback job are one transaction
  (`shigoto_batch:settle/2`), so the callback is enqueued exactly once. Never
  count in a statement of its own, never split the move from the insert.
- **Polling is the correctness backstop.** LISTEN/NOTIFY (`shigoto_notifier`) is
  a latency optimisation and is best-effort / at-most-once by the PG protocol.
  The per-queue polling loop MUST stay even when NOTIFY is wired up. Do not
  "drop polling now that notify works" - that is a 3am data-loss bug.
- **The worker behaviour is the extension seam.** `shigoto_worker` (one required
  callback `perform/1` + optional callbacks) is how consumers extend shigoto.
  New per-consumer job types, backoff shapes, or queue features belong behind
  the existing callbacks/config, not as pre-baked modules in core.

Architectural, queue-semantics, or scheduling changes go past the
**`shigoto-architecture-guardian`** agent before implementation - especially any
change driven by a single consumer (asobi, a specific app) or an Oban feature
port without Erlang-idiom adaptation.

## Commands

```bash
rebar3 compile
docker compose up -d        # Postgres 16 on :5556 (db shigoto_test, pw root)
rebar3 eunit                # shigoto_cron_parser_tests
rebar3 ct                   # CT suites, incl. the lifecycle suite on the real app (needs DB)
rebar3 dialyzer
elp lint                    # ELP lints (~/.local/bin/elp)
rebar3 hank                 # dead-code; ignores worker + middleware behaviours
rebar3 fmt                  # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 ex_doc               # fix every new warning
```

Migrations are not hand-written. `shigoto_migration:up/Pool` runs the versioned,
idempotent statement sets (`v1..v7`) against a minato pool and answers
`{error, Reason}` for the first one that fails. A new version is a new
`vN_statements/0` plus a bump of `?SCHEMA_VERSION`, which `up/1` records as the
comment on `shigoto_jobs` and checks to skip a current schema (a CT case fails
when the two disagree); `down/1` drops the
tables, trigger, and notify function. Edit the versioned statements in
`shigoto_migration.erl`, never scatter DDL elsewhere.

## Pre-push checklist

`fmt --check` -> `xref` -> `dialyzer` -> `elp lint` -> `hank` -> `eunit` ->
`ct` (against Docker Postgres) -> `ex_doc`, all green. Lint with `elp lint`;
there is no elvis config and no `rebar3_lint` plugin. CI (`Taure/erlang-ci`
ci.yml `@v2.1.7`) runs ct, ex_doc, hank, coverage, elp-lint, dependency
submission, and SBOM generation plus a Trivy scan of it (`rebar3_sbom`, the
Taure fork); `audit` and `elp-eqwalize` are disabled for this repo.
Every push to `main` runs release.yml.

## Conventions

- OTP 28+ (`.tool-versions`: erlang 28.4.1, rebar 3.26.0); README floor OTP 27+,
  PostgreSQL 9.5+.
- The `~"..."` sigil for binaries, never `<<"...">>` (see `shigoto_notifier`).
- No `lists:foldl/foldr` - list comprehensions + `maps:from_list`, or explicit
  named recursion. (`shigoto_queue`'s dispatch fold predates this; do not add
  new folds.)
- Logging: `?LOG_*` macros with `#{...}` map reports, never `logger:info/error`
  format strings.
- JSON: OTP `json` module, never thoas/jiffy.
- Docs: OTP `-moduledoc` / `-doc`; ex_doc guides under `guides/`.
- `{vsn, "git"}` in `shigoto.app.src` - version derives from git tags, never
  hand-edited. Do not publish to Hex (the maintainer does that manually).

## Architecture

```
shigoto_sup (one_for_one)
  ├─ shigoto_executor_sup   simple_one_for_one; one process per running job
  ├─ shigoto_queue_sup      one shigoto_queue gen_server per queue
  ├─ shigoto_cron           cron + leader election
  ├─ shigoto_pruner         hourly archive -> prune
  ├─ shigoto_heartbeat      periodic heartbeat writes
  └─ shigoto_notifier       LISTEN/NOTIFY wake-ups (optional)
```

- **Enqueue.** `shigoto:insert/1,2` -> `shigoto_repo:insert_job` on the
  configured minato pool. With `{repo, Repo}` that is the pool kura_postgres
  started for the repo, and `shigoto_db` joins a kura transaction open in the
  calling process (and opens `shigoto:transaction/1` through kura), so enqueue
  is transactional with the caller's kura writes. kura_postgres is an optional
  runtime integration, not a dependency. An `AFTER INSERT` trigger emits
  `NOTIFY shigoto_jobs_insert` (`shigoto_jobs_insert_<instance>` with
  `instance` set; `shigoto_migration:up/1` replaces the trigger function when
  the configured channel differs).
- **Dequeue.** Each `shigoto_queue` polls every `poll_interval`, claims up to
  `concurrency - active` jobs via `FOR UPDATE SKIP LOCKED` (the locking select
  runs once as `id = ANY(ARRAY(SELECT ... LIMIT n FOR UPDATE SKIP LOCKED))`;
  never `id IN (SELECT ...)`, whose semi join can rescan the subquery and claim
  past the limit), and starts one monitored executor per
  job under `shigoto_executor_sup`. Weighted / fair (partition-key) claiming and
  pause/resume live here.
- **Retry / backoff.** On error, timeout, or crash the executor records a
  structured failure and leaves the job `retryable` with `scheduled_at` at the
  end of its backoff; the claim takes due `available` and `retryable` jobs
  alike, so nothing has to promote it. Delay is the
  worker's `backoff/2` or the default `min(round(Attempt^4) + jitter(1..30),
  1800)` seconds. At `max_attempts` the job is `discarded` and `on_discard/2`
  fires. `{snooze, Secs}` reschedules and raises `max_attempts` by one, giving
  back the attempt the claim counted.
- **Executor.** One `shigoto_executor` per running job. It traps exits and
  runs `perform/1` in a linked process, so neither outlives the other.
  `shigoto_executor:stop/2` ends a run early (local cancel, or the heartbeat
  finding the claim gone); the supervisor's shutdown does the same. A stopped
  run writes nothing. Fanout jobs run unclaimed and never write to their row.
- **Notify + polling fallback.** `shigoto_notifier` LISTENs via a
  minato listener, pokes the matching queue to `poll`, and reconnects on drop;
  the timed poll loop always runs underneath it. A payload only names a queue;
  unknown names are dropped and a queue is poked at most once per
  `notify_min_interval`, since anyone who can connect can `NOTIFY`.
- **Batches.** `shigoto_batch` groups jobs and runs a callback worker when the
  last one ends. Counting is part of the job's own statement; `settle/2` then
  finishes a batch with a full count, and `settle_finished/1` on the rescue
  tick settles one a stopped node left `active`.
- **Cron.** `shigoto_cron` runs each pass in a transaction that takes
  `pg_try_advisory_xact_lock`, so one node schedules at a time, and stores each
  entry's `last_scheduled_at` in `shigoto_cron` in the same transaction, so a
  minute is scheduled once; it catches up on the last hour after downtime. The
  minute comes from PostgreSQL's clock and the stored minute only moves forward
  (`GREATEST` in the upsert), so node clock skew cannot reschedule a minute.
- **Dependencies.** A job with `depends_on` is not claimable until the array is
  empty. Completion removes the id and adds the result to `deps_results`. A
  dependency that is discarded or cancelled has failed: every statement that
  can fail a job (`fail_job`, `discard_job`, `cancel_job`, `cancel_by`, the
  rescue) ends in the same CTE tail (`with_dependents/2` in `shigoto_repo`),
  which walks the waiting jobs recursively and releases, cancels or discards
  each by its `on_dependency_failure` (job column, else the app default). A
  dependency already finished at insert is not waited for. Inserting cannot
  create a cycle (no id yet), so there is no cycle check.
- **Stale rescue.** Heartbeats + a per-queue `rescue` tick (`rescue_interval`)
  take back zombie jobs whose owner died (threshold `heartbeat_interval * 2`,
  claiming counts as the first heartbeat). A rescued job is re-queued, or
  discarded at `max_attempts` like a failed last attempt, so a job that kills
  its node cannot loop. Heartbeats and outcomes are fenced on `(id, attempt)`:
  a run whose job was rescued and claimed again writes nothing.
- **Resilience** (via seki): per-worker rate limit, circuit breaker, local +
  global (Postgres advisory) bulkhead concurrency, and CoDel load shedding.
  `shigoto_resilience:admit/2` runs the gates; a gate that raises or cannot
  take its lock snoozes the job. No gate fails open.
- **Rows are untrusted.** A row is data that anyone with write access to the
  table could have put there. `shigoto_job:worker/1` checks the worker name
  (existing atom, `workers` allow-list, exports `perform/1`) before
  `shigoto_job:opened/1` decrypts anything; never call into a module named by
  a row, or decrypt a column, any other way. Rows travel still encrypted
  (queue, executor state, telemetry); only the run sees plaintext. A job map
  goes into a log or error term through `shigoto_job:redact/1`, a failure
  reason through `shigoto_error`.
- **Encryption.** `shigoto_crypto:seal/2` and `open/2` take the context a value
  belongs to (`{args | meta | cron_args | callback_args, Worker}` or
  `{result, JobId}`). v2 frames (the default write format) are bound to it;
  v1 frames (`encryption_write_format` `v1`, for 1.10 nodes in a rolling
  deploy) are not. A value that does not
  open is an error, never passed on. `shigoto_reencrypt` rewrites stored
  values in the current format.
- **Advisory locks.** Every lock goes through `shigoto_lock`, which only uses
  `pg_try_advisory_xact_lock` with a bounded retry. Never add a blocking
  `pg_advisory_xact_lock`: any database role can hold any key forever.

## Gotchas

- The driver is minato (since "feat: run on minato", #48). Do not propose a
  driver swap without first benchmarking the candidate on a real
  insert/claim/complete loop.
- `shigoto_db` decodes rows as maps with atom keys. Match `#{rows := [#{col :=
  V}]}`, never tuple rows; tuple matches silently never match.
- CT suites need Docker Postgres (`:5556`, or set `SHIGOTO_TEST_DB_PORT`); they exercise the real locking and
  transactions - do not stub the DB out of them.
- `enable-elp-eqwalize` is off in CI; if you add eqwalizer specs, do not let
  OTP behaviour result types panic the checker - hand-roll local types.
- `insert` returns `{ok, {conflict, Job}}` for unique-conflict debounce/replace,
  not an error. Handle the conflict tuple.

## Tests

`test/` holds the CT suites (`shigoto_core_SUITE`, `shigoto_features_SUITE`,
`shigoto_integration_SUITE`, `shigoto_lifecycle_SUITE`, `shigoto_boot_SUITE`,
`shigoto_cron_SUITE`, `shigoto_kura_SUITE`), a bench suite
(`shigoto_bench_SUITE`), the eunit modules, and small `*_worker.erl` fixtures.
Add or update tests alongside every change. Use `shigoto:drain_queue/1,2` for
deterministic synchronous processing in tests. Keep the fixture workers minimal.

Most suites call `shigoto_repo` directly to move a job along. That proves the
statements, not the system: a queue that never claims `retryable` jobs passes
every one of them. `shigoto_lifecycle_SUITE` is the suite that runs the real
application (queue, executor, heartbeat, rescue, stager, notifier, pruner)
and only inserts a job and watches what happens to it. A change to how a job
moves between states needs a case there, written to fail first.
`shigoto_lifecycle_worker` reports each run to the test process and does what
it is told (`return`, `crash`, `die`), so a case controls a job from outside.

## Git and PRs

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
Always branch and open a PR - never push to `main`. No `Co-Authored-By` trailer
and no "Generated with Claude Code" branding on any commit or PR. Every merge to
`main` tags a release via `Taure/erlang-ci` release.yml, so keep each PR
coherent.
