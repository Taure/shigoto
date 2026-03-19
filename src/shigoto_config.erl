-module(shigoto_config).
-moduledoc ~"""
Configuration access for Shigoto. Reads from application env.
""".

-export([
    pool/0,
    queues/0,
    poll_interval/0,
    cron_entries/0,
    prune_after_days/0,
    shutdown_timeout/0,
    notifier_config/0
]).

-doc "The pgo pool name for job storage.".
-spec pool() -> atom().
pool() ->
    {ok, Pool} = application:get_env(shigoto, pool),
    Pool.

-doc "Configured queue names and concurrency. Default: `[{<<\"default\">>, 10}]`.".
-spec queues() -> [{binary(), pos_integer()}].
queues() ->
    application:get_env(shigoto, queues, [{~"default", 10}]).

-doc "Poll interval in milliseconds. Default: 5000.".
-spec poll_interval() -> pos_integer().
poll_interval() ->
    application:get_env(shigoto, poll_interval, 5000).

-doc "Cron job entries. Each: `{Name, Schedule, Worker, Args}`.".
-spec cron_entries() -> list().
cron_entries() ->
    application:get_env(shigoto, cron, []).

-doc "Days to keep completed/discarded jobs. Default: 14.".
-spec prune_after_days() -> pos_integer().
prune_after_days() ->
    application:get_env(shigoto, prune_after_days, 14).

-doc "Database connection config for LISTEN/NOTIFY. Returns `undefined` if not configured.".
-spec notifier_config() -> map() | undefined.
notifier_config() ->
    application:get_env(shigoto, notifier, undefined).

-doc "Milliseconds to wait for in-flight jobs during shutdown. Default: 15000.".
-spec shutdown_timeout() -> pos_integer().
shutdown_timeout() ->
    application:get_env(shigoto, shutdown_timeout, 15000).
