# Cron Scheduling

Shigoto includes a built-in cron scheduler that checks configured entries every
minute and inserts jobs for matching schedules. On startup, it catches up on
any intervals missed while the node was down (up to 60 missed minutes).

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

Each cron entry is a 4-tuple: `{Name, Schedule, Worker, Args}`.

| Field | Type | Description |
|-------|------|-------------|
| Name | binary | Unique identifier |
| Schedule | binary | 5-field cron expression |
| Worker | module | Worker implementing `shigoto_worker` |
| Args | map | Args map passed to `perform/1` |

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

When the cron scheduler starts, it checks the `last_scheduled_at` for each
entry in the database. If any intervals were missed (e.g., the node was down),
it inserts jobs for up to 60 missed minutes. Jobs are deduplicated via unique
constraints to prevent double-execution.

## How It Works

1. `shigoto_cron` gen_server checks all entries once per minute
2. Matching entries trigger a job insert into the `default` queue
3. Jobs use a 60-second unique constraint to prevent duplicates
4. Cron jobs follow the same retry, backoff, and pruning rules as regular jobs
