-module(shigoto_config).
-moduledoc """
Configuration access for Shigoto. Reads from application env.
""".

-export([
    pool/0,
    queues/0,
    poll_interval/0,
    cron_entries/0,
    prune_after_days/0,
    shutdown_timeout/0,
    notifier_config/0,
    middleware/0,
    encryption_key/0,
    heartbeat_interval/0,
    load_shedding/0,
    queue_weights/0,
    fair_queues/0,
    encryption_keys/0
]).

-doc "The pgo pool name for job storage. Set via `{pool, Name}` in config. `repo` is supported for backward compatibility.".
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

-doc "Cron job entries. Each: `{Name, Schedule, Worker, Args}` or `{Name, Schedule, Worker, Args, #{timezone => Offset}}`.".
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
