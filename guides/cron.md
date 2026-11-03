# Cron Scheduling

Shigoto includes a built-in cron scheduler that checks configured entries every
minute and inserts jobs for matching schedules. Each minute is scheduled once
across all nodes, and a run missed while the nodes were down (up to 60 minutes
back) is caught up on the first pass after they start.

## Configuration

### Erlang (sys.config)

```erlang
{shigoto, [
    {pool, my_app_db},
    {cron, [
        {<<"daily_cleanup">>, <<"0 2 * * *">>, cleanup_worker, #{<<"days">> => 30}},
        {<<"hourly_sync">>, <<"0 * * * *">>, sync_worker, #{}},
        {<<"weekday_report">>, <<"30 9 * * 1-5">>, report_worker, #{}}
    ]}
]}
```

### Elixir (config.exs)

```elixir
config :shigoto,
  pool: :my_app_db,
  cron: [
    {"daily_cleanup", "0 2 * * *", :cleanup_worker, %{"days" => 30}},
    {"hourly_sync", "0 * * * *", :sync_worker, %{}},
    {"weekday_report", "30 9 * * 1-5", ReportWorker, %{}}
  ]
```

Each cron entry is a 4-tuple `{Name, Schedule, Worker, Args}` or a 5-tuple
`{Name, Schedule, Worker, Args, Opts}` where `Opts` is a map.

| Field | Type | Description |
|-------|------|-------------|
| Name | binary | Unique identifier; the key its last run is stored under |
| Schedule | binary | 5-field cron expression |
| Worker | module | Worker implementing `shigoto_worker` |
| Args | map | Args map passed to `perform/1` |
| Opts | map | Optional. Supports `timezone` (see below) |

## Timezones

By default schedules are matched against UTC. Set a `timezone` in the entry's
`Opts` map to match against a local wall-clock time instead:

```erlang
{cron, [
    %% 09:00 Stockholm time, DST-aware, every weekday
    {<<"morning_report">>, <<"0 9 * * 1-5">>, report_worker, #{},
        #{timezone => <<"Europe/Stockholm">>}},
    %% fixed offset, no DST
    {<<"utc_plus_2">>, <<"0 3 * * *">>, sync_worker, #{}, #{timezone => 2}}
]}
```

`timezone` accepts:

| Value | Example | DST |
|-------|---------|-----|
| `utc` (default) | `utc` | n/a |
| integer hour offset | `2`, `-5` | no |
| `"+/-N"` or `"UTC"` binary | `<<"+2">>` | no |
| named IANA zone | `<<"Europe/Stockholm">>` | yes |

Named IANA zones are resolved against the operating system's time zone database
(`$TZDIR` or `/usr/share/zoneinfo`) for each instant, so daylight-saving
transitions are handled automatically. If a named zone cannot be resolved the
entry falls back to UTC and a warning is logged.

## Cron Expression Syntax

Standard 5-field format: `minute hour day-of-month month day-of-week`

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31)
│ │ │ ┌───────────── month (1-12)
│ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
│ │ │ │ │
* * * * *
```

| Syntax | Description | Example |
|--------|-------------|---------|
| `*` | Any value | `* * * * *` (every minute) |
| `N` | Exact value | `30 * * * *` (at minute 30) |
| `N-M` | Range | `0 9-17 * * *` (hours 9 through 17) |
| `*/N` | Step | `*/15 * * * *` (every 15 minutes) |
| `N-M/S` | Step within range | `0-30/10 * * * *` (minutes 0, 10, 20, 30) |
| `N,M,O` | List | `0,15,30,45 * * * *` (specific minutes) |

## Missed Cron Catch-Up

Each pass stores, per entry, the minute it was scheduled up to
(`last_scheduled_at` in the `shigoto_cron` table). The next pass considers only
the minutes after it, up to 60 of them, and inserts one job if any of those
minutes match the schedule. So a tick that runs late, a restart, or downtime of
up to an hour still schedules the missed run, once. An entry seen for the first
time starts from the current minute and is not backfilled.

The current minute is read from PostgreSQL (`date_trunc('minute', now())`), not
from the node, so nodes whose clocks disagree still agree on the minute. The
stored `last_scheduled_at` only ever moves forward: a pass never sets it to an
earlier minute than the one already stored. A stored minute ahead of the
database's is logged as `shigoto_cron_last_run_in_future`; one more than 60
minutes ahead is put back to the current minute, so it cannot stop the entry
until that time comes.

## How It Works

1. `shigoto_cron` runs a pass at the start of every minute, in a transaction
   that takes `pg_try_advisory_xact_lock`; a node that does not get the lock
   skips the pass, so one node schedules at a time
2. Due entries insert a job into the worker's `queue/0` (or `default`), with the
   worker's `priority/0` and `max_attempts/0`; the `shigoto_cron` row records
   the same three values
3. The job inserts and the new `last_scheduled_at` commit together, so a minute
   is never scheduled twice, even by two nodes. The pass runs in
   `shigoto:transaction/2`, so `job_inserted` telemetry fires after the commit
4. Jobs also use a 60-second unique constraint (`[worker, args]`, states
   `available` and `executing`), so a run still waiting is not queued again
5. Cron jobs follow the same retry, backoff, and pruning rules as regular jobs
6. Before the pass, each entry is checked: its schedule must parse, its args
   must encode as JSON, and its worker's `queue/0`, `priority/0` and
   `max_attempts/0` must fit the jobs table (a binary, and int4 integers). An
   entry that fails is skipped every pass until it is fixed, and the other
   entries are scheduled as usual. `[shigoto, cron, skipped]` telemetry fires
   on every pass; the `shigoto_cron_entry_skipped` warning is logged once per
   entry and reason on each node
7. A pass that fails is logged as `shigoto_cron_pass_failed` and retried on the
   next minute; `shigoto_cron:schedule_once/0` answers `{error, pass_failed}`
   for it

## Advisory locks

shigoto takes three transaction-scoped advisory locks (`pg_advisory_xact_lock`
and `pg_try_advisory_xact_lock`, single bigint key) on its database:

| Key | Held by | For |
|-----|---------|-----|
| `839274628` | `shigoto_cron` | one cron pass at a time |
| `839274629` | `shigoto_stager` | one staging pass at a time |
| `839274630` | `shigoto_migration:up/1` | one migration at a time |

Any session on the database can take these keys too, and a session holding the
cron or stager key stops that work on every node. Do not use them for anything
else. A node that finds the cron lock taken for 5 passes in a row while no node
schedules logs `shigoto_cron_lock_held_elsewhere`; the stager logs
`shigoto_stager_lock_held_elsewhere` after a minute of missed passes (at least
10). Each warning repeats hourly while the lock stays taken, and each emits
`[shigoto, leader_lock, unavailable]`. Find the holder with:

```sql
SELECT pid, usename, application_name, state, xact_start
FROM pg_locks JOIN pg_stat_activity USING (pid)
WHERE locktype = 'advisory' AND objid IN (839274628, 839274629);
```

## Timezone notes

Named zones resolve against the operating system's IANA database
(`/usr/share/zoneinfo`), so every node in a cluster should run a consistent
`tzdata` version. A zone that cannot be resolved (missing or corrupt tzdata)
falls back to UTC with a logged warning rather than failing.

Cron matches at minute granularity under at-least-once semantics: on a DST
fall-back the repeated wall-clock minute may match twice (unique-job de-dup
within the 60s window prevents a duplicate enqueue), and on a spring-forward the
skipped minute does not match. Schedule around 03:00 local to avoid the DST
window if exact-once firing at those minutes matters.
