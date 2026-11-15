-module(shigoto_config_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SETTINGS, [
    repo,
    pool,
    queues,
    fanout_queues,
    poll_interval,
    prune_after_days,
    notifier,
    middleware,
    queue_weights,
    fair_queues,
    encryption_key,
    encryption_keys,
    stage_interval,
    heartbeat_interval,
    rescue_interval,
    shutdown_timeout,
    on_discard_timeout,
    unrunnable_snooze_limit,
    archive_after_days,
    cron,
    load_shedding,
    encryption_write_format,
    encryption_read_formats,
    require_encrypted,
    workers,
    instance,
    advisory_lock_timeout,
    unique_lock_limit,
    notify_min_interval,
    on_dependency_failure,
    propagator,
    testing,
    testing_confirm_no_persistence
]).

config_test_() ->
    {foreach, fun unset/0, fun(_) -> unset() end, [
        fun defaults_when_nothing_is_set/0,
        fun a_setting_of_the_wrong_type_fails_by_name/0,
        fun a_pool_that_is_not_set_fails_by_name/0,
        fun a_queue_entry_is_handed_on_as_written/0,
        fun weights_and_fair_queues_keep_what_can_match_a_queue/0,
        fun a_key_that_is_not_a_binary_is_never_in_the_error/0,
        fun middleware_has_to_be_funs_of_two/0,
        fun every_setting_is_checked_before_anything_starts/0,
        fun a_time_that_is_zero_or_negative_is_refused_where_it_is_read/0,
        fun a_refused_key_is_named_by_its_position/0,
        fun every_default_is_the_documented_one/0,
        fun a_setting_is_read_as_configured/0,
        fun a_setting_read_leniently_falls_back/0,
        fun only_false_turns_required_encryption_off/0,
        fun an_instance_that_is_not_a_valid_name_is_never_used/0,
        fun the_smallest_value_of_a_setting_is_accepted/0,
        fun a_testing_mode_needs_its_confirmation/0,
        fun the_shutdown_budget_counts_every_queue/0,
        fun a_job_is_stale_after_two_heartbeats/0,
        fun an_instance_names_its_own_channel/0,
        fun a_complete_configuration_passes_the_check/0,
        fun requiring_encryption_needs_a_key/0
    ]}.

unset() ->
    [application:unset_env(shigoto, Setting) || Setting <- ?SETTINGS],
    ok.

defaults_when_nothing_is_set() ->
    ?assertEqual([{~"default", 10}], shigoto_config:queues()),
    ?assertEqual([], shigoto_config:fanout_queues()),
    ?assertEqual(5000, shigoto_config:poll_interval()),
    ?assertEqual(14, shigoto_config:prune_after_days()),
    ?assertEqual(undefined, shigoto_config:notifier_config()),
    ?assertEqual([], shigoto_config:middleware()),
    ?assertEqual(#{}, shigoto_config:queue_weights()),
    ?assertEqual([], shigoto_config:fair_queues()),
    ?assertEqual(undefined, shigoto_config:encryption_key()),
    ?assertEqual([], shigoto_config:encryption_keys()).

a_setting_of_the_wrong_type_fails_by_name() ->
    application:set_env(shigoto, poll_interval, ~"5000"),
    ?assertError(
        {shigoto_config, {invalid, poll_interval, ~"5000"}}, shigoto_config:poll_interval()
    ),
    application:set_env(shigoto, prune_after_days, 1.5),
    ?assertError(
        {shigoto_config, {invalid, prune_after_days, 1.5}}, shigoto_config:prune_after_days()
    ),
    application:set_env(shigoto, queues, not_a_list),
    ?assertError({shigoto_config, {invalid, queues, not_a_list}}, shigoto_config:queues()),
    %% A notifier setting holds a password, so it is not echoed.
    application:set_env(shigoto, notifier, [{password, ~"secret"}]),
    ?assertError(
        {shigoto_config, {invalid, notifier, not_a_map}}, shigoto_config:notifier_config()
    ),
    application:set_env(shigoto, repo, ~"my_repo"),
    ?assertError({shigoto_config, {invalid, repo, ~"my_repo"}}, shigoto_config:pool()),
    application:unset_env(shigoto, repo),
    application:set_env(shigoto, pool, ~"my_pool"),
    ?assertError({shigoto_config, {invalid, pool, ~"my_pool"}}, shigoto_config:pool()).

a_pool_that_is_not_set_fails_by_name() ->
    ?assertError({shigoto_config, {invalid, pool, undefined}}, shigoto_config:pool()),
    application:set_env(shigoto, pool, my_pool),
    ?assertEqual(my_pool, shigoto_config:pool()),
    application:set_env(shigoto, repo, my_repo),
    ?assertEqual(my_repo, shigoto_config:pool()).

%% A queue whose entry is wrong fails when it starts, on its own, which the
%% boot suite covers. Reading the setting does not refuse it for every queue.
a_queue_entry_is_handed_on_as_written() ->
    application:set_env(shigoto, queues, [{~"mail", 5}, {~"odd", many}, not_an_entry]),
    ?assertEqual([{~"mail", 5}, {~"odd", many}], shigoto_config:queues()),
    application:set_env(shigoto, fanout_queues, [{~"events", 2, #{}}, {~"bad", 1, not_a_map}, 3]),
    ?assertEqual(
        [{~"events", 2, #{}}, {~"bad", 1, not_a_map}], shigoto_config:fanout_queues()
    ).

weights_and_fair_queues_keep_what_can_match_a_queue() ->
    application:set_env(shigoto, queue_weights, #{~"mail" => 3, mail => 2, ~"odd" => heavy}),
    ?assertEqual(#{~"mail" => 3}, shigoto_config:queue_weights()),
    application:set_env(shigoto, fair_queues, [~"mail", mail]),
    ?assertEqual([~"mail"], shigoto_config:fair_queues()).

a_key_that_is_not_a_binary_is_never_in_the_error() ->
    application:set_env(shigoto, encryption_key, "a key written as a string"),
    ?assertError(
        {shigoto_config, {invalid, encryption_key, not_a_binary}}, shigoto_config:encryption_key()
    ),
    application:set_env(shigoto, encryption_keys, [crypto:strong_rand_bytes(32), a_key]),
    ?assertError(
        {shigoto_config, {invalid, encryption_keys, not_a_binary}},
        shigoto_config:encryption_keys()
    ),
    %% The boot check names the setting and the position.
    ?assertEqual(
        {error, {invalid, encryption_keys, #{position => 2, problem => not_a_binary}}},
        shigoto_crypto:check_keys()
    ).

middleware_has_to_be_funs_of_two() ->
    Middleware = fun(_Job, Next) -> Next() end,
    application:set_env(shigoto, middleware, [Middleware]),
    ?assertEqual([Middleware], shigoto_config:middleware()),
    application:set_env(shigoto, middleware, [{some_module, some_function}]),
    ?assertError(
        {shigoto_config, {invalid, middleware, {some_module, some_function}}},
        shigoto_config:middleware()
    ).

%% One shape for every setting the application refuses to start with:
%% `{shigoto_config, {invalid, Setting, Value}}`.
every_setting_is_checked_before_anything_starts() ->
    application:set_env(shigoto, pool, some_pool),
    ?assertEqual(ok, shigoto_config:check()),
    Refused = [
        {repo, ~"my_repo"},
        {queues, not_a_list},
        {fanout_queues, not_a_list},
        {cron, not_a_list},
        {middleware, [not_a_fun]},
        {queue_weights, []},
        {fair_queues, a_queue},
        {poll_interval, 0},
        {poll_interval, -1},
        {poll_interval, "5000"},
        {stage_interval, 0},
        {heartbeat_interval, 0},
        {rescue_interval, -5},
        {on_discard_timeout, 0},
        {unrunnable_snooze_limit, -1},
        {unrunnable_snooze_limit, 51},
        {unrunnable_snooze_limit, infinity},
        {shutdown_timeout, -1},
        {prune_after_days, -1},
        {archive_after_days, soon},
        {encryption_write_format, v3},
        {encryption_read_formats, []},
        {encryption_read_formats, [v3]},
        {require_encrypted, yes},
        {workers, a_module},
        {workers, [~"a_module"]},
        {instance, ~"Not Valid"},
        {instance, billing},
        {advisory_lock_timeout, -1},
        {unique_lock_limit, 0},
        {unique_lock_limit, 5001},
        {unique_lock_limit, infinity},
        {notify_min_interval, soon},
        {on_dependency_failure, sometimes},
        {propagator, lists}
    ],
    _ = [
        begin
            application:set_env(shigoto, Setting, Value),
            ?assertEqual(
                {Setting, {error, {shigoto_config, {invalid, Setting, refused(Setting, Value)}}}},
                {Setting, shigoto_config:check()}
            ),
            application:unset_env(shigoto, Setting)
        end
     || {Setting, Value} <- Refused
    ],
    application:set_env(shigoto, notifier, [{password, ~"secret"}]),
    ?assertEqual({error, {shigoto_config, {invalid, notifier, not_a_map}}}, shigoto_config:check()),
    application:unset_env(shigoto, notifier),
    application:set_env(shigoto, load_shedding, [{max_in_flight, 10}]),
    ?assertEqual(
        {error, {shigoto_config, {invalid, load_shedding, not_a_map}}}, shigoto_config:check()
    ),
    application:unset_env(shigoto, load_shedding),
    application:unset_env(shigoto, pool),
    ?assertEqual({error, {shigoto_config, {invalid, pool, undefined}}}, shigoto_config:check()).

%% The entry that is wrong, not the whole list.
refused(middleware, [Entry]) -> Entry;
refused(_Setting, Value) -> Value.

a_time_that_is_zero_or_negative_is_refused_where_it_is_read() ->
    application:set_env(shigoto, poll_interval, 0),
    ?assertError({shigoto_config, {invalid, poll_interval, 0}}, shigoto_config:poll_interval()),
    application:set_env(shigoto, heartbeat_interval, -30000),
    ?assertError(
        {shigoto_config, {invalid, heartbeat_interval, -30000}},
        shigoto_config:heartbeat_interval()
    ),
    %% Not waiting at shutdown, and keeping nothing, are things to ask for.
    application:set_env(shigoto, shutdown_timeout, 0),
    ?assertEqual(0, shigoto_config:shutdown_timeout()),
    application:set_env(shigoto, prune_after_days, 0),
    ?assertEqual(0, shigoto_config:prune_after_days()),
    %% So is failing a job at once that this node cannot run.
    ?assertEqual(20, shigoto_config:unrunnable_snooze_limit()),
    application:set_env(shigoto, unrunnable_snooze_limit, 0),
    ?assertEqual(0, shigoto_config:unrunnable_snooze_limit()),
    application:set_env(shigoto, unrunnable_snooze_limit, 50),
    ?assertEqual(50, shigoto_config:unrunnable_snooze_limit()),
    ?assertEqual(1000, shigoto_config:unique_lock_limit()),
    application:set_env(shigoto, unique_lock_limit, 1),
    ?assertEqual(1, shigoto_config:unique_lock_limit()),
    application:set_env(shigoto, unique_lock_limit, 5000),
    ?assertEqual(5000, shigoto_config:unique_lock_limit()),
    application:set_env(shigoto, unique_lock_limit, 5001),
    ?assertError(
        {shigoto_config, {invalid, unique_lock_limit, 5001}}, shigoto_config:unique_lock_limit()
    ).

a_refused_key_is_named_by_its_position() ->
    application:set_env(shigoto, pool, some_pool),
    Short = ~"sixteen byte key",
    application:set_env(shigoto, encryption_key, Short),
    ?assertEqual(
        {error,
            {shigoto_config, {invalid, encryption_key, #{position => 1, problem => {bytes, 16}}}}},
        shigoto_config:check()
    ),
    application:unset_env(shigoto, encryption_key),
    Key = crypto:strong_rand_bytes(32),
    application:set_env(shigoto, encryption_keys, [Key, crypto:strong_rand_bytes(32), Key]),
    ?assertEqual(
        {error, {shigoto_config, {invalid, encryption_keys, #{problem => duplicate_key}}}},
        shigoto_config:check()
    ).

every_default_is_the_documented_one() ->
    ?assertEqual(1000, shigoto_config:stage_interval()),
    ?assertEqual(30000, shigoto_config:heartbeat_interval()),
    ?assertEqual(60000, shigoto_config:rescue_interval()),
    ?assertEqual(15000, shigoto_config:shutdown_timeout()),
    ?assertEqual(60000, shigoto_config:on_discard_timeout()),
    ?assertEqual(90, shigoto_config:archive_after_days()),
    ?assertEqual(5000, shigoto_config:advisory_lock_timeout()),
    ?assertEqual(10, shigoto_config:notify_min_interval()),
    ?assertEqual(run, shigoto_config:on_dependency_failure()),
    ?assertEqual(undefined, shigoto_config:load_shedding()),
    ?assertEqual(undefined, shigoto_config:propagator()),
    ?assertEqual(v1, shigoto_config:encryption_write_format()),
    ?assertEqual([v1, v2], shigoto_config:encryption_read_formats()),
    ?assertEqual(false, shigoto_config:require_encrypted()),
    ?assertEqual(undefined, shigoto_config:workers()),
    ?assertEqual(undefined, shigoto_config:instance()),
    ?assertEqual(disabled, shigoto_config:testing_mode()).

a_setting_is_read_as_configured() ->
    Key = crypto:strong_rand_bytes(32),
    Older = crypto:strong_rand_bytes(32),
    Configured = #{
        encryption_key => Key,
        encryption_keys => [Key, Older],
        load_shedding => #{max_in_flight => 10},
        notifier => #{host => "localhost"},
        propagator => shigoto_fake_propagator,
        encryption_write_format => v2,
        encryption_read_formats => [v2, v1],
        require_encrypted => true,
        workers => [shigoto_test_worker],
        instance => ~"billing",
        advisory_lock_timeout => 250,
        notify_min_interval => 25,
        on_dependency_failure => cancel
    },
    [application:set_env(shigoto, Setting, Value) || Setting := Value <- Configured],
    ?assertEqual(Key, shigoto_config:encryption_key()),
    ?assertEqual([Key, Older], shigoto_config:encryption_keys()),
    ?assertEqual(#{max_in_flight => 10}, shigoto_config:load_shedding()),
    ?assertEqual(#{host => "localhost"}, shigoto_config:notifier_config()),
    ?assertEqual(shigoto_fake_propagator, shigoto_config:propagator()),
    ?assertEqual(v2, shigoto_config:encryption_write_format()),
    ?assertEqual([v1, v2], shigoto_config:encryption_read_formats()),
    ?assertEqual(true, shigoto_config:require_encrypted()),
    ?assertEqual([shigoto_test_worker], shigoto_config:workers()),
    ?assertEqual(~"billing", shigoto_config:instance()),
    ?assertEqual(250, shigoto_config:advisory_lock_timeout()),
    ?assertEqual(25, shigoto_config:notify_min_interval()),
    ?assertEqual(cancel, shigoto_config:on_dependency_failure()),
    application:set_env(shigoto, encryption_read_formats, [v2]),
    ?assertEqual([v2], shigoto_config:encryption_read_formats()).

%% `check/0` refuses these values at boot. Set later, while jobs run, they do
%% not raise where they are read, and what they fall back to is the careful
%% side: nothing is read, no worker is allowed, plaintext is refused.
a_setting_read_leniently_falls_back() ->
    Odd = #{
        propagator => ~"a_module",
        encryption_read_formats => v2,
        require_encrypted => yes,
        workers => a_module,
        advisory_lock_timeout => -1,
        notify_min_interval => -1
    },
    [application:set_env(shigoto, Setting, Value) || Setting := Value <- Odd],
    ?assertEqual(undefined, shigoto_config:propagator()),
    ?assertEqual([], shigoto_config:encryption_read_formats()),
    ?assertEqual(true, shigoto_config:require_encrypted()),
    ?assertEqual([], shigoto_config:workers()),
    ?assertEqual(5000, shigoto_config:advisory_lock_timeout()),
    ?assertEqual(10, shigoto_config:notify_min_interval()),
    application:set_env(shigoto, advisory_lock_timeout, soon),
    application:set_env(shigoto, notify_min_interval, soon),
    ?assertEqual(5000, shigoto_config:advisory_lock_timeout()),
    ?assertEqual(10, shigoto_config:notify_min_interval()).

the_smallest_value_of_a_setting_is_accepted() ->
    application:set_env(shigoto, poll_interval, 1),
    ?assertEqual(1, shigoto_config:poll_interval()),
    application:set_env(shigoto, advisory_lock_timeout, 0),
    ?assertEqual(0, shigoto_config:advisory_lock_timeout()),
    application:set_env(shigoto, notify_min_interval, 0),
    ?assertEqual(0, shigoto_config:notify_min_interval()),
    application:set_env(shigoto, pool, some_pool),
    ?assertEqual(ok, shigoto_config:check()).

a_testing_mode_needs_its_confirmation() ->
    application:set_env(shigoto, testing, inline),
    ?assertEqual(disabled, shigoto_config:testing_mode()),
    application:set_env(shigoto, testing_confirm_no_persistence, yes),
    ?assertEqual(disabled, shigoto_config:testing_mode()),
    application:set_env(shigoto, testing_confirm_no_persistence, true),
    ?assertEqual(inline, shigoto_config:testing_mode()),
    application:set_env(shigoto, testing, manual),
    ?assertEqual(manual, shigoto_config:testing_mode()),
    application:set_env(shigoto, testing, sometimes),
    ?assertEqual(disabled, shigoto_config:testing_mode()),
    application:set_env(shigoto, testing, disabled),
    ?assertEqual(disabled, shigoto_config:testing_mode()).

the_shutdown_budget_counts_every_queue() ->
    Stop = shigoto_executor_sup:stop_timeout(),
    ?assertEqual(16000 + Stop, shigoto_config:shutdown_budget()),
    application:set_env(shigoto, queues, [{~"mail", 5}, {~"reports", 1}]),
    application:set_env(shigoto, fanout_queues, [{~"events", 2, #{}}]),
    application:set_env(shigoto, shutdown_timeout, 2000),
    ?assertEqual(9000 + Stop, shigoto_config:shutdown_budget()),
    application:set_env(shigoto, shutdown_timeout, 0),
    ?assertEqual(3000 + Stop, shigoto_config:shutdown_budget()).

a_job_is_stale_after_two_heartbeats() ->
    ?assertEqual(60.0, shigoto_config:stale_after()),
    application:set_env(shigoto, heartbeat_interval, 2500),
    ?assertEqual(5.0, shigoto_config:stale_after()).

an_instance_names_its_own_channel() ->
    ?assertEqual(~"shigoto_jobs_insert", shigoto_config:notify_channel()),
    application:set_env(shigoto, instance, ~"billing"),
    ?assertEqual(~"shigoto_jobs_insert_billing", shigoto_config:notify_channel()).

a_complete_configuration_passes_the_check() ->
    Key = crypto:strong_rand_bytes(32),
    Configured = #{
        pool => some_pool,
        queues => [{~"mail", 5}],
        fanout_queues => [{~"events", 2, #{}}],
        middleware => [fun(_Job, Next) -> Next() end],
        queue_weights => #{~"mail" => 3},
        fair_queues => [~"mail"],
        notifier => #{host => "localhost"},
        load_shedding => #{max_in_flight => 10},
        encryption_key => Key,
        encryption_write_format => v2,
        encryption_read_formats => [v2],
        require_encrypted => true,
        workers => [shigoto_test_worker, shigoto_unique_worker],
        instance => ~"billing_2",
        advisory_lock_timeout => 0,
        notify_min_interval => 0,
        on_dependency_failure => discard,
        propagator => shigoto_fake_propagator
    },
    [application:set_env(shigoto, Setting, Value) || Setting := Value <- Configured],
    ?assertEqual(ok, shigoto_config:check()).

%% Without a key nothing is encrypted, so the setting that says nothing may be
%% in the clear cannot be honoured.
requiring_encryption_needs_a_key() ->
    application:set_env(shigoto, pool, some_pool),
    application:set_env(shigoto, require_encrypted, true),
    ?assertEqual(
        {error, {shigoto_config, {invalid, require_encrypted, no_encryption_key}}},
        shigoto_config:check()
    ),
    application:set_env(shigoto, encryption_keys, [crypto:strong_rand_bytes(32)]),
    ?assertEqual(ok, shigoto_config:check()),
    application:unset_env(shigoto, encryption_keys),
    application:set_env(shigoto, require_encrypted, false),
    ?assertEqual(ok, shigoto_config:check()).

only_false_turns_required_encryption_off() ->
    ?assertEqual(false, shigoto_config:require_encrypted()),
    application:set_env(shigoto, require_encrypted, false),
    ?assertEqual(false, shigoto_config:require_encrypted()),
    [
        begin
            application:set_env(shigoto, require_encrypted, Value),
            ?assertEqual({Value, true}, {Value, shigoto_config:require_encrypted()})
        end
     || Value <- [true, yes, "true", ~"true", 1, 0, undefined, ~"false", "false"]
    ].

%% Read as no instance, it would put this installation in the lock space and
%% on the channel every unnamed installation in the database shares.
an_instance_that_is_not_a_valid_name_is_never_used() ->
    [
        begin
            application:set_env(shigoto, instance, Instance),
            ?assertError(
                {shigoto_config, {invalid, instance, Instance}}, shigoto_config:instance()
            ),
            ?assertError(
                {shigoto_config, {invalid, instance, Instance}}, shigoto_config:notify_channel()
            )
        end
     || Instance <- [
            billing,
            "billing",
            ~"Billing",
            ~"",
            ~"a', NEW.queue); DROP TABLE shigoto_jobs; --",
            binary:copy(~"a", 33),
            ~"billing\n"
        ]
    ],
    application:set_env(shigoto, instance, binary:copy(~"a", 32)),
    ?assertEqual(binary:copy(~"a", 32), shigoto_config:instance()),
    application:set_env(shigoto, instance, undefined),
    ?assertEqual(undefined, shigoto_config:instance()).
