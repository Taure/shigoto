# Changelog

## [unreleased]

### Bug Fixes

- Stop writing decrypted job args to the database in the clear
- Resolve dependencies atomically on fail, discard and cancel
- Claim retryable jobs once their backoff is over
- Keep one poll timer per queue however often it is woken
- Record a job's outcome only while its claim still holds
- Rescue a stale job once, and discard it when it is out of attempts
- Run a fanout job on every node without changing its row
- Stop the worker process when its job is cancelled or its run ends
- Count cancelled and discarded jobs in their batch
- Release the dependents of jobs cancelled by filter
- Have insert_all answer its jobs in the order given
- Accept any acyclic dependencies, and do not wait on finished jobs
- Fail a job whose worker module cannot be run
- Keep the table of set-up worker gates alive between jobs
- Fail the job when perform/1 returns something it should not
- Record failures by shape and bound the errors column
- Never wait for an advisory lock without a bound
- Check the worker a row names before decrypting or calling anything
- Make insert_all refuse what it cannot honour
- Rate limit notification wake-ups and name the channel per instance
- Count jobs in an unknown state without creating an atom
- Print only a caught class and reason as Class:Reason
- Tell a string that starts with enc: from a frame, and open before calling current
- Do not run a worker without the gates it declares when seki is not running
- Find a unique job across turning encryption on and dropping an old key
- Claim again when a job finishes while work is left
- Give a job's place in the load shedder back however its run ends
- Report a cancel only for a job that was cancelled
- Count a batch job in the statement that ends it
- Take a retried job out of its batch's discarded count
- Release a job waiting on a job that has already ended

### CI

- Run the suites on PostgreSQL 14 to 18 and hold the release on them
- Keep the data directory on the tmpfs on every PostgreSQL major

### Documentation

- Warn that shigoto writes errors itself, so encryption cannot cover it
- Describe the lifecycle suite and when a change needs a case in it
- Add a security guide and say exactly what encryption covers
- Add a security policy and a guide to upgrading from 1.10
- Keep SECURITY.md out of the generated docs

### Features

- Expose queue paused-status through the dashboard
- Let a job choose what it does when a dependency fails
- Bind ciphertexts to their column and worker with v2 frames
- Add shigoto:reencrypt/0,1 to rewrite stored values in the current format
- Write v2 frames by default
- Carry a context from the insert of a job to its runs

### Miscellaneous

- Relock to minato 1.1.6 and seki 0.5.0
- Pin the build plugins

### Performance

- Use the depends_on index when a finished job releases its dependents
- Validate dependencies without walking what they wait for

### Refactoring

- Type the executor registry reads and clear the elp lints
- Narrow batch ids to integers before counting them
- Read settings through typed readers
- Bring src to no eqwalizer errors

### Testing

- De-flake the stager case and cover the fail-to-discard dependency path
- Add a lifecycle suite that runs jobs through the real queue
- Add a suite for what a database writer or any connected role can do
- Write the bench numbers under the CT priv_dir
- Run the frame-like result and the missing-seki gate through the real queue
- Cover the backlog, the load shedder and a cancel of nothing in the lifecycle suite
- Bring the suites to no eqwalizer errors
- Schedule the traced cron entry until a pass is not skipped
- Make PostgreSQL refuse a write and drop every connection
- Run two nodes on one database
- Put the cron case's root context back in the cron case
- Run the lifecycle suite through PgBouncer in transaction mode

## [1.10.1] - 2026-11-08

### Bug Fixes

- Run jobs inside kura_sandbox (#69)

## [1.10.0] - 2026-11-06

### Features

- Cron, migration and kura-transaction fixes from the Nova Book review (#66)

## [1.9.13] - 2026-11-05

### Documentation

- Name Oban as the comparison and replace stale pgo references with minato (#67)

## [1.9.12] - 2026-08-26

### Miscellaneous

- Add the MIT licence file the README and app.src already declare (#61)

## [1.9.11] - 2026-08-11

### Miscellaneous

- Bump erlang-ci to v2.1.7 (#59)

## [1.9.10] - 2026-08-11

### Miscellaneous

- Minato 1.0.2 (#58)

## [1.9.9] - 2026-08-10

### Miscellaneous

- Minato ~> 1.0, which is the socket transport by default (#57)

## [1.9.8] - 2026-08-10

### Miscellaneous

- Minato ~> 0.18.10 for the prepared-statement fix (#56)

## [1.9.7] - 2026-08-06

### Miscellaneous

- Stop tracking generated documentation (#55)

## [1.9.6] - 2026-08-06

### Miscellaneous

- Minato 0.18.9 (#54)

## [1.9.5] - 2026-08-06

### Miscellaneous

- Minato 0.18.8 (#53)

## [1.9.4] - 2026-08-06

### Bug Fixes

- Drop the orphaned pgo lock entry (#52)

## [1.9.3] - 2026-08-06

### Miscellaneous

- Take every plugin from hex and drop the sbom fork (#51)

## [1.9.2] - 2026-08-06

### Miscellaneous

- Minato 0.18.5 (#50)

## [1.9.1] - 2026-08-05

### Bug Fixes

- Let cron retry the failure shapes minato has (#49)

## [1.9.0] - 2026-08-05

### Features

- Run on minato (#48)

## [1.8.0] - 2026-07-05

### Features

- DB-free testing ergonomics (perform_job, inline/manual modes, enqueue assertions) (#45)

## [1.7.0] - 2026-07-05

### Features

- Named IANA timezones with DST for cron schedules (#44)

## [1.6.0] - 2026-07-05

### Features

- Pass predecessor results to dependent jobs (workflow context) (#40)

## [1.5.0] - 2026-07-05

### Features

- Notify-on-due stager for scheduled/retryable jobs (#39)

## [1.4.1] - 2026-07-05

### Bug Fixes

- Make per-worker global concurrency limit atomic and off-by-one correct (#38)

## [1.4.0] - 2026-07-05

### Features

- Pool-less arities for cancel/retry (API consistency) (#37)

## [1.3.3] - 2026-07-05

### Documentation

- Document telemetry event contract and unique-jobs design (#36)

## [1.3.2] - 2026-07-05

### Bug Fixes

- Bound the archive table with a retention window (#33)

## [1.3.1] - 2026-07-05

### Bug Fixes

- Harden transactional enqueue (telemetry hole + pool option) (#34)

## [1.3.0] - 2026-07-05

### Features

- Add transactional enqueue API (#32)

## [1.2.3] - 2026-07-02

### Documentation

- Add AGENTS.md for AI tooling (#30)

## [1.2.2] - 2026-04-03

### Bug Fixes

- Auto-migrate shigoto tables on application start

## [1.2.1] - 2026-03-30

### Documentation

- Add fanout queues guide (#27)

## [1.2.0] - 2026-03-30

### Features

- Add fanout queue mode for broadcast delivery (#26)

## [1.1.0] - 2026-03-28

### Features

- Support repo config as alternative to pool (#25)

## [1.0.4] - 2026-03-26

### Bug Fixes

- Update rebar.lock (#23)

## [1.0.3] - 2026-03-26

### Miscellaneous

- Configure hex doc provider for ex_doc (#22)

## [1.0.2] - 2026-03-26

### Miscellaneous

- Disable eqWAlize CI check (#21)

## [1.0.1] - 2026-03-26

### Miscellaneous

- Remove eqwalizer_support for Hex compatibility (#20)

## [1.0.0] - 2026-03-26

### Bug Fixes

- Match return value from rescue_stale_jobs for dialyzer
- Match unmatched return values for dialyzer
- Simplify validate_step, clear stale cache
- Match case expression return for dialyzer
- Format executor_sup, remove unreachable pattern in notifier
- Resolve multiple shigoto issues
- Align CI compose port with test config (5556)
- Remove unused catch_up_entry Name argument (hank)
- Resolve ELP lint warnings, convert to sigil strings (#14)
- Resolve all 177 eqWAlizer errors, enable in CI (#15)
- Use upper_first in cliff template, restore CI permissions (#19)

### CI

- Upgrade erlang-ci to v2.0.0

### Documentation

- Add ex_doc guides for getting started, workers, and cron
- Add README
- Comprehensive README and new guides (#13)

### Features

- Initial shigoto library
- Add Docker Compose and integration tests
- Add cron expression parser with full 5-field syntax support
- Commit pending improvements (pgo direct, notifier, unique jobs, graceful shutdown)
- Seki resilience, batches, middleware, encryption, and 20+ features (#1)
- Resolve job dependencies on discard and cancel
- Cron leader election, aliases, docs, and fixes
- Encryption key rotation and global concurrency
- Enhanced telemetry with queue, resilience, and cron events
- Core improvements for production readiness (#12)
- Cron timezone, meta encryption, graceful cancellation (#16)

### Miscellaneous

- Add erlang-ci workflow and tool-versions
- Update erlang-ci ref to v1
- Switch CI to docker-compose for PostgreSQL
- Commit rebar.lock for reproducible builds and proper CI caching
- Add covertool plugin for CI coverage
- Switch seki from git dep to Hex (~> 0.4)
- Disable audit in CI, upgrade erlang-ci to v2.0.5 (#11)
- Add release workflow and cliff.toml for v1.0.0 (#18)

### Testing

- Add benchmark suite (#17)

