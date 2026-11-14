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
    rescue_interval/0,
    on_dependency_failure/0,
    stale_after/0,
    load_shedding/0,
    queue_weights/0,
    fair_queues/0,
    encryption_keys/0,
    encryption_write_format/0,
    encryption_read_formats/0,
    require_encrypted/0,
    workers/0,
    instance/0,
    advisory_lock_timeout/0,
    notify_min_interval/0,
    notify_channel/0,
    fanout_queues/0,
    propagator/0,
    check/0
]).

-doc "The minato pool name for job storage. Set `repo` for Kura-based apps or `pool` for a pool of its own.".
-spec pool() -> atom().
pool() ->
    case application:get_env(shigoto, repo) of
        {ok, Repo} when is_atom(Repo) ->
            Repo;
        {ok, Repo} ->
            error({shigoto_config, {invalid, repo, Repo}});
        undefined ->
            case application:get_env(shigoto, pool) of
                {ok, Pool} when is_atom(Pool) -> Pool;
                {ok, Pool} -> error({shigoto_config, {invalid, pool, Pool}});
                undefined -> error({shigoto_config, {not_set, pool}})
            end
    end.

-doc "Configured queue names and concurrency. Default: `[{<<\"default\">>, 10}]`.".
-spec queues() -> [{Name :: term(), Concurrency :: term()}].
queues() ->
    case setting(queues, [{~"default", 10}]) of
        Queues when is_list(Queues) -> [Queue || {_Name, _Concurrency} = Queue <- Queues];
        Other -> error({shigoto_config, {invalid, queues, Other}})
    end.

-doc "Poll interval in milliseconds. Default: 5000.".
-spec poll_interval() -> pos_integer().
poll_interval() ->
    integer_setting(poll_interval, 5000).

-doc "Stager interval in milliseconds for surfacing newly-due scheduled/retryable jobs. Default: 1000.".
-spec stage_interval() -> pos_integer().
stage_interval() ->
    integer_setting(stage_interval, 1000).

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
    case setting(cron, []) of
        Entries when is_list(Entries) -> Entries;
        Other -> error({shigoto_config, {invalid, cron, Other}})
    end.

-doc "Days to keep completed/discarded jobs before archiving. Default: 14.".
-spec prune_after_days() -> pos_integer().
prune_after_days() ->
    integer_setting(prune_after_days, 14).

-doc "Days to keep archived jobs before permanent deletion. Default: 90.".
-spec archive_after_days() -> pos_integer().
archive_after_days() ->
    integer_setting(archive_after_days, 90).

-doc "Database connection config for LISTEN/NOTIFY. Returns `undefined` if not configured.".
-spec notifier_config() -> map() | undefined.
notifier_config() ->
    map_setting(notifier).

-doc "Milliseconds to wait for in-flight jobs during shutdown. Default: 15000.".
-spec shutdown_timeout() -> pos_integer().
shutdown_timeout() ->
    integer_setting(shutdown_timeout, 15000).

-doc "Global middleware chain applied to all jobs. Default: [].".
-spec middleware() -> [shigoto_middleware:middleware()].
middleware() ->
    [middleware(Middleware) || Middleware <- list_setting(middleware)].

%% What a fun answers cannot be known before it is called.
-spec middleware(term()) -> dynamic().
middleware(Middleware) when is_function(Middleware, 2) -> Middleware;
middleware(Other) -> error({shigoto_config, {invalid, middleware, Other}}).

-doc """
AES-256-GCM encryption key, exactly 32 bytes. Returns `undefined` if not
configured. `m:shigoto_crypto` says which columns it covers.
""".
-spec encryption_key() -> binary() | undefined.
encryption_key() ->
    case setting(encryption_key, undefined) of
        undefined -> undefined;
        Key when is_binary(Key) -> Key;
        _NotAKey -> error({shigoto_config, {invalid_encryption_key, not_a_binary}})
    end.

-doc "Heartbeat interval in milliseconds for executing jobs. Default: 30000.".
-spec heartbeat_interval() -> pos_integer().
heartbeat_interval() ->
    integer_setting(heartbeat_interval, 30000).

-doc "Milliseconds between sweeps for stale executing jobs. Default: 60000.".
-spec rescue_interval() -> pos_integer().
rescue_interval() ->
    integer_setting(rescue_interval, 60000).

-doc """
Seconds an executing job may go without a heartbeat before it counts as stale:
twice the heartbeat interval.
""".
-spec stale_after() -> float().
stale_after() ->
    heartbeat_interval() * 2 / 1000.

-doc """
What a waiting job does when a job it depends on is discarded or cancelled,
unless the job says otherwise with its own `on_dependency_failure`: `run`
without it (the default), or be `cancel`led or `discard`ed in turn.
""".
-spec on_dependency_failure() -> run | cancel | discard.
on_dependency_failure() ->
    case application:get_env(shigoto, on_dependency_failure, run) of
        Policy when Policy =:= run; Policy =:= cancel; Policy =:= discard -> Policy;
        Other -> error({invalid_on_dependency_failure, Other})
    end.

-doc "Load shedding config. Default: undefined (disabled).".
-spec load_shedding() -> map() | undefined.
load_shedding() ->
    map_setting(load_shedding).

-doc "Queue weight config. Map of queue name to weight. Default: #{} (equal weight).".
-spec queue_weights() -> #{binary() => pos_integer()}.
queue_weights() ->
    case setting(queue_weights, #{}) of
        Weights when is_map(Weights) ->
            #{
                Queue => Weight
             || Queue := Weight <- Weights, is_binary(Queue), is_integer(Weight)
            };
        Other ->
            error({shigoto_config, {invalid, queue_weights, Other}})
    end.

-doc "Queues that use fair partition-based claiming. Default: [] (all use standard claiming).".
-spec fair_queues() -> [binary()].
fair_queues() ->
    [Queue || Queue <- list_setting(fair_queues), is_binary(Queue)].

-doc "Ordered list of encryption keys (newest first) for key rotation. Default: [].".
-spec encryption_keys() -> [binary()].
encryption_keys() ->
    [
        case Key of
            _ when is_binary(Key) -> Key;
            _NotAKey -> error({shigoto_config, {invalid_encryption_key, not_a_binary}})
        end
     || Key <- list_setting(encryption_keys)
    ].

-doc """
Fanout queues — every node processes every job. Format:
`[{QueueName, Concurrency, Opts}]` where Opts may include
`window` (seconds, default 120). Default: [].
""".
-spec fanout_queues() -> [{Name :: term(), Concurrency :: term(), Opts :: term()}].
fanout_queues() ->
    [Queue || {_Name, _Concurrency, _Opts} = Queue <- list_setting(fanout_queues)].

-doc """
The module that carries a context from the process that inserts a job to the
processes that run it (`m:shigoto_propagator`). Default: `undefined`, nothing
is carried.
""".
-spec propagator() -> module() | undefined.
propagator() ->
    case setting(propagator, undefined) of
        Module when is_atom(Module) -> Module;
        _NotAModule -> undefined
    end.

-doc """
The frame `m:shigoto_crypto` writes: `v2` (the default) or `v1`.

`v1` is what releases up to 1.10 write and is all they can read. Set it for
the time 1.10 nodes run beside this release, and remove it once every node is
upgraded. See the [Encryption](encryption.md#upgrading-encryption) guide for
the upgrade steps.
""".
-spec encryption_write_format() -> v1 | v2.
encryption_write_format() ->
    case application:get_env(shigoto, encryption_write_format, v2) of
        Format when Format =:= v1; Format =:= v2 -> Format;
        Other -> error({shigoto_config, {invalid_encryption_write_format, Other}})
    end.

-doc """
The frames `m:shigoto_crypto` reads: `[v1, v2]` by default. Set `[v2]` once no
`v1` ciphertext is left (`shigoto:reencrypt/0,1`), so that one copied from a
backup or another row is refused.
""".
-spec encryption_read_formats() -> [v1 | v2].
encryption_read_formats() ->
    case application:get_env(shigoto, encryption_read_formats, [v1, v2]) of
        Formats when is_list(Formats) -> [v1 || v1 <- Formats] ++ [v2 || v2 <- Formats];
        _NotAList -> []
    end.

-doc """
Whether a plaintext value in a column this installation encrypts fails the job
instead of being run. Default: `false`. Only applies with a key configured.
""".
-spec require_encrypted() -> boolean().
require_encrypted() ->
    application:get_env(shigoto, require_encrypted, false) =:= true.

-doc """
The worker modules this node runs. Default: `undefined`, any module that
exports `perform/1`. With a list, a job naming a module outside it fails with
`unknown_worker` and the module is never loaded or called.

Optional in 1.x and required from 2.0: set it now.
""".
-spec workers() -> [term()] | undefined.
workers() ->
    case application:get_env(shigoto, workers, undefined) of
        undefined -> undefined;
        Workers when is_list(Workers) -> Workers;
        _NotAList -> []
    end.

-doc """
The name of this installation. Default: `undefined`.

With a name, the advisory locks shigoto takes and the `NOTIFY` channel it uses
are its own, so two installations in one database (two schemas) do not share
them. Lower-case letters, digits and `_`, at most 32 bytes. Every node of one
installation has to name the same instance: a node with a name and one without
do not exclude each other.
""".
-spec instance() -> binary() | undefined.
instance() ->
    case application:get_env(shigoto, instance, undefined) of
        Instance when is_binary(Instance) -> Instance;
        _Unnamed -> undefined
    end.

-doc """
Milliseconds to wait for an advisory lock another session holds before giving
up. Default: 5000.
""".
-spec advisory_lock_timeout() -> non_neg_integer().
advisory_lock_timeout() ->
    case application:get_env(shigoto, advisory_lock_timeout, 5000) of
        Ms when is_integer(Ms), Ms >= 0 -> Ms;
        _Invalid -> 5000
    end.

-doc """
The shortest time, in milliseconds, between two polls of one queue caused by
notifications. Default: 10.
""".
-spec notify_min_interval() -> non_neg_integer().
notify_min_interval() ->
    case application:get_env(shigoto, notify_min_interval, 10) of
        Ms when is_integer(Ms), Ms >= 0 -> Ms;
        _Invalid -> 10
    end.

-doc """
The `NOTIFY` channel jobs are announced on: `shigoto_jobs_insert`, or
`shigoto_jobs_insert_<instance>` when an instance is named.
""".
-spec notify_channel() -> binary().
notify_channel() ->
    case instance() of
        undefined -> ~"shigoto_jobs_insert";
        Instance -> <<"shigoto_jobs_insert_", Instance/binary>>
    end.

-doc """
Check the settings that are dangerous to get wrong, before anything starts.

Answers `{error, {shigoto_config, Reason}}` for the first problem. `Reason`
names the setting and what is wrong with it, never a key.
""".
-spec check() -> ok | {error, {shigoto_config, term()}}.
check() ->
    try
        ok = checked(shigoto_crypto:check_keys()),
        _ = encryption_write_format(),
        ok = checked(read_formats_checked(setting(encryption_read_formats, [v1, v2]))),
        ok = checked(boolean_checked(require_encrypted, setting(require_encrypted, false))),
        ok = checked(workers_checked(setting(workers, undefined))),
        ok = checked(instance_checked(setting(instance, undefined))),
        ok = checked(interval_checked(advisory_lock_timeout, setting(advisory_lock_timeout, 5000))),
        ok = checked(interval_checked(notify_min_interval, setting(notify_min_interval, 10))),
        ok = checked(shigoto_propagator:check(setting(propagator, undefined)))
    catch
        error:{shigoto_config, Reason} -> {error, {shigoto_config, Reason}}
    end.

checked(ok) -> ok;
checked({error, Reason}) -> error({shigoto_config, Reason}).

%% A setting as it was configured, which is not yet known to be of its type.
-spec setting(atom(), term()) -> term().
setting(Key, Default) ->
    application:get_env(shigoto, Key, Default).

%% A setting of the wrong type never worked: it failed further in, at a timer
%% or in a statement. Here it fails by name.
-spec integer_setting(atom(), integer()) -> integer().
integer_setting(Key, Default) ->
    case setting(Key, Default) of
        Value when is_integer(Value) -> Value;
        Other -> error({shigoto_config, {invalid, Key, Other}})
    end.

-spec map_setting(atom()) -> map() | undefined.
map_setting(Key) ->
    case setting(Key, undefined) of
        undefined -> undefined;
        Value when is_map(Value) -> Value;
        _NotAMap -> error({shigoto_config, {invalid, Key, not_a_map}})
    end.

-spec list_setting(atom()) -> [term()].
list_setting(Key) ->
    case setting(Key, []) of
        Value when is_list(Value) -> Value;
        Other -> error({shigoto_config, {invalid, Key, Other}})
    end.

read_formats_checked(Formats) when is_list(Formats), Formats =/= [] ->
    case [Format || Format <- Formats, Format =/= v1, Format =/= v2] of
        [] -> ok;
        _ -> {error, {invalid_encryption_read_formats, Formats}}
    end;
read_formats_checked(Formats) ->
    {error, {invalid_encryption_read_formats, Formats}}.

boolean_checked(_Setting, Value) when is_boolean(Value) -> ok;
boolean_checked(Setting, Value) -> {error, {not_a_boolean, Setting, Value}}.

workers_checked(undefined) ->
    ok;
workers_checked(Workers) when is_list(Workers) ->
    case lists:all(fun erlang:is_atom/1, Workers) of
        true -> ok;
        false -> {error, {invalid_workers, not_modules}}
    end;
workers_checked(_Workers) ->
    {error, {invalid_workers, not_a_list}}.

instance_checked(undefined) ->
    ok;
instance_checked(Instance) when is_binary(Instance) ->
    case re:run(Instance, ~"^[a-z0-9_]{1,32}$", [dollar_endonly, {capture, none}]) of
        match -> ok;
        nomatch -> {error, {invalid_instance, Instance}}
    end;
instance_checked(Instance) ->
    {error, {invalid_instance, Instance}}.

interval_checked(_Setting, Ms) when is_integer(Ms), Ms >= 0 -> ok;
interval_checked(Setting, Ms) -> {error, {not_milliseconds, Setting, Ms}}.
