# Cron Scheduling

Shigoto includes a built-in cron scheduler that checks configured entries every
minute and inserts jobs for matching schedules.

## Configuration

Add cron entries to your `sys.config`:

```erlang
{shigoto, [
    {pool, my_app_db},
    {queues, [{<<"default">>, 10}]},
    {cron, [
        {<<"daily_cleanup">>, <<"0 2 * * *">>, cleanup_worker, #{<<"days">> => 30}},
        {<<"hourly_sync">>, <<"0 * * * *">>, sync_worker, #{}},
        {<<"weekday_report">>, <<"30 9 * * 1-5">>, report_worker, #{}}
    ]}
]}
```

Each cron entry is a 4-tuple:

```erlang
{Name, Schedule, Worker, Args}
```

| Field | Type | Description |
|-------|------|-------------|
| `Name` | `binary()` | Unique identifier for the cron entry |
| `Schedule` | `binary()` | 5-field cron expression |
| `Worker` | `module()` | Worker module implementing `shigoto_worker` |
| `Args` | `map()` | Args map passed to the worker |

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

### Supported Syntax

| Syntax | Description | Example |
|--------|-------------|---------|
| `*` | Any value | `* * * * *` (every minute) |
| `N` | Exact value | `30 * * * *` (at minute 30) |
| `N-M` | Range | `0 9-17 * * *` (hours 9 through 17) |
| `*/N` | Step | `*/15 * * * *` (every 15 minutes) |
| `N-M/S` | Step within range | `0-30/10 * * * *` (minutes 0, 10, 20, 30) |
| `N,M,O` | List | `0,15,30,45 * * * *` (specific minutes) |

## Examples

```erlang
%% Every minute
<<"* * * * *">>

%% Every day at midnight
<<"0 0 * * *">>

%% Every hour at minute 0
<<"0 * * * *">>

%% Every 15 minutes
<<"*/15 * * * *">>

%% Weekdays at 9:30 AM
<<"30 9 * * 1-5">>

%% First day of every month at 3:00 AM
<<"0 3 1 * *">>

%% Every Monday and Friday at 6:00 PM
<<"0 18 * * 1,5">>

%% Every 5 minutes during business hours on weekdays
<<"*/5 9-17 * * 1-5">>
```

## How It Works

The `shigoto_cron` gen_server checks all configured cron entries once per
minute. When an entry's schedule matches the current UTC time, a job is
inserted into the `default` queue with the configured worker and args.

Jobs created by cron entries are regular Shigoto jobs -- they follow the same
retry, backoff, and pruning rules as manually inserted jobs.
