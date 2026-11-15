# Changelog

Generated from the commit history by [git-cliff](https://git-cliff.org), so an
edit made here is lost. To change it, regenerate it:

```
git cliff -o CHANGELOG.md
```

and commit the result as `chore(changelog): regenerate`, the last commit of
the pull request. CI fails a pull request whose file differs.

## [unreleased]

### Bug Fixes

- Stop sending unique fields on every node once none is stored in the clear
- Answer every refused insert without PostgreSQL's message and detail
- Cut the worker name in the errors entries a statement builds
- Keep looking for unique fields in the clear while the check fails
- Read a deps_results key as a job id in one place

### Documentation

- Describe row keys without naming a minato that is not released
- Say what an instance made invalid on a running node does
- Rewrap the insert_all/3 paragraph on unique locks
- Name the rebar3 and the Hex publishing main brought in

### Refactoring

- Write the empty key name with the binary sigil

### Testing

- Trace what a call sends to PostgreSQL from a module of its own
- Insert_all at exactly its unique lock limit and one above
- Name the tables whose columns have to be atoms

## [1.10.2] - 2026-11-15

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
- Cascade to a waiting job only while it still waits
- Do not replace or debounce a unique job that has left its states
- Archive a job in the statement that deletes it
- Give a job back when its node stops, without using an attempt
- Keep the heartbeat running until the queues and executors have stopped
- Run on_discard/2 in a process of its own, bounded in time and number
- Rescue and sweep once per node, one node at a time
- Have insert_all insert a unique job once instead of refusing it
- Refuse to migrate over an index whose concurrent build failed
- Leave a batch active when this node cannot run its callback
- Have a retried job wait again on the dependency it was ended for
- Refuse every invalid setting at boot, in one shape
- Stop putting a job back for ever when this node cannot run it
- Record an error perform/1 answered as the term it is
- Refuse a fanout job in a batch
- Leave fanout queues out of the stager's notifications
- Take a statement that ran as run, whatever its command tag
- Keep the notifier alive when its listener cannot subscribe
- Refuse to start when encryption is required and no key is set
- Read require_encrypted and instance to fail closed while the node runs
- Bound the advisory locks one insert_all call takes for its unique jobs
- Hand a job only the results of the jobs it was inserted to wait for
- Look for a unique job by its fields in the clear only while one is stored that way
- Refuse a result stored under a key that is no job id
- Cut a worker name that is longer than a module name can be
- Refuse unique states that are not job states
- Refuse the keys that belong to shigoto in meta and callback_args
- Bound the on_discard backlog by the size of its rows
- Warn at boot when a key is set and the workers are not listed
- Name every column of the shigoto tables where statements are sent
- Name what a job waits for in meta that was given as JSON text

### CI

- Run the suites on PostgreSQL 14 to 18 and hold the release on them
- Keep the data directory on the tmpfs on every PostgreSQL major
- Run eqwalizer on pull requests
- Mutate six modules on pull requests and fail below 88%
- Fail a pull request whose CHANGELOG.md is not the generated one

### Documentation

- Warn that shigoto writes errors itself, so encryption cannot cover it
- Describe the lifecycle suite and when a change needs a case in it
- Add a security guide and say exactly what encryption covers
- Add a security policy and a guide to upgrading from 1.10
- Keep SECURITY.md out of the generated docs
- Add a changelog generated by git-cliff
- Hide the plumbing and reserve the _shigoto prefix
- Lead the batch docs with one insert, and finish the upgrade table
- Say what waits for an on_discard callback in the upgrading guide
- Say that a cluster-wide rate limit can double during the deploy

### Features

- Expose queue paused-status through the dashboard
- Let a job choose what it does when a dependency fails
- Bind ciphertexts to their column and worker with v2 frames
- Add shigoto:reencrypt/0,1 to rewrite stored values in the current format
- Carry a context from the insert of a job to its runs

### Miscellaneous

- Relock to minato 1.1.6 and seki 0.5.0
- Pin the build plugins
- Publish to Hex with Workload Identity (#70)

### Performance

- Use the depends_on index when a finished job releases its dependents
- Validate dependencies without walking what they wait for

### Refactoring

- Type the executor registry reads and clear the elp lints
- Narrow batch ids to integers before counting them
- Read settings through typed readers
- Bring src to no eqwalizer errors
- Clear the eqwalizer errors and elp lints of the new code
- End the on_discard process by returning when its callback did
- Name a worker's seki limiter, bulkhead and breaker by a term
- Say the types of the new helpers where eqwalizer loses them

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
- Give the broken time zone file a directory of its own
- Cover the lock statements and what mutation testing found untested
- Read the remembered time as an integer
- Clear what hank reports in the test tree
- Listen for the start, stop and exception events in the leak probe

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

