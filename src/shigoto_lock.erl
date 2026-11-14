-module(shigoto_lock).
-moduledoc """
The PostgreSQL advisory locks shigoto takes: one per unique key while a unique
job is inserted, one per worker for the global concurrency check, and one each
for the cron pass, the stager pass and the migration.

Advisory locks are shared by the whole database. Any role that can connect can
take any key, so a lock here can be held by something that is not shigoto. Two
things follow:

- shigoto never waits for one without a bound. Every lock is taken with
  `pg_try_advisory_xact_lock`, and `acquire_xact/2` tries again for at most
  `shigoto_config:advisory_lock_timeout/0` milliseconds before it answers
  `{error, lock_timeout}`. What the caller does then is the caller's to say:
  a unique insert answers the error, the global concurrency check snoozes the
  job, a cron or stager pass is skipped, a migration is retried.
- With `shigoto_config:instance/0` set, the keys are this installation's own:
  the two-integer form of the lock, with the first integer derived from the
  instance name. Two installations in one database then never share a key.
  Without an instance the keys are the single integers earlier releases take,
  so nodes of both releases exclude each other during a rolling deploy. A node
  with an instance and one without do not, so name the instance on every node
  at once.

All locks are transaction-scoped: call these inside `shigoto_db:transaction/2`.
""".

-export([try_xact/2, acquire_xact/2, acquire_xact/3]).

-doc """
Take a lock without waiting: `true` when this transaction holds it, `false`
when another session does.
""".
-spec try_xact(atom(), integer()) -> boolean() | {error, term()}.
try_xact(Pool, Key) ->
    tried(Pool, [Key]).

-doc """
Take every lock in `Keys`, waiting at most `advisory_lock_timeout` for the ones
another session holds.
""".
-spec acquire_xact(atom(), [integer(), ...]) -> ok | {error, lock_timeout | term()}.
acquire_xact(Pool, Keys) ->
    acquire_xact(Pool, Keys, shigoto_config:advisory_lock_timeout()).

-doc "Like `acquire_xact/2`, waiting at most `Timeout` milliseconds.".
-spec acquire_xact(atom(), [integer(), ...], non_neg_integer()) ->
    ok | {error, lock_timeout | term()}.
acquire_xact(Pool, Keys, Timeout) ->
    acquired(Pool, lists:usort(Keys), erlang:monotonic_time(millisecond) + Timeout).

acquired(Pool, Keys, Deadline) ->
    case tried(Pool, Keys) of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {error, lock_timeout};
                false ->
                    timer:sleep(4 + rand:uniform(16)),
                    acquired(Pool, Keys, Deadline)
            end;
        {error, _} = Failed ->
            Failed
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec tried(atom(), [integer(), ...]) -> boolean() | {error, term()}.
tried(Pool, Keys) ->
    {SQL, Params} = statement(shigoto_config:instance(), Keys),
    case shigoto_db:query(Pool, SQL, Params) of
        #{rows := [#{locked := Locked}]} when is_boolean(Locked) -> Locked;
        {error, _} = Failed -> Failed
    end.

statement(undefined, Keys) ->
    Calls = [
        [~"pg_try_advisory_xact_lock($", integer_to_binary(N), ~")"]
     || N <- lists:seq(1, length(Keys))
    ],
    {iolist_to_binary([~"SELECT ", in_order(Calls), ~" AS locked"]), Keys};
statement(Instance, Keys) ->
    Calls = [
        [~"pg_try_advisory_xact_lock($1, $", integer_to_binary(N + 1), ~")"]
     || N <- lists:seq(1, length(Keys))
    ],
    {iolist_to_binary([~"SELECT ", in_order(Calls), ~" AS locked"]), [
        class(Instance) | [int4(Key) || Key <- Keys]
    ]}.

%% CASE is the one construct PostgreSQL evaluates in order, so a later lock is
%% only asked for once the earlier ones are held.
in_order([Call]) ->
    Call;
in_order([Call | Calls]) ->
    [~"CASE WHEN ", Call, ~" THEN ", in_order(Calls), ~" ELSE false END"].

class(Instance) ->
    <<Class:32/signed, _/binary>> = crypto:hash(sha256, [~"shigoto/lock/", Instance]),
    Class.

int4(Key) ->
    <<Signed:32/signed>> = <<Key:32>>,
    Signed.
