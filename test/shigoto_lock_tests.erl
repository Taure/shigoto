-module(shigoto_lock_tests).

-include_lib("eunit/include/eunit.hrl").

%% The first integer of the lock for the instances `billing` and `reports`.
%% Nodes of one installation only exclude each other while they agree on it,
%% so it is pinned as a number: deriving it differently is a breaking change.
-define(BILLING, -1881615269).
-define(REPORTS, 893415121).

lock_test_() ->
    {foreach, fun() -> application:unset_env(shigoto, instance) end,
        fun(_) -> application:unset_env(shigoto, instance) end, [
            fun one_key_is_one_call/0,
            fun several_keys_are_asked_for_in_order/0,
            fun an_instance_takes_the_two_integer_form/0,
            fun every_key_of_an_instance_follows_its_class/0,
            fun a_key_of_an_instance_is_cut_to_a_signed_int4/0,
            fun two_instances_do_not_share_a_class/0,
            fun a_failed_query_is_answered_not_waited_for/0
        ]}.

one_key_is_one_call() ->
    ?assertEqual(
        {~"SELECT pg_try_advisory_xact_lock($1) AS locked", [42]},
        shigoto_lock:statement(undefined, [42])
    ).

several_keys_are_asked_for_in_order() ->
    ?assertEqual(
        {
            <<
                "SELECT CASE WHEN pg_try_advisory_xact_lock($1) THEN "
                "CASE WHEN pg_try_advisory_xact_lock($2) THEN "
                "pg_try_advisory_xact_lock($3) "
                "ELSE false END ELSE false END AS locked"
            >>,
            [7, 3, 9]
        },
        shigoto_lock:statement(undefined, [7, 3, 9])
    ).

an_instance_takes_the_two_integer_form() ->
    ?assertEqual(
        {~"SELECT pg_try_advisory_xact_lock($1, $2) AS locked", [?BILLING, 42]},
        shigoto_lock:statement(~"billing", [42])
    ).

every_key_of_an_instance_follows_its_class() ->
    ?assertEqual(
        {
            <<
                "SELECT CASE WHEN pg_try_advisory_xact_lock($1, $2) THEN "
                "pg_try_advisory_xact_lock($1, $3) "
                "ELSE false END AS locked"
            >>,
            [?BILLING, 7, 3]
        },
        shigoto_lock:statement(~"billing", [7, 3])
    ).

a_key_of_an_instance_is_cut_to_a_signed_int4() ->
    Keys = [0, 5, -5, 16#7FFFFFFF, 16#80000000, 16#FFFFFFFF, 16#100000005, -16#80000001],
    {_SQL, [_Class | Cut]} = shigoto_lock:statement(~"billing", Keys),
    ?assertEqual([0, 5, -5, 2147483647, -2147483648, -1, 5, 2147483647], Cut).

two_instances_do_not_share_a_class() ->
    ?assertMatch({_, [?BILLING, 1]}, shigoto_lock:statement(~"billing", [1])),
    ?assertMatch({_, [?REPORTS, 1]}, shigoto_lock:statement(~"reports", [1])).

a_failed_query_is_answered_not_waited_for() ->
    Started = erlang:monotonic_time(millisecond),
    ?assertMatch({error, _}, shigoto_lock:try_xact(shigoto_lock_tests_no_pool, 1)),
    ?assertMatch({error, _}, shigoto_lock:acquire_xact(shigoto_lock_tests_no_pool, [1, 2], 60000)),
    ?assertMatch({error, _}, shigoto_lock:acquire_xact(shigoto_lock_tests_no_pool, [1])),
    application:set_env(shigoto, instance, ~"billing"),
    ?assertMatch({error, _}, shigoto_lock:try_xact(shigoto_lock_tests_no_pool, 1)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 30000).
