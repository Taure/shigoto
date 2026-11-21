# Changelog

Generated from the commit history by [git-cliff](https://git-cliff.org), so an
edit made here is lost. To change it, regenerate it:

```
git cliff -o CHANGELOG.md
```

and commit the result as `chore(changelog): regenerate`, the last commit of
the pull request. CI fails a pull request whose file differs.

## [unreleased]

### CI

- Run CI weekly to catch dependency rot (#60)

## [1.11.0] - 2026-11-16

### Features

- Retries that run, fenced outcomes, dependency failure policy, opt-in v2 encryption frames, minato 1.2 (#71)

## [1.10.2] - 2026-11-15

### Miscellaneous

- Publish to Hex with Workload Identity (#70)

## [1.10.1] - 2026-11-08

### Bug Fixes

- Run jobs inside kura_sandbox (#69)

## [1.10.0] - 2026-11-06

### Documentation

- Describe shigoto on Hex as an Oban alternative and add a GitHub link

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

