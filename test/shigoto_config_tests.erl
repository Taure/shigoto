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
    encryption_keys
]).

config_test_() ->
    {foreach, fun unset/0, fun(_) -> unset() end, [
        fun defaults_when_nothing_is_set/0,
        fun a_setting_of_the_wrong_type_fails_by_name/0,
        fun a_pool_that_is_not_set_fails_by_name/0,
        fun a_queue_entry_is_handed_on_as_written/0,
        fun weights_and_fair_queues_keep_what_can_match_a_queue/0,
        fun a_key_that_is_not_a_binary_is_never_in_the_error/0,
        fun middleware_has_to_be_funs_of_two/0
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
    ?assertError({shigoto_config, {invalid, repo, ~"my_repo"}}, shigoto_config:pool()).

a_pool_that_is_not_set_fails_by_name() ->
    ?assertError({shigoto_config, {not_set, pool}}, shigoto_config:pool()),
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
        {shigoto_config, {invalid_encryption_key, not_a_binary}}, shigoto_config:encryption_key()
    ),
    application:set_env(shigoto, encryption_keys, [crypto:strong_rand_bytes(32), a_key]),
    ?assertError(
        {shigoto_config, {invalid_encryption_key, not_a_binary}},
        shigoto_config:encryption_keys()
    ),
    %% The boot check still names the setting and the position.
    ?assertMatch(
        {error, {invalid_encryption_key, #{setting := encryption_keys, problem := not_a_binary}}},
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
