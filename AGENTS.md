# AGENTS.md

Working agreement for agents and contributors on **shigoto** (仕事, "work") -
PostgreSQL-backed background job processing for Erlang. Jobs live in Postgres
and are claimed with `FOR UPDATE SKIP LOCKED`, so any node with the DB pool is a
worker: no Redis, no external broker, no coordination. A small OTP library on
[pgo](https://github.com/erleans/pgo) + [telemetry](https://hex.pm/packages/telemetry)
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
- **Batch atomicity.** Batch completed/discarded counters are updated inside a
  transaction; the completion callback fires exactly once. Keep count updates
  and state transitions in one transaction.
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
rebar3 ct                   # core / features / integration CT suites (needs DB)
rebar3 dialyzer
rebar3 lint                 # rebar3_lint (elvis)
rebar3 hank                 # dead-code; ignores worker + middleware behaviours
rebar3 fmt                  # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 ex_doc               # fix every new warning
```

Migrations are not hand-written. `shigoto_migration:up/Pool` runs the versioned,
idempotent statement sets (`v1..v5`) against a pgo pool; `down/1` drops the
tables, trigger, and notify function. Edit the versioned statements in
`shigoto_migration.erl`, never scatter DDL elsewhere.

## Pre-push checklist

`fmt --check` -> `xref` -> `dialyzer` -> `lint` -> `hank` -> `eunit` -> `ct`
(against Docker Postgres) -> `ex_doc`, all green. CI (`Taure/erlang-ci` ci.yml
`@v2.0.9`) runs ct, ex_doc, hank, coverage, elp-lint, sbom + sbom-scan, and
dependency submission; `elp-eqwalize` and `audit` are disabled for this repo, so
do not rely on them locally either. Every push to `main` runs release.yml.

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

- **Enqueue.** `shigoto:insert/1,2` -> `shigoto_repo:insert_job` in the app's own
  pgo pool (transactional with the caller's work). An `AFTER INSERT` trigger
  emits `NOTIFY shigoto_jobs_insert`.
- **Dequeue.** Each `shigoto_queue` polls every `poll_interval`, claims up to
  `concurrency - active` jobs via `FOR UPDATE SKIP LOCKED` (ROW_NUMBER subquery
  wrapped in an outer locking select), and starts one monitored executor per
  job under `shigoto_executor_sup`. Weighted / fair (partition-key) claiming and
  pause/resume live here.
- **Retry / backoff.** On error, timeout, or crash the executor records a
  structured failure and reschedules: `retryable -> available`. Delay is the
  worker's `backoff/2` or the default `min(round(Attempt^4) + jitter(1..30),
  1800)` seconds. At `max_attempts` the job is `discarded` and `on_discard/2`
  fires. `{snooze, Secs}` reschedules without consuming an attempt.
- **Notify + polling fallback.** `shigoto_notifier` LISTENs via
  `pgo_notifications`, pokes the matching queue to `poll` immediately, and
  reconnects on drop; the timed poll loop always runs underneath it.
- **Batches.** `shigoto_batch` groups jobs, tracks completed/discarded counts
  transactionally, and runs a callback worker on completion.
- **Cron.** `shigoto_cron` uses `pg_try_advisory_xact_lock` so one node owns
  scheduling; it catches up on intervals missed during downtime.
- **Stale rescue.** Heartbeats + a per-queue `rescue` tick re-queue zombie jobs
  whose owner died (threshold `heartbeat_interval * 2`).
- **Resilience** (via seki): per-worker rate limit, circuit breaker, local +
  global (Postgres advisory) bulkhead concurrency, and CoDel load shedding.

## Gotchas

- `pgo` is structurally the right driver here (caller-driven I/O + ETS-holder
  pool, ships `pgo_notifications`). Do not propose a pgo -> X swap without first
  benchmarking the candidate on a real insert/claim/complete loop; the last such
  attempt (epgsql+hnc, 2026-05) measured 6-38% slower and was abandoned.
- CT suites need Docker Postgres (`:5556`); they exercise the real locking and
  transactions - do not stub the DB out of them.
- `enable-elp-eqwalize` is off in CI; if you add eqwalizer specs, do not let
  OTP behaviour result types panic the checker - hand-roll local types.
- `insert` returns `{ok, {conflict, Job}}` for unique-conflict debounce/replace,
  not an error. Handle the conflict tuple.

## Tests

`test/` holds three CT suites (`shigoto_core_SUITE`, `shigoto_features_SUITE`,
`shigoto_integration_SUITE`), a bench suite (`shigoto_bench_SUITE`), the eunit
`shigoto_cron_parser_tests`, and small `*_worker.erl` fixtures. Add or update
tests alongside every change. Use `shigoto:drain_queue/1,2` for deterministic
synchronous processing in tests. Keep the fixture workers minimal.

## Git and PRs

Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
Always branch and open a PR - never push to `main`. No `Co-Authored-By` trailer
and no "Generated with Claude Code" branding on any commit or PR. Every merge to
`main` tags a release via `Taure/erlang-ci` release.yml, so keep each PR
coherent.
