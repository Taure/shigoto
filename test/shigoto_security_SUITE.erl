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
    a_worker_name_no_module_can_have_is_written_cut/1,
    a_worker_name_is_cut_in_the_entries_a_statement_adds/1,
    args_moved_to_another_column_are_not_decrypted/1,
    a_worker_outside_the_allow_list_is_never_called/1,
    a_job_put_back_for_its_worker_is_not_decrypted/1,
    a_frame_that_does_not_open_fails_the_job/1,
    a_plaintext_job_is_refused_when_encryption_is_required/1,
    a_plaintext_job_is_refused_when_the_setting_became_nonsense/1,
    an_instance_that_became_nonsense_is_not_used/1,
    a_v1_frame_is_refused_once_only_v2_is_read/1,
    v1_is_still_written_and_read_when_set/1,
    v1_is_written_unless_v2_is_set/1,
    v1_leaves_results_and_callback_args_as_1_10_reads_them/1,
    no_failure_stores_or_emits_the_args/1,
    random_args_and_failures_never_leak/1,
    a_running_job_is_held_encrypted/1,
    a_result_is_encrypted_and_reaches_the_dependent/1,
    a_result_moved_to_another_job_is_not_decrypted/1,
    a_result_copied_under_its_own_id_reaches_no_other_job/1,
    a_result_a_job_did_not_wait_for_is_not_handed_to_it/1,
    a_waiting_job_from_before_the_upgrade_gets_its_results/1,
    reencrypt_names_what_a_waiting_job_may_read/1,
    batch_callback_args_are_encrypted/1,
    a_batch_naming_no_worker_gets_no_callback/1,
    replaced_args_are_bound_to_the_existing_row/1,
    a_unique_job_is_still_found_after_key_rotation/1,
    a_unique_job_from_before_encryption_is_still_a_duplicate/1,
    a_unique_insert_sends_no_plaintext_to_the_database/1,
    a_node_without_queues_stops_looking_for_unique_fields_too/1,
    a_check_that_fails_keeps_looking_for_unique_fields/1,
    a_unique_job_is_still_found_once_its_key_is_dropped/1,
    insert_all_inserts_a_unique_job_once/1,
    insert_all_takes_uniqueness_from_its_options/1,
    insert_all_inserts_nothing_when_a_unique_lock_is_held/1,
    two_bulk_inserts_at_once_insert_each_unique_job_once/1,
    a_bulk_insert_rolled_back_leaves_no_unique_job/1,
    unique_states_that_are_no_job_state_are_refused/1,
    keys_that_belong_to_shigoto_are_refused/1,
    insert_all_takes_no_more_unique_locks_than_its_limit/1,
    insert_all_takes_exactly_its_limit_of_unique_locks/1,
    a_full_lock_table_is_answered_not_raised/1,
    a_unique_insert_the_database_refuses_is_answered_not_raised/1,
    an_insert_the_database_refuses_does_not_quote_the_row/1,
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
    unique_lock_limit,
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
        a_worker_name_no_module_can_have_is_written_cut,
        a_worker_name_is_cut_in_the_entries_a_statement_adds,
        args_moved_to_another_column_are_not_decrypted,
        a_worker_outside_the_allow_list_is_never_called,
        a_job_put_back_for_its_worker_is_not_decrypted,
        a_frame_that_does_not_open_fails_the_job,
        a_plaintext_job_is_refused_when_encryption_is_required,
        a_plaintext_job_is_refused_when_the_setting_became_nonsense,
        an_instance_that_became_nonsense_is_not_used,
        a_v1_frame_is_refused_once_only_v2_is_read,
        v1_is_still_written_and_read_when_set,
        v1_is_written_unless_v2_is_set,
        v1_leaves_results_and_callback_args_as_1_10_reads_them,
        no_failure_stores_or_emits_the_args,
        random_args_and_failures_never_leak,
        a_running_job_is_held_encrypted,
        a_result_is_encrypted_and_reaches_the_dependent,
        a_result_moved_to_another_job_is_not_decrypted,
        a_result_copied_under_its_own_id_reaches_no_other_job,
        a_result_a_job_did_not_wait_for_is_not_handed_to_it,
        a_waiting_job_from_before_the_upgrade_gets_its_results,
        reencrypt_names_what_a_waiting_job_may_read,
        batch_callback_args_are_encrypted,
        a_batch_naming_no_worker_gets_no_callback,
        replaced_args_are_bound_to_the_existing_row,
        a_unique_job_is_still_found_after_key_rotation,
        a_unique_job_from_before_encryption_is_still_a_duplicate,
        a_unique_insert_sends_no_plaintext_to_the_database,
        a_node_without_queues_stops_looking_for_unique_fields_too,
        a_check_that_fails_keeps_looking_for_unique_fields,
        a_unique_job_is_still_found_once_its_key_is_dropped,
        insert_all_inserts_a_unique_job_once,
        insert_all_takes_uniqueness_from_its_options,
        insert_all_inserts_nothing_when_a_unique_lock_is_held,
        two_bulk_inserts_at_once_insert_each_unique_job_once,
        a_bulk_insert_rolled_back_leaves_no_unique_job,
        unique_states_that_are_no_job_state_are_refused,
        keys_that_belong_to_shigoto_are_refused,
        insert_all_takes_no_more_unique_locks_than_its_limit,
        insert_all_takes_exactly_its_limit_of_unique_locks,
        a_full_lock_table_is_answered_not_raised,
        a_unique_insert_the_database_refuses_is_answered_not_raised,
        an_insert_the_database_refuses_does_not_quote_the_row,
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
        a_result_copied_under_its_own_id_reaches_no_other_job,
        a_result_a_job_did_not_wait_for_is_not_handed_to_it,
        a_waiting_job_from_before_the_upgrade_gets_its_results,
        reencrypt_names_what_a_waiting_job_may_read,
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
overrides(a_worker_name_no_module_can_have_is_written_cut) ->
    #{unrunnable_snooze_limit => 0};
overrides(a_job_put_back_for_its_worker_is_not_decrypted) ->
    #{workers => [shigoto_canary_worker]};
overrides(a_plaintext_job_is_refused_when_encryption_is_required) ->
    #{require_encrypted => true};
overrides(a_result_copied_under_its_own_id_reaches_no_other_job) ->
    #{require_encrypted => true};
overrides(v1_is_still_written_and_read_when_set) ->
    #{encryption_write_format => v1};
overrides(a_held_unique_lock_does_not_stall_the_insert) ->
    #{advisory_lock_timeout => 200};
overrides(insert_all_inserts_nothing_when_a_unique_lock_is_held) ->
    #{advisory_lock_timeout => 200};
overrides(a_node_without_queues_stops_looking_for_unique_fields_too) ->
    #{queues => [], rescue_interval => 100};
overrides(a_check_that_fails_keeps_looking_for_unique_fields) ->
    #{queues => []};
overrides(insert_all_takes_no_more_unique_locks_than_its_limit) ->
    #{unique_lock_limit => 6};
overrides(insert_all_takes_exactly_its_limit_of_unique_locks) ->
    #{unique_lock_limit => 6};
overrides(a_full_lock_table_is_answered_not_raised) ->
    #{unique_lock_limit => 5000};
overrides(a_held_concurrency_lock_snoozes_the_job) ->
    #{advisory_lock_timeout => 200};
overrides(a_flood_of_notifications_is_rate_limited) ->
    #{poll_interval => 60000, notify_min_interval => 250, notifier => connection()};
overrides(an_insert_the_database_refuses_does_not_quote_the_row) ->
    #{encryption_key => undefined};
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

a_worker_name_no_module_can_have_is_written_cut(_Config) ->
    Name = <<(binary:copy(~"w", 2000))/binary, "-THE-END">>,
    Id = insert_row(Name, ~"{}", 1),
    Row = await(Id, ~"discarded"),
    ?assertMatch([#{~"worker" := <<_:255/binary>>}], errors(Row)),
    ?assertEqual(
        [],
        [
            Term
         || Term <- [maps:get(errors, Row) | captured()],
            binary:match(printed(Term), ~"-THE-END") =/= nomatch
        ]
    ).

%% The rescue and a failed dependency add their entry in the statement, where
%% the name is the row's own text as well.
a_worker_name_is_cut_in_the_entries_a_statement_adds(_Config) ->
    Name = <<(binary:copy(~"w", 2000))/binary, "-THE-END">>,
    #{rows := [#{id := Stale}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, state, attempt, max_attempts, attempted_at)
        VALUES ('parked', $1, '{}'::jsonb, 'executing', 1, 1, now() - interval '1 hour')
        RETURNING id
        """,
        [Name]
    ),
    #{rows := [#{id := Dependent}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, depends_on, on_dependency_failure)
        VALUES ('parked', $1, '{}'::jsonb, ARRAY[$2::bigint], 'discard')
        RETURNING id
        """,
        [Name, Stale]
    ),
    ?assertEqual({ok, 1}, shigoto_repo:rescue_stale_jobs(?POOL, 60)),
    Cut = binary:copy(~"w", 255),
    ?assertMatch(
        [#{~"error" := ~"rescued", ~"worker" := Cut}], errors(await(Stale, ~"discarded"))
    ),
    ?assertMatch(
        [#{~"error" := ~"dependency_failed", ~"worker" := Cut}],
        errors(await(Dependent, ~"discarded"))
    ).

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

%% A setting changed while the node runs is not checked the way the boot
%% checks it. Whatever is not `false` still requires encryption.
a_plaintext_job_is_refused_when_the_setting_became_nonsense(_Config) ->
    Canary = canary(),
    Plain = iolist_to_binary(json:encode(args(~"ok", Canary))),
    [
        begin
            application:set_env(shigoto, require_encrypted, Value),
            Id = insert_row(~"shigoto_canary_worker", Plain, 1),
            Row = await(Id, ~"discarded"),
            ?assertMatch([#{~"error" := ~"plaintext_refused"}], errors(Row))
        end
     || Value <- [yes, "true"]
    ],
    ok = not_performed(shigoto_canary_worker).

%% It is neither read as no instance, which is the lock space and the channel
%% of every unnamed installation, nor written into the trigger function.
an_instance_that_became_nonsense_is_not_used(_Config) ->
    Source = notify_source(),
    try
        [
            begin
                application:set_env(shigoto, instance, Instance),
                Invalid = {shigoto_config, {invalid, instance, Instance}},
                ?assertEqual({error, Invalid}, shigoto_migration:up(?POOL)),
                ?assertError(Invalid, shigoto_lock:acquire_xact(?POOL, [1]))
            end
         || Instance <- [billing, ~"a', NEW.queue); PERFORM pg_sleep(0); PERFORM pg_notify('b"]
        ]
    after
        application:unset_env(shigoto, instance)
    end,
    ?assertEqual(Source, notify_source()).

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
    #{rows := [#{callback_args := <<StoredArgs/binary>>}]} = shigoto_db:query(
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
    seki:reset_breaker({shigoto_breaker, shigoto_canary_worker}).

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

%% A result is bound to the job that produced it, so copied whole, key and
%% all, it opens. What a job may be handed is the results of the jobs it was
%% inserted to wait for, and their ids are sealed in its meta.
a_result_copied_under_its_own_id_reaches_no_other_job(_Config) ->
    Canary = canary(),
    Source = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    #{result := Stolen} = await(Source, ~"completed"),
    %% Args and meta are bound to the worker, not to the row: those of any job
    %% of the target's worker will do.
    {ok, #{id := Donor}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker,
        args => #{},
        scheduled_at => seconds_from_now(3600)
    }),
    Target = insert_waiting_row(
        stored(Donor, args), stored(Donor, meta), #{Source => json:decode(Stolen)}
    ),
    Row = await(Target, ~"discarded"),
    ?assertMatch([#{~"error" := ~"decrypt_failed"}], errors(Row)),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Canary, [Row | captured()]),
    %% The job that was inserted to wait for it is handed it.
    {ok, #{id := Child}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker, args => #{}, depends_on => [Source]
    }),
    {_, ChildArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Source => #{~"secret" => Canary}}, maps:get(deps_results, ChildArgs)),
    _ = await(Child, ~"completed"),
    {ok, #{meta := Meta}} = shigoto:get_job(Child),
    ?assertEqual(#{~"_shigoto_deps" => [Source]}, json:decode(Meta)),
    %% So is one inserted with others.
    {ok, [_, #{id := Bulk}]} = shigoto:insert_all([
        #{worker => shigoto_canary_other_worker, args => #{~"n" => 1}},
        #{worker => shigoto_canary_other_worker, args => #{~"n" => 2}, depends_on => [Source]}
    ]),
    Seen = [performed(shigoto_canary_other_worker), performed(shigoto_canary_other_worker)],
    ?assertEqual(
        [#{~"n" => 1}, #{~"n" => 2, deps_results => #{Source => #{~"secret" => Canary}}}],
        lists:sort([Args || {_Worker, Args} <- Seen])
    ),
    _ = await(Bulk, ~"completed"),
    %% And one whose meta was handed over as JSON text.
    {ok, #{id := Text}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker,
        args => #{~"n" => 3},
        meta => ~"{\"trace\":\"t1\"}",
        depends_on => [Source]
    }),
    {_, TextArgs} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Source => #{~"secret" => Canary}}, maps:get(deps_results, TextArgs)),
    _ = await(Text, ~"completed"),
    {ok, #{meta := TextMeta}} = shigoto:get_job(Text),
    ?assertEqual(#{~"trace" => ~"t1", ~"_shigoto_deps" => [Source]}, json:decode(TextMeta)).

a_result_a_job_did_not_wait_for_is_not_handed_to_it(_Config) ->
    Canary = canary(),
    Other = canary(),
    [Waited, NotWaited] = [enqueue(~"result", C) || C <- [Canary, Other]],
    _ = [performed(shigoto_canary_worker) || _ <- [Waited, NotWaited]],
    _ = await(Waited, ~"completed"),
    #{result := Stolen} = await(NotWaited, ~"completed"),
    {ok, #{id := Child}} = shigoto:insert(#{
        worker => shigoto_canary_other_worker,
        args => #{},
        depends_on => [Waited],
        max_attempts => 1,
        scheduled_at => seconds_from_now(3600)
    }),
    #{} = shigoto_db:query(
        ?POOL,
        ~"""
        UPDATE shigoto_jobs SET scheduled_at = now(),
          deps_results = deps_results || jsonb_build_object($2::text, $3::jsonb)
        WHERE id = $1
        """,
        [Child, integer_to_binary(NotWaited), Stolen]
    ),
    Row = await(Child, ~"discarded"),
    ?assertMatch([#{~"error" := ~"decrypt_failed"}], errors(Row)),
    ok = not_performed(shigoto_canary_other_worker),
    ok = no_canary(Other, [Row | captured()]).

%% A job a release before this one inserted has no list. It runs while
%% plaintext is still accepted, which is how long the upgrade takes.
a_waiting_job_from_before_the_upgrade_gets_its_results(_Config) ->
    Canary = canary(),
    Source = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    #{result := Result} = await(Source, ~"completed"),
    Sealed = shigoto_crypto:seal(~"{}", {args, ~"shigoto_canary_other_worker"}),
    Old = insert_waiting_row(Sealed, ~"{}", #{Source => json:decode(Result)}),
    {_, Args} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Source => #{~"secret" => Canary}}, maps:get(deps_results, Args)),
    _ = await(Old, ~"completed").

%% `shigoto:reencrypt/0,1` is what the upgrade runs before it sets
%% `require_encrypted`, so it gives such a job its list.
reencrypt_names_what_a_waiting_job_may_read(_Config) ->
    Canary = canary(),
    Done = enqueue(~"result", Canary),
    _ = performed(shigoto_canary_worker),
    #{result := Result} = await(Done, ~"completed"),
    Pending = parked(Canary),
    Sealed = shigoto_crypto:seal(~"{}", {args, ~"shigoto_canary_other_worker"}),
    Old = insert_waiting_row(Sealed, ~"{\"trace\": \"t1\"}", #{Done => json:decode(Result)}, [
        Pending
    ]),
    {ok, #{jobs := #{failed := 0, skipped := 0}}} = shigoto:reencrypt(),
    {ok, #{meta := Meta}} = shigoto:get_job(Old),
    ?assertEqual(
        #{~"trace" => ~"t1", ~"_shigoto_deps" => lists:sort([Done, Pending])}, json:decode(Meta)
    ),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, stored(Old, meta)),
    {ok, #{jobs := Again}} = shigoto:reencrypt(),
    ?assertMatch(#{rewritten := 0, failed := 0, skipped := 0}, Again),
    application:set_env(shigoto, require_encrypted, true),
    #{} = shigoto_db:query(
        ?POOL, ~"UPDATE shigoto_jobs SET depends_on = '{}' WHERE id = $1", [Old]
    ),
    {_, Args} = performed(shigoto_canary_other_worker),
    ?assertEqual(#{Done => #{~"secret" => Canary}}, maps:get(deps_results, Args)),
    _ = await(Old, ~"completed").

%% A row of `shigoto_canary_other_worker` written to the table directly, with
%% results in it.
insert_waiting_row(Args, Meta, Results) ->
    insert_waiting_row(Args, Meta, Results, []).

insert_waiting_row(Args, Meta, Results, DependsOn) ->
    DepsResults = iolist_to_binary(
        json:encode(#{integer_to_binary(Id) => Result || Id := Result <- Results})
    ),
    #{rows := [#{id := Id}]} = shigoto_db:query(
        ?POOL,
        ~"""
        INSERT INTO shigoto_jobs (queue, worker, args, meta, deps_results, depends_on, max_attempts)
        VALUES ($1, 'shigoto_canary_other_worker', $2::jsonb, $3::jsonb, $4::jsonb, $5, 1)
        RETURNING id
        """,
        [?QUEUE, Args, Meta, DepsResults, DependsOn]
    ),
    Id.

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
    ok = restart(),
    ?assert(shigoto_repo:raw_unique_keys(?POOL)),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)),
    %% The raw form is looked for, never stored.
    {ok, #{unique_key := Hashed}} = shigoto:insert(Params#{args => #{~"n" => 2}}, Unique),
    ?assertEqual(64, byte_size(Hashed)),
    ?assertEqual(nomatch, binary:match(Hashed, ~"shigoto_canary_other_worker")),
    %% reencrypt moves the old job's key to the hash, after which the raw
    %% form no longer has to be looked for.
    {ok, #{jobs := #{failed := 0, skipped := 0}}} = shigoto:reencrypt(),
    ?assertEqual(shigoto_crypto:unique_key(Material), stored(Id, unique_key)),
    ?assertNot(shigoto_repo:raw_unique_keys(?POOL)),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)),
    application:set_env(shigoto, require_encrypted, true),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)).

%% PostgreSQL can log the parameters of a statement, to a place that is
%% usually less protected than the table.
a_unique_insert_sends_no_plaintext_to_the_database(_Config) ->
    Canary = canary(),
    Unique = #{unique => #{keys => [worker, args, queue]}},
    Params = #{
        worker => shigoto_canary_other_worker,
        args => #{~"canary" => Canary},
        scheduled_at => seconds_from_now(3600)
    },
    {Inserted, Sent} = shigoto_statement_probe:sent(shigoto, insert, [Params, Unique]),
    ?assertMatch({ok, #{id := _}}, Inserted),
    ?assertMatch([_ | _], Sent),
    ok = no_canary(Canary, Sent),
    {Again, SentAgain} = shigoto_statement_probe:sent(shigoto, insert_all, [
        [Params, Params#{args => #{~"canary" => Canary, ~"n" => 2}}], Unique
    ]),
    ?assertMatch({ok, [_, _]}, Again),
    ok = no_canary(Canary, SentAgain),
    ?assertEqual(2, job_count()),
    %% A job from before the key was configured has its unique fields in the
    %% clear in the table already, and is only found by them.
    ok = clean(),
    Older = canary(),
    application:unset_env(shigoto, encryption_key),
    {ok, #{id := Id}} = shigoto:insert(Params#{args => #{~"canary" => Older}}, Unique),
    application:set_env(shigoto, encryption_key, key(1)),
    ok = restart(),
    ?assertMatch(
        {ok, {conflict, #{id := Id}}},
        shigoto:insert(Params#{args => #{~"canary" => Older}}, Unique)
    ),
    %% Until reencrypt has replaced the last of them.
    {ok, #{jobs := #{failed := 0, skipped := 0}}} = shigoto:reencrypt(),
    {Found, SentAfter} = shigoto_statement_probe:sent(shigoto, insert, [
        Params#{args => #{~"canary" => Older}}, Unique
    ]),
    ?assertMatch({ok, {conflict, #{id := Id}}}, Found),
    ok = no_canary(Older, SentAfter).

%% `shigoto:reencrypt/0,1` on another node replaces the last unique key in the
%% clear. A node that only inserts makes no rescue pass, and finds out as well.
a_node_without_queues_stops_looking_for_unique_fields_too(_Config) ->
    Unique = #{unique => #{keys => [worker, args]}},
    Params = (waiting(shigoto_canary_other_worker, 1))#{queue => ~"parked"},
    application:unset_env(shigoto, encryption_key),
    {ok, #{id := Id}} = shigoto:insert(Params, Unique),
    application:set_env(shigoto, encryption_key, key(1)),
    ok = restart(),
    ?assert(shigoto_repo:raw_unique_keys(?POOL)),
    #{num_rows := 1} = shigoto_db:query(
        ?POOL,
        ~"UPDATE shigoto_jobs SET unique_key = $2 WHERE id = $1",
        [Id, shigoto_crypto:unique_key(~"{\"n\":1}:shigoto_canary_other_worker")]
    ),
    ok = wait_for(fun() -> not shigoto_repo:raw_unique_keys(?POOL) end),
    ?assertMatch({ok, {conflict, #{id := Id}}}, shigoto:insert(Params, Unique)).

%% Whether a unique key is stored in the clear is not known while the check
%% fails. Taken as "none is", a duplicate of a job from before the key would
%% be inserted without a word.
a_check_that_fails_keeps_looking_for_unique_fields(_Config) ->
    ?assertNot(shigoto_repo:raw_unique_keys(?POOL)),
    _ = captured(),
    ok = renamed(~"shigoto_jobs", ~"shigoto_jobs_away"),
    try
        ok = shigoto_repo:raw_unique_keys_forgotten(?POOL),
        ?assert(shigoto_repo:raw_unique_keys(?POOL)),
        ?assert(shigoto_repo:raw_unique_keys_checked(?POOL)),
        ok = shigoto_repo:raw_unique_keys_rechecked(?POOL)
    after
        ok = renamed(~"shigoto_jobs_away", ~"shigoto_jobs")
    end,
    %% Said once, however often it fails.
    ?assertMatch(
        [#{reason := {pgsql_error, #{code := ~"42P01"}}}],
        [
            Report
         || {log, #{msg := {report, #{msg := ~"shigoto_raw_unique_check_failed"} = Report}}} <-
                captured()
        ]
    ),
    %% Kept, and asked again on the rescuer's tick until the database answers.
    ?assert(shigoto_repo:raw_unique_keys(?POOL)),
    ok = shigoto_repo:raw_unique_keys_rechecked(?POOL),
    ?assertNot(shigoto_repo:raw_unique_keys(?POOL)).

renamed(From, To) ->
    #{} = shigoto_db:query(?POOL, [~"ALTER TABLE ", From, ~" RENAME TO ", To], []),
    ok.

%% What a node does when its configuration is changed: it starts again.
restart() ->
    ok = application:stop(shigoto),
    {ok, _} = application:ensure_all_started(shigoto),
    ok.

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
    Test = self(),
    Inserters = [
        spawn_monitor(fun() ->
            Jobs = [waiting(shigoto_unique_worker, N) || N <- Order],
            Test ! {answered, self(), shigoto:insert_all(Jobs)}
        end)
     || Order <- [lists:seq(1, 300), lists:seq(300, 1, -1)]
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

%% Every unique job of a call holds its advisory locks until the call ends,
%% and the lock table is one for the whole server.
unique_states_that_are_no_job_state_are_refused(_Config) ->
    {ok, #{id := Other}} = shigoto:insert(waiting(shigoto_canary_other_worker, 1)),
    Job = waiting(shigoto_canary_worker, 1),
    %% Put into the statement as it is, this matched every job in the table.
    Quoted = 'available\') OR (\'1\' = \'1',
    [
        begin
            Refused = {error, {invalid_unique_states, States}},
            ?assertEqual(Refused, shigoto:insert(Job, #{unique => #{states => States}})),
            ?assertEqual(Refused, shigoto:insert_all([Job], #{unique => #{states => States}}))
        end
     || States <- [[Quoted], [available, scheduled], [~"available"], [], available]
    ],
    ?assertEqual(1, job_count()),
    Every = [available, executing, retryable, completed, discarded, cancelled],
    {ok, #{id := Id}} = shigoto:insert(Job, #{unique => #{states => Every}}),
    ?assertNotEqual(Other, Id),
    ?assertMatch(
        {ok, {conflict, #{id := Id}}}, shigoto:insert(Job, #{unique => #{states => Every}})
    ).

keys_that_belong_to_shigoto_are_refused(_Config) ->
    Job = waiting(shigoto_canary_worker, 1),
    [
        begin
            Refused = {error, {reserved_key, meta, ~"_shigoto_deps"}},
            ?assertEqual(Refused, shigoto:insert(Job#{meta => Meta})),
            ?assertEqual(Refused, shigoto:insert_all([Job, Job#{meta => Meta}]))
        end
     || Meta <- [
            #{~"_shigoto_deps" => [1], ~"mine" => 1},
            #{'_shigoto_deps' => [1]},
            ~"{\"_shigoto_deps\":[1]}"
        ]
    ],
    ?assertEqual(0, job_count()),
    %% A carrier handed over by hand is the one key a caller may set.
    Carrier = #{~"traceparent" => ~"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"},
    {ok, #{id := Id}} = shigoto:insert(Job#{
        meta => #{~"_shigoto_carrier" => Carrier, ~"_mine" => 1}
    }),
    {ok, #{meta := Meta}} = shigoto:get_job(Id),
    ?assertEqual(#{~"_shigoto_carrier" => Carrier, ~"_mine" => 1}, json:decode(Meta)),
    [
        ?assertEqual(
            {error, {reserved_key, callback_args, Key}},
            shigoto:new_batch(#{
                callback_worker => shigoto_batch_callback_worker,
                callback_args => #{Key => ~"discard", ~"mine" => 1}
            })
        )
     || Key <- [~"_batch_event", ~"_shigoto_anything"]
    ],
    ?assertEqual(
        {error, {reserved_key, callback_args, ~"_batch_event"}},
        shigoto:new_batch(#{callback_args => ~"{\"_batch_event\":\"discard\"}"})
    ),
    ?assertMatch(
        #{rows := [#{count := 0}]},
        shigoto_db:query(?POOL, ~"SELECT count(*) AS count FROM shigoto_batches", [])
    ).

insert_all_takes_no_more_unique_locks_than_its_limit(_Config) ->
    _ = captured(),
    Unique = [waiting(shigoto_unique_worker, N) || N <- lists:seq(1, 7)],
    Plain = [waiting(shigoto_canary_other_worker, N) || N <- lists:seq(1, 20)],
    {error, {too_many_unique_locks, Needed, 6}} = shigoto:insert_all(Plain ++ Unique),
    ?assert(Needed >= 7),
    ?assertEqual(0, job_count()),
    ?assertEqual([], inserted_events()),
    %% Jobs that are not unique take no lock and do not count.
    [First, Second, Third | _] = Unique,
    ?assertMatch({ok, [_ | _]}, shigoto:insert_all(Plain ++ [First, Second, Third])),
    ?assertEqual(23, job_count()).

%% One key and no unique key in the clear: a unique job takes one lock.
insert_all_takes_exactly_its_limit_of_unique_locks(_Config) ->
    Unique = [waiting(shigoto_unique_worker, N) || N <- lists:seq(1, 7)],
    ?assertEqual({error, {too_many_unique_locks, 7, 6}}, shigoto:insert_all(Unique)),
    ?assertEqual(0, job_count()),
    [_Seventh | AtTheLimit] = Unique,
    ?assertMatch({ok, [_, _, _, _, _, _]}, shigoto:insert_all(AtTheLimit)),
    ?assertEqual(6, job_count()).

a_full_lock_table_is_answered_not_raised(_Config) ->
    Jobs = [waiting(shigoto_unique_worker, N) || N <- lists:seq(1, 600)],
    Holder = fill_lock_table(),
    try
        ?assertMatch({error, {pgsql_error, #{code := ~"53200"}}}, shigoto:insert_all(Jobs)),
        {error, {pgsql_error, #{} = Fields}} = shigoto:insert_all(Jobs),
        ?assertEqual([], maps:keys(maps:without([code, severity, severity_non_localised], Fields))),
        ?assertEqual(0, job_count())
    after
        ok = release(Holder)
    end,
    ?assertMatch({ok, [_ | _]}, shigoto:insert_all(Jobs)),
    ?assertEqual(600, job_count()).

%% Another session takes advisory locks until PostgreSQL has no room for 500
%% more, and keeps what it got.
fill_lock_table() ->
    Test = self(),
    Holder = spawn_link(fun() ->
        shigoto_db:transaction(?POOL, fun() ->
            ok = filled(1 bsl 40),
            Test ! {holding, self()},
            receive
                release -> ok
            after 60000 -> ok
            end
        end),
        Test ! {released, self()}
    end),
    receive
        {holding, Holder} -> Holder
    after 60000 -> ct:fail(lock_table_not_filled)
    end.

filled(From) ->
    #{} = shigoto_db:query(?POOL, ~"SAVEPOINT filling", []),
    Taken = shigoto_db:query(
        ?POOL,
        ~"SELECT count(pg_advisory_xact_lock(key)) AS taken FROM generate_series($1::bigint, $2::bigint) key",
        [From, From + 499]
    ),
    case Taken of
        #{rows := [#{taken := 500}]} ->
            #{} = shigoto_db:query(?POOL, ~"RELEASE SAVEPOINT filling", []),
            filled(From + 500);
        {error, {pgsql_error, #{code := ~"53200"}}} ->
            #{} = shigoto_db:query(?POOL, ~"ROLLBACK TO SAVEPOINT filling", []),
            ok
    end.

a_unique_insert_the_database_refuses_is_answered_not_raised(_Config) ->
    ok = refusing(~"BEFORE INSERT", ~"NEW.worker = 'shigoto_unique_worker'"),
    try
        {error, {pgsql_error, Fields}} = shigoto:insert(waiting(shigoto_unique_worker, 1)),
        ?assertMatch(#{code := ~"P0001"}, Fields),
        ?assertNot(is_map_key(message, Fields)),
        ?assertMatch(
            {error, {pgsql_error, #{code := ~"P0001"}}},
            shigoto:insert_all([
                waiting(shigoto_canary_other_worker, 1), waiting(shigoto_unique_worker, 1)
            ])
        ),
        ?assertEqual(0, job_count())
    after
        ok = accepting()
    end,
    ?assertMatch({ok, #{id := _}}, shigoto:insert(waiting(shigoto_unique_worker, 1))).

%% PostgreSQL quotes the row a constraint refused in the `detail` of its
%% error ("Failing row contains ..."), args and all.
an_insert_the_database_refuses_does_not_quote_the_row(_Config) ->
    Canary = canary(),
    Job = (waiting(shigoto_canary_other_worker, 1))#{
        args => #{~"canary" => Canary}, priority => 1000
    },
    #{} = shigoto_db:query(
        ?POOL,
        ~"ALTER TABLE shigoto_jobs ADD CONSTRAINT shigoto_test_priority CHECK (priority < 1000)",
        []
    ),
    try
        Refusals = [
            shigoto:insert(Job),
            shigoto:insert_all([Job, Job]),
            shigoto:insert(Job, #{unique => #{keys => [worker]}}),
            shigoto:insert_all([Job, Job], #{unique => #{keys => [worker]}})
        ],
        ?assertMatch(
            [{error, {pgsql_error, #{code := ~"23514", constraint := ~"shigoto_test_priority"}}}],
            lists:usort([
                {error, {pgsql_error, maps:with([code, constraint], Fields)}}
             || {error, {pgsql_error, #{} = Fields}} <- Refusals
            ])
        ),
        ?assertEqual(
            lists:duplicate(4, [code, constraint, severity, severity_non_localised]),
            [lists:sort(maps:keys(Fields)) || {error, {pgsql_error, #{} = Fields}} <- Refusals]
        ),
        ok = no_canary(Canary, Refusals),
        ?assertEqual(0, job_count())
    after
        #{} = shigoto_db:query(
            ?POOL, ~"ALTER TABLE shigoto_jobs DROP CONSTRAINT IF EXISTS shigoto_test_priority", []
        )
    end.

refusing(Timing, When) ->
    #{} = shigoto_db:query(
        ?POOL,
        ~"""
        CREATE OR REPLACE FUNCTION shigoto_test_refuse() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'refused by the test'; END
        $$ LANGUAGE plpgsql
        """,
        []
    ),
    #{} = shigoto_db:query(
        ?POOL,
        [
            ~"CREATE TRIGGER shigoto_test_refuse ",
            Timing,
            ~" ON shigoto_jobs FOR EACH ROW WHEN (",
            When,
            ~") EXECUTE FUNCTION shigoto_test_refuse()"
        ],
        []
    ),
    ok.

accepting() ->
    #{} = shigoto_db:query(
        ?POOL, ~"DROP TRIGGER IF EXISTS shigoto_test_refuse ON shigoto_jobs", []
    ),
    #{} = shigoto_db:query(?POOL, ~"DROP FUNCTION IF EXISTS shigoto_test_refuse()", []),
    ok.

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

-spec waiting(module(), integer()) -> map().
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
