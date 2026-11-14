-module(shigoto_propagator_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, ~"_shigoto_carrier").

propagator_test_() ->
    {foreach, fun() -> application:set_env(shigoto, propagator, shigoto_fake_propagator) end,
        fun(_) ->
            application:unset_env(shigoto, propagator),
            shigoto_fake_propagator:clear()
        end,
        [
            fun the_key_is_one_reserved_meta_key/0,
            fun injected_is_what_the_module_says/0,
            fun a_carrier_out_of_bounds_is_dropped_whole/0,
            fun an_inject_that_raises_is_no_carrier/0,
            fun stamping_keeps_the_rest_of_meta/0,
            fun a_stored_carrier_is_read_from_opened_meta/0,
            fun attaching_and_detaching_restore_the_process/0,
            fun an_attach_that_raises_attaches_nothing/0,
            fun the_setting_has_to_name_a_propagator/0
        ]}.

the_key_is_one_reserved_meta_key() ->
    ?assertEqual(?KEY, shigoto_propagator:key()).

injected_is_what_the_module_says() ->
    ?assertEqual(#{}, shigoto_propagator:injected()),
    shigoto_fake_propagator:trace(~"t"),
    ?assertEqual(#{~"traceparent" => ~"t"}, shigoto_propagator:injected()),
    application:unset_env(shigoto, propagator),
    ?assertEqual(#{}, shigoto_propagator:injected()).

a_carrier_out_of_bounds_is_dropped_whole() ->
    shigoto_fake_propagator:trace(oversized),
    ?assertEqual(#{}, shigoto_propagator:injected()),
    Entries = fun(N) -> #{integer_to_binary(I) => ~"v" || I <- lists:seq(1, N)} end,
    ?assertEqual(Entries(32), shigoto_propagator:carrier(#{meta => #{?KEY => Entries(32)}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => #{?KEY => Entries(33)}})),
    Sized = fun(Bytes) -> #{~"k" => binary:copy(~"x", Bytes - 1)} end,
    ?assertEqual(Sized(4096), shigoto_propagator:carrier(#{meta => #{?KEY => Sized(4096)}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => #{?KEY => Sized(4097)}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => #{?KEY => #{~"k" => 1}}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => #{?KEY => #{k => ~"v"}}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => #{?KEY => ~"traceparent"}})).

an_inject_that_raises_is_no_carrier() ->
    shigoto_fake_propagator:trace(raise),
    ?assertEqual(#{}, shigoto_propagator:injected()).

stamping_keeps_the_rest_of_meta() ->
    Carrier = #{~"traceparent" => ~"t"},
    ?assertEqual(#{worker => w}, shigoto_propagator:stamped(#{worker => w}, #{})),
    ?assertEqual(
        #{worker => w, meta => #{?KEY => Carrier}},
        shigoto_propagator:stamped(#{worker => w}, Carrier)
    ),
    ?assertEqual(
        #{meta => #{~"tenant" => 7, ?KEY => Carrier}},
        shigoto_propagator:stamped(#{meta => #{~"tenant" => 7}}, Carrier)
    ),
    Own = #{meta => #{?KEY => #{~"traceparent" => ~"own"}}},
    ?assertEqual(Own, shigoto_propagator:stamped(Own, Carrier)),
    ?assertEqual(#{meta => not_a_map}, shigoto_propagator:stamped(#{meta => not_a_map}, Carrier)).

a_stored_carrier_is_read_from_opened_meta() ->
    Carrier = #{~"traceparent" => ~"t"},
    Json = iolist_to_binary(json:encode(#{~"tenant" => 7, ?KEY => Carrier})),
    ?assertEqual(Carrier, shigoto_propagator:carrier(#{meta => Json})),
    ?assertEqual(Carrier, shigoto_propagator:carrier(#{meta => #{?KEY => Carrier}})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => ~"{}"})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => ~"not json"})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{meta => null})),
    ?assertEqual(#{}, shigoto_propagator:carrier(#{})).

attaching_and_detaching_restore_the_process() ->
    Carrier = #{~"traceparent" => ~"job"},
    shigoto_fake_propagator:trace(~"mine"),
    ?assertEqual(#{}, shigoto_propagator:current()),
    Attachment = shigoto_propagator:attached(Carrier),
    ?assertEqual(~"job", shigoto_fake_propagator:trace()),
    ?assertEqual(Carrier, shigoto_propagator:current()),
    ?assertEqual(ok, shigoto_propagator:detached(Attachment)),
    ?assertEqual(~"mine", shigoto_fake_propagator:trace()),
    ?assertEqual(#{}, shigoto_propagator:current()),
    ?assertEqual(none, shigoto_propagator:attached(#{})),
    ?assertEqual(ok, shigoto_propagator:detached(none)),
    application:unset_env(shigoto, propagator),
    ?assertEqual(none, shigoto_propagator:attached(Carrier)).

an_attach_that_raises_attaches_nothing() ->
    ?assertEqual(none, shigoto_propagator:attached(#{~"traceparent" => ~"unattachable"})),
    ?assertEqual(#{}, shigoto_propagator:current()).

the_setting_has_to_name_a_propagator() ->
    ?assertEqual(ok, shigoto_propagator:check(undefined)),
    ?assertEqual(ok, shigoto_propagator:check(shigoto_fake_propagator)),
    ?assertEqual({error, {invalid_propagator, lists}}, shigoto_propagator:check(lists)),
    ?assertEqual(
        {error, {invalid_propagator, shigoto_no_such_module}},
        shigoto_propagator:check(shigoto_no_such_module)
    ),
    ?assertEqual({error, {invalid_propagator, ~"mod"}}, shigoto_propagator:check(~"mod")),
    application:set_env(shigoto, propagator, lists),
    ?assertEqual({error, {shigoto_config, {invalid_propagator, lists}}}, shigoto_config:check()).
