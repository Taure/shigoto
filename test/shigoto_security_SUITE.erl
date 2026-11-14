-module(shigoto_security_SUITE).
-behaviour(ct_suite).
-moduledoc """
What someone who can write to the jobs table, or merely connect to the
database, can make shigoto do. Each case runs the real application, sets up
the row or the lock by hand with SQL, and checks three things: nothing is
decrypted that should not be, nothing is called that should not be, and no
plaintext reaches the `errors` column, a log event or a telemetry event.

The canary is a string put in a job's args. `captured/0` collects every logger
event (with metadata) and every shigoto telemetry event the case produced.
""".

-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    args_moved_to_another_worker_are_not_decrypted/1,
    args_moved_to_a_module_that_is_no_worker_are_not_decrypted/1,
    args_moved_to_another_column_are_not_decrypted/1,
    a_worker_outside_the_allow_list_is_never_called/1,
    a_job_put_back_for_its_worker_is_not_decrypted/1,
    a_frame_that_does_not_open_fails_the_job/1,
    a_plaintext_job_is_refused_when_encryption_is_required/1,
    a_v1_frame_is_refused_once_only_v2_is_read/1,
    v1_is_still_written_and_read_when_set/1,
    v1_is_written_unless_v2_is_set/1,
    v1_leaves_results_and_callback_args_as_1_10_reads_them/1,
    no_failure_stores_or_emits_the_args/1,
    random_args_and_failures_never_leak/1,
    a_running_job_is_held_encrypted/1,
    a_result_is_encrypted_and_reaches_the_dependent/1,
    a_result_moved_to_another_job_is_not_decrypted/1,
    batch_callback_args_are_encrypted/1,
    a_batch_naming_no_worker_gets_no_callback/1,
    replaced_args_are_bound_to_the_existing_row/1,
    a_unique_job_is_still_found_after_key_rotation/1,
    a_unique_job_from_before_encryption_is_still_a_duplicate/1,
    a_unique_job_is_still_found_once_its_key_is_dropped/1,
    insert_all_inserts_a_unique_job_once/1,
    insert_all_takes_uniqueness_from_its_options/1,
    insert_all_inserts_nothing_when_a_unique_lock_is_held/1,
    two_bulk_inserts_at_once_insert_each_unique_job_once/1,
    a_bulk_insert_rolled_back_leaves_no_unique_job/1,
    insert_all_encrypts_the_meta/1,
    insert_all_validates_dependencies/1,
    a_bad_key_stops_the_boot_without_printing_it/1,
    a_held_unique_lock_does_not_stall_the_insert/1,
    a_held_concurrency_lock_snoozes_the_job/1,
    an_instance_has_its_own_locks_and_channel/1,
    a_flood_of_notifications_is_rate_limited/1,
    the_dashboard_decrypts_and_survives_odd_rows/1,
    reencrypt_moves_every_value_to_v2/1,
    errors_are_bounded/1
]).

-define(POOL, shigoto_test_pool).
-define(QUEUE, ~"default").
-define(ENV_KEYS, [
    queues,
    poll_interval,
    heartbeat_interval,
    rescue_interval,
    notifier,
    encryption_key,
    encryption_keys,
    encryption_write_format,
    encryption_read_formats,
    require_encrypted,
    workers,
    unrunnable_snooze_limit,
    instance,
    advisory_lock_timeout,
    notify_min_interval
]).

all() ->
    [{group, v2}, {group, v1}].

%% Every case runs with `encryption_write_format` `v2`. The ones that do not
%% assert what only `v2` gives (binding to column and worker, encrypted results
%% and callback args) run again with `v1`, the default.
groups() ->
    [{v2, [], cases() -- v1_only()}, {v1, [], cases() -- v2_only()}].

cases() ->
    [
        args_moved_to_another_worker_are_not_decrypted,
        args_moved_to_a_module_that_is_no_worker_are_not_decrypted,
        args_moved_to_another_column_are_not_decrypted,
        a_worker_outside_the_allow_list_is_never_called,
        a_job_put_back_for_its_worker_is_not_decrypted,
        a_frame_that_does_not_open_fails_the_job,
        a_plaintext_job_is_refused_when_encryption_is_required,
        a_v1_frame_is_refused_once_only_v2_is_read,
        v1_is_still_written_and_read_when_set,
        v1_is_written_unless_v2_is_set,
        v1_leaves_results_and_callback_args_as_1_10_reads_them,
        no_failure_stores_or_emits_the_args,
        random_args_and_failures_never_leak,
        a_running_job_is_held_encrypted,
        a_result_is_encrypted_and_reaches_the_dependent,
        a_result_moved_to_another_job_is_not_decrypted,
        batch_callback_args_are_encrypted,
        a_batch_naming_no_worker_gets_no_callback,
        replaced_args_are_bound_to_the_existing_row,
        a_unique_job_is_still_found_after_key_rotation,
        a_unique_job_from_before_encryption_is_still_a_duplicate,
        a_unique_job_is_still_found_once_its_key_is_dropped,
        insert_all_inserts_a_unique_job_once,
        insert_all_takes_uniqueness_from_its_options,
        insert_all_inserts_nothing_when_a_unique_lock_is_held,
        two_bulk_inserts_at_once_insert_each_unique_job_once,
        a_bulk_insert_rolled_back_leaves_no_unique_job,
        insert_all_encrypts_the_meta,
        insert_all_validates_dependencies,
        a_bad_key_stops_the_boot_without_printing_it,
        a_held_unique_lock_does_not_stall_the_insert,
        a_held_concurrency_lock_snoozes_the_job,
        an_instance_has_its_own_locks_and_channel,
        a_flood_of_notifications_is_rate_limited,
        the_dashboard_decrypts_and_survives_odd_rows,
        reencrypt_moves_every_value_to_v2,
        errors_are_bounded
    ].

v1_only() ->
    [v1_leaves_results_and_callback_args_as_1_10_reads_them].

%% What only `v2` gives, and the cases that set the format themselves.
v2_only() ->
    [
        args_moved_to_another_worker_are_not_decrypted,
        args_moved_to_another_column_are_not_decrypted,
        a_result_is_encrypted_and_reaches_the_dependent,
        a_result_moved_to_another_job_is_not_decrypted,
        batch_callback_args_are_encrypted,
        a_v1_frame_is_refused_once_only_v2_is_read,
        v1_is_still_written_and_read_when_set,
        v1_is_written_unless_v2_is_set,
        reencrypt_moves_every_value_to_v2
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    case application:load(shigoto) of
        ok -> ok;
        {error, {already_loaded, shigoto}} -> ok
    end,
    Config.

end_per_suite(_Config) ->
    shigoto_migration:down(?POOL),
    ok.

init_per_group(Format, Config) ->
    [{write_format, Format} | Config].

end_per_group(_Format, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ok = clean(),
    [
        application:set_env(shigoto, Key, Value)
     || Key := Value <- env(TestCase, proplists:get_value(write_format, Config))
    ],
    application:set_env(shigoto, pool, ?POOL),
    case TestCase of
        a_bad_key_stops_the_boot_without_printing_it ->
            ok;
        _ ->
            {ok, _} = application:ensure_all_started(shigoto),
            true = register(shigoto_canary_owner, self()),
            ok = shigoto_event_probe:attach()
    end,
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok = shigoto_event_probe:detach(),
    _ = [unregister(shigoto_canary_owner) || whereis(shigoto_canary_owner) =:= self()],
    _ = application:stop(shigoto),
    _ = application:stop(seki),
    [application:unset_env(shigoto, Key) || Key <- ?ENV_KEYS],
    ok = clean().

env(TestCase, Format) ->
    maps:merge(
        #{
            queues => [{?QUEUE, 5}],
            poll_interval => 50,
            heartbeat_interval => 5000,
            rescue_interval => 60000,
            encryption_key => key(1),
            encryption_write_format => Format
        },
        overrides(TestCase)
    ).

overrides(a_worker_outside_the_allow_list_is_never_called) ->
    #{workers => [shigoto_canary_worker], unrunnable_snooze_limit => 0};
overrides(args_moved_to_a_module_that_is_no_worker_are_not_decrypted) ->
    #{unrunnable_snooze_limit => 0};
overrides(a_job_put_back_for_its_worker_is_not_decrypted) ->
    #{workers => [shigoto_canary_worker]};
overrides(a_plaintext_job_is_refused_when_encryption_is_required) ->
    #{require_encrypted => true};
overrides(v1_is_still_written_and_read_when_set) ->
    #{encryption_write_format => v1};
overrides(a_held_unique_lock_does_not_stall_the_insert) ->
    #{advisory_lock_timeout => 200};
overrides(insert_all_inserts_nothing_when_a_unique_lock_is_held) ->
    #{advisory_lock_timeout => 200};
overrides(a_held_concurrency_lock_snoozes_the_job) ->
    #{advisory_lock_timeout => 200};
overrides(a_flood_of_notifications_is_rate_limited) ->
    #{poll_interval => 60000, notify_min_interval => 250, notifier => connection()};
overrides(errors_are_bounded) ->
    #{encryption_key => undefined};
overrides(_TestCase) ->
    #{}.

%%----------------------------------------------------------------------
%% Moving a ciphertext
%%----------------------------------------------------------------------

args_moved_to_another_worker_are_not_decrypted(_Config) ->
    Canary = canary(),
    Source = parked(Canary),
    Target = insert_row(~"shigoto_canary_other_worker", stored(Source, args), 1),
    Row = await(Target, ~"discarded"),
    ?assertMatch([#{~"error" := ~"decrypt_failed"}], errors(Row)),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Canary, [Row | captured()]).

args_moved_to_a_module_that_is_no_worker_are_not_decrypted(_Config) ->
    Canary = canary(),
    Source = parked(Canary),
    %% maps:get/1 does not exist: on a release that resolved the worker by name
    %% alone, the undef frame carried the decrypted args into `errors`.
    Target = insert_row(~"maps", stored(Source, args), 1),
    Row = await(Target, ~"discarded"),
    ?assertMatch([#{~"error" := <<"{unknown_worker,", _/binary>>}], errors(Row)),
    ok = no_canary(Canary, [Row | captured()]).

args_moved_to_another_column_are_not_decrypted(_Config) ->
    Canary = canary(),
    Source = parked(Canary),
    Target = parked(~"harmless"),
    #{} = shigoto_db:query(
        ?POOL,
        ~"UPDATE shigoto_jobs SET meta = $2::jsonb, scheduled_at = now() WHERE id = $1",
        [Target, stored(Source, args)]
    ),
    Row = await(Target, ~"retryable"),
    ?assertMatch([#{~"error" := ~"decrypt_failed"}], errors(Row)),
    ok = not_performed(shigoto_canary_worker),
    %% Reading the job shows the reason, not the args that were moved in.
    {ok, #{meta := Meta}} = shigoto:get_job(Target),
    ?assertEqual(~"\"decrypt_failed\"", Meta),
    ok = no_canary(Canary, [Row, Meta | captured()]).

a_worker_outside_the_allow_list_is_never_called(_Config) ->
    Canary = canary(),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker, args => #{~"canary" => Canary}, max_attempts => 1
    }),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"error" := <<"{unknown_worker,", _/binary>>}], errors(Row)),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Canary, [Row | captured()]),
    Allowed = enqueue(~"ok", Canary),
    _ = performed(),
    _ = await(Allowed, ~"completed").

a_job_put_back_for_its_worker_is_not_decrypted(_Config) ->
    Canary = canary(),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker, args => #{~"canary" => Canary}
    }),
    ok = wait_for(fun() -> errors(row(Id)) =/= [] end),
    Row = row(Id),
    ?assertMatch(#{state := ~"available", attempt := 1}, Row),
    ?assertMatch([#{~"error" := <<"{unknown_worker,", _/binary>>, ~"snoozed" := 30}], errors(Row)),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Canary, [Row | captured()]).

%%----------------------------------------------------------------------
%% What is not a valid ciphertext
%%----------------------------------------------------------------------

a_frame_that_does_not_open_fails_the_job(_Config) ->
    Garbage = iolist_to_binary(
        json:encode(<<"enc:v2:", (base64:encode(crypto:strong_rand_bytes(64)))/binary>>)
    ),
    Id = insert_row(~"shigoto_canary_worker", Garbage, 1),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"error" := ~"decrypt_failed"}], errors(Row)),
    ok = not_performed(shigoto_canary_worker),
    {ok, #{args := Args}} = shigoto:get_job(Id),
    ?assertEqual(~"\"decrypt_failed\"", Args).

a_plaintext_job_is_refused_when_encryption_is_required(_Config) ->
    Canary = canary(),
    Plain = iolist_to_binary(json:encode(args(~"ok", Canary))),
    Id = insert_row(~"shigoto_canary_worker", Plain, 1),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"error" := ~"plaintext_refused"}], errors(Row)),
    ok = not_performed(shigoto_canary_worker),
    Encrypted = enqueue(~"ok", Canary),
    _ = performed(),
    _ = await(Encrypted, ~"completed").

a_v1_frame_is_refused_once_only_v2_is_read(_Config) ->
    Canary = canary(),
    application:set_env(shigoto, encryption_write_format, v1),
    Old = parked(Canary),
    ?assertMatch(<<"\"enc:", _/binary>>, stored(Old, args)),
    ?assertNotMatch(<<"\"enc:v2:", _/binary>>, stored(Old, args)),
    application:set_env(shigoto, encryption_write_format, v2),
    application:set_env(shigoto, encryption_read_formats, [v2]),
    ok = due(Old),
    Row = await(Old, ~"retryable"),
    ?assertMatch([#{~"error" := ~"format_refused"}], errors(Row)),
    ok = not_performed(shigoto_canary_worker).

v1_is_still_written_and_read_when_set(_Config) ->
    Canary = canary(),
    Id = enqueue(~"result", Canary),
    {_Worker, Args} = performed(),
    ?assertMatch(#{~"canary" := Canary}, Args),
    Row = await(Id, ~"completed"),
    %% What the previous release wrote, opened the way it opened it.
    <<"\"enc:", Rest/binary>> = maps:get(args, Row),
    Encoded = binary:part(Rest, 0, byte_size(Rest) - 1),
    ?assertMatch(#{~"canary" := Canary}, opened_by_1_10(key(1), base64:decode(Encoded))),
    %% v1 covers what that release covered: a result stays readable to it.
    ?assertEqual(#{~"secret" => Canary}, json:decode(maps:get(result, Row))).

opened_by_1_10(Key, <<IV:12/binary, Tag:16/binary, Cipher/binary>>) ->
    case crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Cipher, ~"shigoto", Tag, false) of
        Plain when is_binary(Plain) -> json:decode(Plain)
    end.

%%----------------------------------------------------------------------
%% Failures
%%----------------------------------------------------------------------

%% The default is what 1.10 can read. A node that does not say `v2` writes
%% nothing a 1.10 node beside it, or one rolled back to, would fail on.
v1_is_written_unless_v2_is_set(_Config) ->
    Insert = fun() ->
        {ok, #{args := Args}} = shigoto:insert(#{
            worker => shigoto_canary_other_worker, args => #{~"n" => 1}, queue => ~"parked"
        }),
        Args
    end,
    ok = application:stop(shigoto),
    application:unset_env(shigoto, encryption_write_format),
    _ = shigoto_event_probe:captured(),
    {ok, _} = application:ensure_all_started(shigoto),
    <<"\"enc:", Rest/binary>> = Stored = Insert(),
    ?assertNotMatch(<<"\"enc:v2:", _/binary>>, Stored),
    Encoded = binary:part(Rest, 0, byte_size(Rest) - 1),
    ?assertEqual(#{~"n" => 1}, opened_by_1_10(key(1), base64:decode(Encoded))),
    %% Not a setting to be warned about: it is the default.
    ?assertEqual([], boot_warnings(~"shigoto_encryption_write_format_v1")),
    ok = application:stop(shigoto),
    application:set_env(shigoto, encryption_write_format, v2),
    {ok, _} = application:ensure_all_started(shigoto),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, Insert()),
    %% Both are read whichever is written.
    ?assertEqual(
        {ok, ~"{\"n\":1}"}, shigoto_crypto:open(Stored, {args, ~"shigoto_canary_other_worker"})
    ).

v1_leaves_results_and_callback_args_as_1_10_reads_them(_Config) ->
    Canary = canary(),
    {ok, #{id := BatchId}} = shigoto:new_batch(#{
        callback_worker => shigoto_canary_other_worker,
        callback_args => #{~"canary" => Canary}
    }),
    #{rows := [#{callback_args := StoredArgs}]} = shigoto_db:query(
        ?POOL, ~"SELECT callback_args FROM shigoto_batches WHERE id = $1", [BatchId]
    ),
    ?assertEqual(#{~"canary" => Canary}, json:decode(StoredArgs)),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker, args => args(~"result", Canary), batch => BatchId
    }),
    _ = performed(shigoto_canary_worker),
    Row = await(Id, ~"completed"),
    ?assert(written_frame(maps:get(args, Row))),
    ?assertEqual(#{~"secret" => Canary}, json:decode(maps:get(result, Row))),
    {_Worker, CallbackArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{~"canary" => Canary}, CallbackArgs).

boot_warnings(Msg) ->
    [
        Event
     || {log, #{level := warning, msg := {report, #{msg := Logged}}} = Event} <-
            shigoto_event_probe:captured(),
        Logged =:= Msg
    ].

no_failure_stores_or_emits_the_args(_Config) ->
    [ok = fails_without_leaking(Mode, canary()) || Mode <- shigoto_canary_worker:modes()],
    ok.

random_args_and_failures_never_leak(_Config) ->
    Seed = {erlang:unique_integer([positive]), erlang:system_time(), 7},
    ct:log("seed ~p", [Seed]),
    _ = rand:seed(exsss, Seed),
    Modes = shigoto_canary_worker:modes(),
    [
        ok = fails_without_leaking(
            lists:nth(rand:uniform(length(Modes)), Modes), random_canary(), random_extra()
        )
     || _ <- lists:seq(1, 40)
    ],
    ok.

fails_without_leaking(Mode, Canary) ->
    fails_without_leaking(Mode, Canary, #{}).

fails_without_leaking(Mode, Canary, Extra) ->
    ok = closed_breaker(),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker,
        args => maps:merge(Extra, args(Mode, Canary)),
        meta => #{~"trace" => Canary},
        max_attempts => 1
    }),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"error" := _}], errors(Row)),
    receive
        {discarded, shigoto_canary_worker, #{~"canary" := Canary}, [_]} -> ok
    after 2000 -> ct:fail({on_discard_not_called, Mode})
    end,
    case no_canary(Canary, [Row | captured()]) of
        ok -> ok;
        Leak -> ct:fail({Mode, Leak})
    end.

%% Every job in these cases fails, which is what opens a worker's breaker.
closed_breaker() ->
    Breaker = shigoto_cb_shigoto_canary_worker,
    _ = [seki:reset_breaker(Breaker) || whereis(Breaker) =/= undefined],
    ok.

a_running_job_is_held_encrypted(_Config) ->
    Canary = canary(),
    Id = enqueue(~"wait", Canary),
    {Worker, _Args} = performed(),
    [Executor] = shigoto_executor:running(Id),
    %% The executor is busy with the run, so what a remote shell can ask of it
    %% without stopping it is this. The decrypted job is on its stack and in
    %% the worker process, nowhere else.
    Held = [
        process_info(Executor, [dictionary, messages]),
        ets:tab2list(shigoto_executors),
        [sys:get_state(Queue) || {_, Queue, _, _} <- supervisor:which_children(shigoto_queue_sup)]
    ],
    Worker ! {instruct, ok},
    _ = await(Id, ~"completed"),
    ok = no_canary(Canary, Held),
    %% What `sys` and a crash report print for an executor.
    {ok, _Module, Opened} = shigoto_job:opened(row(Id)),
    ?assertNotEqual(ok, no_canary(Canary, [Opened])),
    State = {state, Opened, ?POOL, self(), claimed},
    ok = no_canary(Canary, [shigoto_executor:format_status(#{state => State, message => execute})]).

errors_are_bounded(_Config) ->
    %% Without a key the reason is stored as it is, but never without a bound.
    Big = binary:copy(~"x", 100000),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker, args => args(~"return_error", Big), max_attempts => 60
    }),
    _ = performed(),
    First = await(Id, ~"retryable"),
    [#{~"error" := Error}] = errors(First),
    ?assert(byte_size(Error) =< 1024),
    Entry = ~"{\"error\": \"filler\"}",
    #{} = shigoto_db:query(
        ?POOL,
        ~"""
        UPDATE shigoto_jobs
        SET errors = (SELECT jsonb_agg($2::jsonb) FROM generate_series(1, 50)), scheduled_at = now()
        WHERE id = $1
        """,
        [Id, Entry]
    ),
    _ = performed(),
    ok = wait_for(fun() -> maps:get(attempt, row(Id)) =:= 2 andalso retryable(Id) end),
    Errors = errors(row(Id)),
    ?assertEqual(50, length(Errors)),
    ?assertMatch(#{~"attempt" := 2}, lists:last(Errors)).

retryable(Id) ->
    maps:get(state, row(Id)) =:= ~"retryable".

%%----------------------------------------------------------------------
%% Results and batches
%%----------------------------------------------------------------------

a_result_is_encrypted_and_reaches_the_dependent(_Config) ->
    Canary = canary(),
    Parent = enqueue(~"result", Canary),
    {ok, #{id := Child}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker, args => #{}, depends_on => [Parent]
    }),
    _ = performed(shigoto_canary_worker),
    {_Worker, ChildArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Parent => #{~"secret" => Canary}}, maps:get(deps_results, ChildArgs)),
    ParentRow = await(Parent, ~"completed"),
    ChildRow = await(Child, ~"completed"),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, maps:get(result, ParentRow)),
    ok = no_canary(Canary, [ParentRow, ChildRow | captured()]),
    {ok, #{result := Result, args := Args}} = shigoto:get_job(Parent),
    ?assertEqual(#{~"secret" => Canary}, json:decode(Result)),
    ?assertMatch(#{~"canary" := Canary}, json:decode(Args)),
    %% A dependency that has already finished is read at insert.
    {ok, #{id := Late}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker, args => #{}, depends_on => [Parent]
    }),
    {_, LateArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Parent => #{~"secret" => Canary}}, maps:get(deps_results, LateArgs)),
    ok = no_canary(Canary, [await(Late, ~"completed")]).

a_result_moved_to_another_job_is_not_decrypted(_Config) ->
    Canary = canary(),
    Source = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    #{result := Stolen} = await(Source, ~"completed"),
    Other = enqueue(~"ok", ~"harmless"),
    _ = performed(shigoto_canary_worker),
    _ = await(Other, ~"completed"),
    %% The stolen result is filed as the result of another job.
    Forged = iolist_to_binary(json:encode(#{integer_to_binary(Other) => json:decode(Stolen)})),
    Target = insert_row(~"shigoto_canary_other_worker", ~"{}", 1),
    #{} = shigoto_db:query(
        ?POOL,
        ~"UPDATE shigoto_jobs SET deps_results = $2::jsonb, args = $3::jsonb WHERE id = $1",
        [Target, Forged, shigoto_crypto:seal(~"{}", {args, ~"shigoto_canary_other_worker"})]
    ),
    Row = await(Target, ~"discarded"),
    ?assertMatch([_ | _], [E || #{~"error" := ~"decrypt_failed"} = E <- errors(Row)]),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Canary, [Row | captured()]).

batch_callback_args_are_encrypted(_Config) ->
    Canary = canary(),
    {ok, #{id := BatchId}} = shigoto:new_batch(#{
        callback_worker => shigoto_canary_other_worker, callback_args => #{~"canary" => Canary}
    }),
    #{rows := [#{callback_args := StoredArgs} = Stored]} = shigoto_db:query(
        ?POOL, ~"SELECT * FROM shigoto_batches WHERE id = $1", [BatchId]
    ),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, StoredArgs),
    ok = no_canary(Canary, [Stored]),
    {ok, #{callback_args := Shown}} = shigoto:get_batch(BatchId),
    ?assertEqual(#{~"canary" => Canary}, json:decode(Shown)),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker, args => args(~"ok", ~"x"), batch => BatchId
    }),
    _ = performed(shigoto_canary_worker),
    _ = await(Id, ~"completed"),
    {_Worker, CallbackArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{~"canary" => Canary}, CallbackArgs).

a_batch_naming_no_worker_gets_no_callback(_Config) ->
    {ok, #{id := BatchId}} = shigoto:new_batch(#{
        callback_worker => ~"shigoto_no_such_callback_module", callback_args => #{}
    }),
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker, args => args(~"ok", ~"x"), batch => BatchId
    }),
    _ = performed(shigoto_canary_worker),
    %% The job's own outcome is recorded whatever the batch row names.
    _ = await(Id, ~"completed"),
    ok = wait_for(fun() ->
        [
            Report
         || {log, #{msg := {report, #{msg := ~"shigoto_batch_callback_unrunnable"} = Report}}} <-
                captured()
        ] =/= []
    end),
    %% Nothing says a callback is on the way: the batch is as the job left it.
    ?assertMatch(
        {ok, #{state := ~"active", completed_jobs := 1, total_jobs := 1}},
        shigoto:get_batch(BatchId)
    ),
    #{rows := [#{count := 1}]} = shigoto_db:query(
        ?POOL, ~"SELECT count(*) AS count FROM shigoto_jobs", []
    ).

%%----------------------------------------------------------------------
%% Uniqueness and bulk inserts
%%----------------------------------------------------------------------

replaced_args_are_bound_to_the_existing_row(_Config) ->
    Canary = canary(),
    Unique = #{unique => #{keys => [queue], replace => [args]}},
    Later = #{scheduled_at => seconds_from_now(3600)},
    {ok, #{id := Id}} = shigoto:insert(
        Later#{worker => shigoto_canary_other_worker, args => #{~"n" => 1}}, Unique
    ),
    %% Another worker replaces the args of the row it conflicts with.
    {ok, {conflict, #{id := Id}}} = shigoto:insert(
        Later#{worker => shigoto_canary_worker, args => #{~"canary" => Canary}}, Unique
    ),
    ?assert(written_frame(stored(Id, args))),
    ok = no_canary(Canary, [row(Id)]),
    ok = due(Id),
    {_Worker, Args} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{~"canary" => Canary}, Args),
    _ = await(Id, ~"completed").

a_unique_job_is_still_found_after_key_rotation(_Config) ->
    Unique = #{unique => #{keys => [worker, args]}},
    Params = #{
        worker => shigoto_canary_other_worker,
        args => #{~"n" => 1},
        scheduled_at => seconds_from_now(3600)
    },
    {ok, #{id := Id, unique_key := Before}} = shigoto:insert(Params, Unique),
    application:unset_env(shigoto, encryption_key),
    application:set_env(shigoto, encryption_keys, [key(2), key(1)]),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)),
    %% A new job is stored under the new key, and both are still found.
    {ok, #{unique_key := After}} = shigoto:insert(Params#{args => #{~"n" => 2}}, Unique),
    ?assertNotEqual(Before, After),
    ?assertEqual(shigoto_crypto:unique_key(~"{\"n\":2}:shigoto_canary_other_worker"), After),
    ?assertMatch({ok, {conflict, _}}, shigoto:insert(Params#{args => #{~"n" => 2}}, Unique)).

a_unique_job_from_before_encryption_is_still_a_duplicate(_Config) ->
    Unique = #{unique => #{keys => [worker, args]}},
    Params = #{
        worker => shigoto_canary_other_worker,
        args => #{~"n" => 1},
        scheduled_at => seconds_from_now(3600)
    },
    Material = ~"{\"n\":1}:shigoto_canary_other_worker",
    application:unset_env(shigoto, encryption_key),
    {ok, #{id := Id, unique_key := Raw}} = shigoto:insert(Params, Unique),
    ?assertEqual(Material, Raw),
    application:set_env(shigoto, encryption_key, key(1)),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)),
    %% The raw form is looked for, never stored.
    {ok, #{unique_key := Hashed}} = shigoto:insert(Params#{args => #{~"n" => 2}}, Unique),
    ?assertEqual(64, byte_size(Hashed)),
    ?assertEqual(nomatch, binary:match(Hashed, ~"shigoto_canary_other_worker")),
    %% reencrypt moves the old job's key to the hash, after which the raw
    %% form no longer has to be looked for.
    {ok, #{jobs := #{failed := 0, skipped := 0}}} = shigoto:reencrypt(),
    ?assertEqual(shigoto_crypto:unique_key(Material), stored(Id, unique_key)),
    application:set_env(shigoto, require_encrypted, true),
    ?assertEqual([shigoto_crypto:unique_key(Material)], shigoto_crypto:unique_keys(Material)),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)).

a_unique_job_is_still_found_once_its_key_is_dropped(_Config) ->
    ByArgs = #{unique => #{keys => [worker, args]}},
    ByQueue = #{unique => #{keys => [queue], states => [available, completed]}},
    Later = #{scheduled_at => seconds_from_now(3600)},
    First = Later#{worker => shigoto_canary_other_worker, args => #{~"n" => 1}},
    Second = Later#{
        worker => shigoto_canary_other_worker, args => #{~"n" => 2}, queue => ~"parked"
    },
    {ok, #{id := FirstId, unique_key := FirstKey}} = shigoto:insert(First, ByArgs),
    {ok, #{id := SecondId}} = shigoto:insert(Second, ByQueue),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET state = 'completed' WHERE id = $1", [SecondId]
    ),
    application:unset_env(shigoto, encryption_key),
    application:set_env(shigoto, encryption_keys, [key(2), key(1)]),
    ?assertMatch({ok, {conflict, #{id := FirstId}}}, shigoto:insert(First, ByArgs)),
    {ok, #{jobs := Jobs}} = shigoto:reencrypt(),
    ?assertMatch(#{failed := 0, skipped := 0}, Jobs),
    ?assertNotEqual(FirstKey, stored(FirstId, unique_key)),
    ?assertEqual(
        shigoto_crypto:unique_key(~"{\"n\":1}:shigoto_canary_other_worker"),
        stored(FirstId, unique_key)
    ),
    ?assertEqual(shigoto_crypto:unique_key(~"parked"), stored(SecondId, unique_key)),
    {ok, #{jobs := Again}} = shigoto:reencrypt(),
    ?assertMatch(#{rewritten := 0, failed := 0, skipped := 0}, Again),
    %% Reported clean: the old key can go and plaintext can be refused.
    application:set_env(shigoto, encryption_keys, [key(2)]),
    application:set_env(shigoto, require_encrypted, true),
    ?assertMatch({ok, {conflict, #{id := FirstId}}}, shigoto:insert(First, ByArgs)),
    ?assertMatch({ok, {conflict, #{id := SecondId}}}, shigoto:insert(Second, ByQueue)),
    %% A key written under a key that is no longer configured cannot be
    %% moved, and is reported.
    application:set_env(shigoto, encryption_keys, [key(3)]),
    {ok, #{jobs := Orphaned}} = shigoto:reencrypt(),
    ?assertMatch(#{failed := Failed} when Failed >= 2, Orphaned),
    ?assertEqual(unique_key_under(key(2), ~"parked"), stored(SecondId, unique_key)).

unique_key_under(Key, Material) ->
    Saved = application:get_env(shigoto, encryption_keys),
    application:set_env(shigoto, encryption_keys, [Key]),
    try
        shigoto_crypto:unique_key(Material)
    after
        case Saved of
            {ok, Keys} -> application:set_env(shigoto, encryption_keys, Keys);
            undefined -> application:unset_env(shigoto, encryption_keys)
        end
    end.

insert_all_inserts_a_unique_job_once(_Config) ->
    {ok, #{id := Already}} = shigoto:insert(waiting(shigoto_unique_worker, 1)),
    _ = captured(),
    {ok, Answered} = shigoto:insert_all([
        waiting(shigoto_canary_other_worker, 1),
        waiting(shigoto_unique_worker, 1),
        waiting(shigoto_unique_worker, 2),
        waiting(shigoto_canary_other_worker, 1),
        waiting(shigoto_unique_worker, 2)
    ]),
    [Plain, Duplicate, New, Other, Again] = [Id || #{id := Id} <- Answered],
    ?assertEqual(Already, Duplicate),
    ?assertEqual(New, Again),
    %% Inserted in the order given, the duplicates answered where they stood.
    ?assert(Already < Plain andalso Plain < New andalso New < Other),
    ?assertEqual(4, job_count()),
    ?assertEqual([Plain, New, Other], lists:sort(inserted_events())).

insert_all_takes_uniqueness_from_its_options(_Config) ->
    Plain = [waiting(shigoto_canary_other_worker, N) || N <- [1, 1, 2]],
    {ok, [#{id := One}, #{id := One}, #{id := Two}]} =
        shigoto:insert_all(Plain, #{unique => #{keys => [args]}}),
    ?assertNotEqual(One, Two),
    ?assertEqual(2, job_count()),
    %% Saying that duplicates are wanted is the way to insert them.
    Unique = [waiting(shigoto_unique_worker, N) || N <- [1, 1]],
    {ok, [#{id := First}, #{id := Second}]} = shigoto:insert_all(Unique, #{unique => false}),
    ?assertNotEqual(First, Second),
    ?assertEqual(4, job_count()).

insert_all_inserts_nothing_when_a_unique_lock_is_held(_Config) ->
    Jobs = [
        waiting(shigoto_canary_other_worker, 1),
        waiting(shigoto_unique_worker, 2),
        waiting(shigoto_unique_worker, 1)
    ],
    Key = erlang:phash2(shigoto_crypto:unique_key(~"{\"n\":1}:shigoto_unique_worker")),
    Holder = hold_lock(~"SELECT pg_advisory_xact_lock($1)", [Key]),
    _ = captured(),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, {lock_timeout, unique}}, shigoto:insert_all(Jobs)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    ?assertEqual(0, job_count()),
    ?assertEqual([], inserted_events()),
    ok = release(Holder),
    ?assertMatch({ok, [_, _, _]}, shigoto:insert_all(Jobs)),
    ?assertEqual(3, job_count()).

two_bulk_inserts_at_once_insert_each_unique_job_once(_Config) ->
    Jobs = [waiting(shigoto_unique_worker, N) || N <- lists:seq(1, 300)],
    Test = self(),
    Inserters = [
        spawn_monitor(fun() -> Test ! {answered, self(), shigoto:insert_all(Order)} end)
     || Order <- [Jobs, lists:reverse(Jobs)]
    ],
    [{ok, Forward}, {ok, Backward}] = [
        receive
            {answered, Pid, Answer} -> Answer;
            {'DOWN', Monitor, process, Pid, Reason} -> ct:fail({inserter_died, Reason})
        after 30000 -> ct:fail(insert_all_never_answered)
        end
     || {Pid, Monitor} <- Inserters
    ],
    ?assertEqual(300, job_count()),
    ?assertEqual(
        [Id || #{id := Id} <- Forward], lists:reverse([Id || #{id := Id} <- Backward])
    ),
    ?assertEqual(300, length(inserted_events())).

a_bulk_insert_rolled_back_leaves_no_unique_job(_Config) ->
    _ = captured(),
    ?assertError(
        undone,
        shigoto:transaction(fun() ->
            {ok, [_, _]} = shigoto:insert_all([
                waiting(shigoto_canary_other_worker, 1), waiting(shigoto_unique_worker, 1)
            ]),
            error(undone)
        end)
    ),
    ?assertEqual(0, job_count()),
    ?assertEqual([], inserted_events()),
    %% The lock went with the transaction.
    ?assertMatch({ok, [#{id := _}]}, shigoto:insert_all([waiting(shigoto_unique_worker, 1)])).

insert_all_encrypts_the_meta(_Config) ->
    Canary = canary(),
    {ok, [#{id := Id}]} = shigoto:insert_all([
        #{
            worker => shigoto_canary_other_worker,
            args => #{},
            meta => #{~"trace" => Canary},
            scheduled_at => seconds_from_now(3600)
        }
    ]),
    ?assert(written_frame(stored(Id, meta))),
    {ok, #{meta := Meta}} = shigoto:get_job(Id),
    ?assertEqual(#{~"trace" => Canary}, json:decode(Meta)).

%% Whether `Stored` is a frame of the format the case runs with.
written_frame(<<"\"enc:v2:", _/binary>>) -> shigoto_config:encryption_write_format() =:= v2;
written_frame(<<"\"enc:", _/binary>>) -> shigoto_config:encryption_write_format() =:= v1;
written_frame(_Plain) -> false.

waiting(Worker, N) ->
    #{worker => Worker, args => #{~"n" => N}, scheduled_at => seconds_from_now(3600)}.

inserted_events() ->
    [
        Id
     || {telemetry, [shigoto, job, inserted], _Measurements, #{job_id := Id}} <- captured()
    ].

insert_all_validates_dependencies(_Config) ->
    Job = #{worker => shigoto_canary_other_worker, args => #{}},
    ?assertEqual(
        {error, {missing_dependencies, [999999]}},
        shigoto:insert_all([Job, Job#{depends_on => [999999]}])
    ),
    ?assertEqual(0, job_count()),
    Canary = canary(),
    Parent = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    _ = await(Parent, ~"completed"),
    %% A dependency that has finished is not waited for, as with insert/1.
    {ok, [#{id := Child}]} = shigoto:insert_all([Job#{depends_on => [Parent]}]),
    {_Worker, Args} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Parent => #{~"secret" => Canary}}, maps:get(deps_results, Args)),
    _ = await(Child, ~"completed").

%%----------------------------------------------------------------------
%% Configuration
%%----------------------------------------------------------------------

a_bad_key_stops_the_boot_without_printing_it(_Config) ->
    Short = ~"sixteen byte key",
    application:set_env(shigoto, encryption_key, Short),
    {error, Reason} = application:ensure_all_started(shigoto),
    Text = iolist_to_binary(io_lib:format("~0tp", [Reason])),
    ?assertNotEqual(nomatch, binary:match(Text, ~"{invalid,encryption_key,")),
    ?assertEqual(nomatch, binary:match(Text, Short)),
    application:unset_env(shigoto, encryption_key),
    application:set_env(shigoto, encryption_keys, [key(1), key(2), key(1)]),
    ?assertMatch(
        {error, {shigoto_config, {invalid, encryption_keys, #{problem := duplicate_key}}}},
        shigoto_config:check()
    ),
    application:set_env(shigoto, encryption_keys, [key(1)]),
    application:set_env(shigoto, instance, ~"Not Valid"),
    ?assertMatch({error, {shigoto_config, {invalid, instance, _}}}, shigoto_config:check()).

%%----------------------------------------------------------------------
%% Locks and notifications
%%----------------------------------------------------------------------

a_held_unique_lock_does_not_stall_the_insert(_Config) ->
    Unique = #{unique => #{keys => [worker, args]}},
    Params = #{
        worker => shigoto_canary_other_worker,
        args => #{~"n" => 1},
        scheduled_at => seconds_from_now(3600)
    },
    Key = erlang:phash2(shigoto_crypto:unique_key(~"{\"n\":1}:shigoto_canary_other_worker")),
    Holder = hold_lock(~"SELECT pg_advisory_xact_lock($1)", [Key]),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, {lock_timeout, unique}}, shigoto:insert(Params, Unique)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    ?assertEqual(0, job_count()),
    ok = release(Holder),
    ?assertMatch({ok, #{id := _}}, shigoto:insert(Params, Unique)).

a_held_concurrency_lock_snoozes_the_job(_Config) ->
    Key = erlang:phash2({global_concurrency, ~"shigoto_global_conc_worker"}),
    Holder = hold_lock(~"SELECT pg_advisory_xact_lock($1)", [Key]),
    {ok, #{id := Id}} = shigoto:insert(#{worker => shigoto_global_conc_worker, args => #{}}),
    ok = wait_for(fun() ->
        lists:any(
            fun
                ({telemetry, [shigoto, resilience, gate_failed], _, #{gate := Gate}}) ->
                    Gate =:= global_concurrency;
                (_) ->
                    false
            end,
            captured()
        )
    end),
    %% Snoozed, not run and not failed.
    ok = wait_for(fun() -> maps:get(state, row(Id)) =:= ~"available" end),
    ?assertMatch(
        [#{~"error" := <<"{gate_failed,global_concurrency,", _/binary>>, ~"snoozed" := 5}],
        errors(row(Id))
    ),
    ok = release(Holder),
    ok = due(Id),
    _ = await(Id, ~"completed").

an_instance_has_its_own_locks_and_channel(_Config) ->
    Legacy = hold_lock(~"SELECT pg_advisory_xact_lock($1)", [839274630]),
    ?assertEqual({error, lock_timeout}, migrated_within(200)),
    application:set_env(shigoto, instance, ~"tenant_a"),
    try
        %% The same key in the installation's own space is free.
        ?assertEqual(ok, migrated_within(200)),
        ?assertEqual(~"shigoto_jobs_insert_tenant_a", shigoto_config:notify_channel()),
        ?assertNotEqual(nomatch, binary:match(notify_source(), ~"'shigoto_jobs_insert_tenant_a'"))
    after
        ok = release(Legacy),
        application:unset_env(shigoto, instance),
        ok = shigoto_migration:up(?POOL)
    end,
    ?assertNotEqual(nomatch, binary:match(notify_source(), ~"'shigoto_jobs_insert'")).

migrated_within(Ms) ->
    application:set_env(shigoto, advisory_lock_timeout, Ms),
    try
        shigoto_migration:up(?POOL)
    after
        application:unset_env(shigoto, advisory_lock_timeout)
    end.

notify_source() ->
    #{rows := [#{source := Source}]} = shigoto_db:query(
        ?POOL, ~"SELECT prosrc AS source FROM pg_proc WHERE proname = 'shigoto_notify_insert'", []
    ),
    Source.

a_flood_of_notifications_is_rate_limited(_Config) ->
    ok = wait_for(fun() -> element(2, notifier_state()) =/= undefined end),
    Notifier = whereis(shigoto_notifier),
    _ = captured(),
    %% Anyone who can connect can do this.
    [
        #{} = shigoto_db:query(?POOL, ~"SELECT pg_notify('shigoto_jobs_insert', $1)", [Payload])
     || _ <- lists:seq(1, 100),
        Payload <- [?QUEUE, ~"no-such-queue", binary:copy(~"x", 4000)]
    ],
    timer:sleep(600),
    Polls = [poll || {telemetry, [shigoto, queue, poll], _, _} <- captured()],
    %% One at once, then one per interval: 600 ms of a 250 ms interval.
    ?assert(length(Polls) >= 1),
    ?assert(length(Polls) =< 4),
    ?assertEqual(Notifier, whereis(shigoto_notifier)),
    %% Names that are no queue are not remembered.
    ?assertMatch(Wakes when map_size(Wakes) =:= 1, element(5, notifier_state())),
    ?assertMatch(#{?QUEUE := _}, element(5, notifier_state())).

notifier_state() ->
    case sys:get_state(shigoto_notifier) of
        State when is_tuple(State) -> State
    end.

%%----------------------------------------------------------------------
%% Reading and maintenance
%%----------------------------------------------------------------------

the_dashboard_decrypts_and_survives_odd_rows(_Config) ->
    Canary = canary(),
    Id = parked(Canary),
    {ok, [#{id := Id, args := Args}]} = shigoto_dashboard:search_jobs(#{
        worker => shigoto_canary_worker
    }),
    ?assertMatch(#{~"canary" := Canary}, json:decode(Args)),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET state = 'not_a_state_atom_anywhere' WHERE id = $1", [Id]
    ),
    {ok, [#{queue := ?QUEUE, other := 1}]} = shigoto_dashboard:queue_stats(),
    ?assertMatch({ok, #{status := _}}, shigoto:health()).

reencrypt_moves_every_value_to_v2(_Config) ->
    Canary = canary(),
    application:set_env(shigoto, encryption_write_format, v1),
    Parent = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    _ = await(Parent, ~"completed"),
    Waiting = seconds_from_now(3600),
    {ok, #{id := Child}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker,
        args => #{~"canary" => Canary},
        depends_on => [Parent],
        scheduled_at => Waiting
    }),
    Plain = insert_row(
        ~"shigoto_canary_other_worker", iolist_to_binary(json:encode(#{~"canary" => Canary})), 1
    ),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET scheduled_at = $2 WHERE id = $1", [Plain, Waiting]
    ),
    {ok, #{id := BatchId}} = shigoto:new_batch(#{
        callback_worker => shigoto_canary_other_worker, callback_args => #{~"canary" => Canary}
    }),
    %% v1 leaves the result, the copy of it in the child and the callback args
    %% in the clear, and the row inserted by hand is plaintext.
    ?assertNotEqual(ok, no_canary(Canary, rows())),
    application:set_env(shigoto, encryption_write_format, v2),
    {ok, #{jobs := Jobs, batches := Batches}} = shigoto:reencrypt(#{batch_size => 2}),
    ?assertMatch(#{scanned := 3, failed := 0, skipped := 0}, Jobs),
    ?assertMatch(#{scanned := 1, rewritten := 1, failed := 0}, Batches),
    ok = no_canary(Canary, rows()),
    [
        ?assertMatch(<<"\"enc:v2:", _/binary>>, stored(Id, args))
     || Id <- [Parent, Child, Plain]
    ],
    %% Nothing is left to do, and nothing was lost.
    {ok, #{jobs := Again}} = shigoto:reencrypt(),
    ?assertMatch(#{scanned := 3, rewritten := 0, failed := 0}, Again),
    application:set_env(shigoto, encryption_read_formats, [v2]),
    application:set_env(shigoto, require_encrypted, true),
    ok = due(Child),
    ok = due(Plain),
    Seen = [performed(shigoto_canary_other_worker), performed(shigoto_canary_other_worker)],
    ?assertEqual(
        [
            #{~"canary" => Canary},
            #{~"canary" => Canary, deps_results => #{Parent => #{~"secret" => Canary}}}
        ],
        lists:sort([Args || {_Worker, Args} <- Seen])
    ),
    {ok, #{callback_args := Shown}} = shigoto:get_batch(BatchId),
    ?assertEqual(#{~"canary" => Canary}, json:decode(Shown)).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

key(N) ->
    binary:copy(<<N>>, 32).

canary() ->
    <<"CANARY-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>.

%% A canary followed by what a printer has to escape.
random_canary() ->
    iolist_to_binary([canary() | [random_part() || _ <- lists:seq(1, 12)]]).

random_part() ->
    Parts =
        {
            ~"a",
            ~"Z",
            ~"0",
            ~" ",
            ~"_",
            ~".",
            ~":",
            ~"/",
            <<$\\>>,
            <<$">>,
            ~"'",
            ~"{",
            ~"}",
            ~"[",
            ~"]",
            ~"<",
            ~">",
            ~"å",
            ~"ö",
            ~"€"
        },
    element(rand:uniform(tuple_size(Parts)), Parts).

random_extra() ->
    #{
        ~"n" => rand:uniform(1000000),
        ~"nested" => #{~"list" => [rand:uniform(100) || _ <- lists:seq(1, rand:uniform(5))]},
        ~"flag" => rand:uniform(2) =:= 1
    }.

args(Mode, Canary) ->
    #{~"test" => list_to_binary(pid_to_list(self())), ~"mode" => Mode, ~"canary" => Canary}.

enqueue(Mode, Canary) ->
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker, args => args(Mode, Canary)
    }),
    Id.

%% A job that is not due, so its row can be read and copied.
parked(Canary) ->
    {ok, #{id := Id}} = shigoto:insert(#{
        worker => shigoto_canary_worker,
        args => args(~"ok", Canary),
        scheduled_at => seconds_from_now(3600)
    }),
    Id.

insert_row(Worker, Args, MaxAttempts) ->
    #{rows := [#{id := Id}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, max_attempts)
        VALUES ($1, $2, $3::jsonb, $4) RETURNING id
        """,
        [?QUEUE, Worker, Args, MaxAttempts]
    ),
    Id.

stored(Id, Column) ->
    maps:get(Column, row(Id)).

row(Id) ->
    #{rows := [Row]} = shigoto_db:query(?POOL, ~"SELECT * FROM shigoto_jobs WHERE id = $1", [Id]),
    Row.

rows() ->
    #{rows := Jobs} = shigoto_db:query(?POOL, ~"SELECT * FROM shigoto_jobs", []),
    #{rows := Batches} = shigoto_db:query(?POOL, ~"SELECT * FROM shigoto_batches", []),
    Jobs ++ Batches.

job_count() ->
    #{rows := [#{count := Count}]} = shigoto_db:query(
        ?POOL, ~"SELECT count(*) AS count FROM shigoto_jobs", []
    ),
    Count.

errors(#{errors := Errors}) ->
    json:decode(Errors).

due(Id) ->
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET scheduled_at = now() WHERE id = $1", [Id]
    ),
    ok.

performed() ->
    performed(shigoto_canary_worker).

performed(Module) ->
    receive
        {performed, Module, Worker, Args} -> {Worker, Args}
    after 5000 -> ct:fail({never_performed, Module})
    end.

not_performed(Module) ->
    receive
        {performed, Module, _Worker, Args} -> ct:fail({performed, Module, Args})
    after 300 -> ok
    end.

%% What was logged and emitted so far, once the events that follow a job's
%% last write have had time to arrive.
captured() ->
    timer:sleep(100),
    shigoto_event_probe:captured().

%% `ok` when `Canary` is nowhere in `Terms`, printed the way a log handler or
%% an exporter would print them; otherwise the terms it is in. Only the part
%% of the canary that no printer escapes is looked for.
no_canary(<<"CANARY-", Hex:16/binary, _/binary>>, Terms) ->
    Needle = <<"CANARY-", Hex/binary>>,
    case [Term || Term <- Terms, binary:match(printed(Term), Needle) =/= nomatch] of
        [] -> ok;
        Leaks -> {leaked, Leaks}
    end.

printed(Term) when is_binary(Term) ->
    Term;
printed(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp ~0p", [Term, Term])).

%% Take an advisory lock the way any session in the database can, and keep it
%% until released.
hold_lock(SQL, Params) ->
    Test = self(),
    Holder = spawn_link(fun() ->
        shigoto_db:transaction(?POOL, fun() ->
            #{} = shigoto_db:query(?POOL, SQL, Params),
            Test ! {holding, self()},
            receive
                release -> ok
            after 20000 -> ok
            end
        end),
        Test ! {released, self()}
    end),
    receive
        {holding, Holder} -> Holder
    after 5000 -> ct:fail(lock_not_taken)
    end.

release(Holder) ->
    Holder ! release,
    receive
        {released, Holder} -> ok
    after 5000 -> ct:fail(lock_not_released)
    end.

await(Id, State) ->
    await(Id, State, 400).

await(Id, State, 0) ->
    ct:fail({never_reached, State, row(Id)});
await(Id, State, Tries) ->
    case row(Id) of
        #{state := State} = Row ->
            Row;
        _Other ->
            timer:sleep(25),
            await(Id, State, Tries - 1)
    end.

wait_for(Check) ->
    wait_for(Check, 200).

wait_for(_Check, 0) ->
    ct:fail(condition_not_met);
wait_for(Check, Tries) ->
    case Check() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_for(Check, Tries - 1)
    end.

seconds_from_now(Seconds) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(calendar:universal_time()) + Seconds
    ).

connection() ->
    #{
        host => "localhost",
        port => shigoto_test_repo:port(),
        database => "shigoto_test",
        user => "postgres",
        password => "root"
    }.

clean() ->
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_jobs_archive", []),
    _ = shigoto_db:query(?POOL, ~"DELETE FROM shigoto_batches", []),
    ok.
