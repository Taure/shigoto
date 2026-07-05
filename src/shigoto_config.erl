-module(shigoto_config).
-moduledoc """
Configuration access for Shigoto. Reads from application env.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    pool/0,
    queues/0,
    poll_interval/0,
    stage_interval/0,
    testing_mode/0,
    cron_entries/0,
    prune_after_days/0,
    archive_after_days/0,
    shutdown_timeout/0,
    notifier_config/0,
    middleware/0,
    encryption_key/0,
    heartbeat_interval/0,
    load_shedding/0,
    queue_weights/0,
    fair_queues/0,
    encryption_keys/0,
    fanout_queues/0
]).

-doc "The pgo pool name for job storage. Set `repo` for Kura-based apps or `pool` for raw pgo.".
-spec pool() -> atom().
pool() ->
    case application:get_env(shigoto, repo) of
        {ok, Repo} ->
            Repo;
        undefined ->
            {ok, Pool} = application:get_env(shigoto, pool),
            Pool
    end.

-doc "Configured queue names and concurrency. Default: `[{<<\"default\">>, 10}]`.".
-spec queues() -> [{binary(), pos_integer()}].
queues() ->
    application:get_env(shigoto, queues, [{~"default", 10}]).

-doc "Poll interval in milliseconds. Default: 5000.".
-spec poll_interval() -> pos_integer().
poll_interval() ->
    application:get_env(shigoto, poll_interval, 5000).

-doc "Stager interval in milliseconds for surfacing newly-due scheduled/retryable jobs. Default: 1000.".
-spec stage_interval() -> pos_integer().
stage_interval() ->
    application:get_env(shigoto, stage_interval, 1000).

-doc """
Testing mode for `insert/1,2` and `insert_all/1,2`. Default: `disabled` (normal
production behaviour — jobs are persisted and run by queue workers).

`inline` executes each inserted job synchronously in the calling process and
keeps no database row; `manual` captures inserted jobs in a process-local buffer
for `m:shigoto_testing` assertions without persisting or executing them. Both are
strictly for tests: they change persistence, so arming them requires TWO keys —

```erlang
application:set_env(shigoto, testing, inline),          %% or manual
application:set_env(shigoto, testing_confirm_no_persistence, true).
```

A non-`disabled` `testing` value WITHOUT the confirmation key does NOT arm the
mode: it falls back to the real persisted path and logs an error, so a testing
config that leaks into production fails safe and loud rather than silently
dropping jobs.
""".
-spec testing_mode() -> disabled | inline | manual.
testing_mode() ->
    case application:get_env(shigoto, testing, disabled) of
        disabled ->
            disabled;
        Mode when Mode =:= inline; Mode =:= manual ->
            case application:get_env(shigoto, testing_confirm_no_persistence, false) of
                true ->
                    Mode;
                _ ->
                    ?LOG_ERROR(#{
                        msg => ~"shigoto_testing_mode_not_confirmed",
                        mode => Mode,
                        action =>
                            ~"falling back to persisted insert; set testing_confirm_no_persistence to arm"
                    }),
                    disabled
            end;
        Other ->
            ?LOG_ERROR(#{msg => ~"shigoto_invalid_testing_mode", value => Other}),
            disabled
    end.

-doc """
Cron job entries. Each is `{Name, Schedule, Worker, Args}` or
`{Name, Schedule, Worker, Args, #{timezone => Timezone}}`.

`Timezone` may be:
- `utc` (the default when omitted)
- an integer hour offset, e.g. `2` or `-5`
- a `"+/-N"` or `"UTC"` binary, e.g. `<<"+2">>`
- a named IANA zone, e.g. `<<"Europe/Stockholm">>`, resolved (with DST) for
  each instant against the operating system's time zone database
""".
-spec cron_entries() -> list().
cron_entries() ->
    application:get_env(shigoto, cron, []).

-doc "Days to keep completed/discarded jobs before archiving. Default: 14.".
-spec prune_after_days() -> pos_integer().
prune_after_days() ->
    application:get_env(shigoto, prune_after_days, 14).

-doc "Days to keep archived jobs before permanent deletion. Default: 90.".
-spec archive_after_days() -> pos_integer().
archive_after_days() ->
    application:get_env(shigoto, archive_after_days, 90).

-doc "Database connection config for LISTEN/NOTIFY. Returns `undefined` if not configured.".
-spec notifier_config() -> map() | undefined.
notifier_config() ->
    application:get_env(shigoto, notifier, undefined).

-doc "Milliseconds to wait for in-flight jobs during shutdown. Default: 15000.".
-spec shutdown_timeout() -> pos_integer().
shutdown_timeout() ->
    application:get_env(shigoto, shutdown_timeout, 15000).

-doc "Global middleware chain applied to all jobs. Default: [].".
-spec middleware() -> [shigoto_middleware:middleware()].
middleware() ->
    application:get_env(shigoto, middleware, []).

-doc "AES-256-GCM encryption key for job args/meta. Returns `undefined` if not configured.".
-spec encryption_key() -> binary() | undefined.
encryption_key() ->
    application:get_env(shigoto, encryption_key, undefined).

-doc "Heartbeat interval in milliseconds for executing jobs. Default: 30000.".
-spec heartbeat_interval() -> pos_integer().
heartbeat_interval() ->
    application:get_env(shigoto, heartbeat_interval, 30000).

-doc "Load shedding config. Default: undefined (disabled).".
-spec load_shedding() -> map() | undefined.
load_shedding() ->
    application:get_env(shigoto, load_shedding, undefined).

-doc "Queue weight config. Map of queue name to weight. Default: #{} (equal weight).".
-spec queue_weights() -> #{binary() => pos_integer()}.
queue_weights() ->
    application:get_env(shigoto, queue_weights, #{}).

-doc "Queues that use fair partition-based claiming. Default: [] (all use standard claiming).".
-spec fair_queues() -> [binary()].
fair_queues() ->
    application:get_env(shigoto, fair_queues, []).

-doc "Ordered list of encryption keys (newest first) for key rotation. Default: [].".
-spec encryption_keys() -> [binary()].
encryption_keys() ->
    application:get_env(shigoto, encryption_keys, []).

-doc """
Fanout queues — every node processes every job. Format:
`[{QueueName, Concurrency, Opts}]` where Opts may include
`window` (seconds, default 120). Default: [].
""".
-spec fanout_queues() -> [{binary(), pos_integer(), map()}].
fanout_queues() ->
    application:get_env(shigoto, fanout_queues, []).
