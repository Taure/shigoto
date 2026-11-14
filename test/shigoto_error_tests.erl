-module(shigoto_error_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, ~"4111-1111-1111-1111").

error_test_() ->
    {foreach, fun() -> application:set_env(shigoto, encryption_key, binary:copy(<<1>>, 32)) end,
        fun(_) -> application:unset_env(shigoto, encryption_key) end, [
            fun a_shape_keeps_atoms_only/0,
            fun an_error_that_embeds_its_value_keeps_its_tag/0,
            fun a_shape_is_bounded/0,
            fun a_stack_frame_keeps_no_arguments/0,
            fun a_stack_is_bounded/0,
            fun text_carries_no_value_when_a_key_is_set/0,
            fun text_is_as_given_without_a_key/0,
            fun text_is_bounded_and_always_valid/0,
            fun an_entry_has_the_documented_fields/0,
            fun appended_keeps_the_newest_entries/0
        ]}.

a_shape_keeps_atoms_only() ->
    ?assertEqual(timeout, shigoto_error:shape(timeout)),
    ?assertEqual('_', shigoto_error:shape(?SECRET)),
    ?assertEqual('_', shigoto_error:shape(#{card => ?SECRET})),
    ?assertEqual('_', shigoto_error:shape([?SECRET])),
    ?assertEqual('_', shigoto_error:shape(4111)),
    ?assertEqual({http, '_', closed}, shigoto_error:shape({http, 503, closed})),
    ?assertEqual({rejected, {reason, '_'}}, shigoto_error:shape({rejected, {reason, ?SECRET}})).

an_error_that_embeds_its_value_keeps_its_tag() ->
    [
        ?assertEqual(Tag, shigoto_error:shape({Tag, ?SECRET}))
     || Tag <- [badmatch, case_clause, try_clause, badkey, badmap, badarg, nocatch, badfun]
    ],
    ?assertEqual({'EXIT', badmatch}, shigoto_error:shape({'EXIT', {badmatch, ?SECRET}})).

a_shape_is_bounded() ->
    Deep = {a, {b, {c, {d, {e, {f, ?SECRET}}}}}},
    ?assertEqual({a, {b, {c, {d, '_'}}}}, shigoto_error:shape(Deep)),
    Wide = list_to_tuple(lists:duplicate(100, wide)),
    ?assertEqual(list_to_tuple(lists:duplicate(8, wide)), shigoto_error:shape(Wide)).

a_stack_frame_keeps_no_arguments() ->
    Stack = [
        {my_worker, perform, [#{~"card" => ?SECRET}], [
            {file, "my_worker.erl"}, {line, 12}, {error_info, #{cause => ?SECRET}}
        ]},
        {my_worker, helper, 2, [{file, "my_worker.erl"}, {line, 30}]},
        {not_a_frame, ?SECRET}
    ],
    ?assertEqual(
        [
            {my_worker, perform, 1, [{file, "my_worker.erl"}, {line, 12}]},
            {my_worker, helper, 2, [{file, "my_worker.erl"}, {line, 30}]},
            '_'
        ],
        shigoto_error:stack(Stack)
    ).

a_stack_is_bounded() ->
    Stack = [{my_worker, recurse, 1, [{line, N}]} || N <- lists:seq(1, 500)],
    ?assertEqual(16, length(shigoto_error:stack(Stack))),
    Text = stacktrace(shigoto_error:entry(#{}, {error, failed, Stack})),
    ?assert(byte_size(Text) =< 4096).

text_carries_no_value_when_a_key_is_set() ->
    Stack = [{my_worker, perform, [#{~"card" => ?SECRET}], []}],
    Reasons = [
        ?SECRET,
        {error, ?SECRET},
        {error, {badmatch, ?SECRET}, Stack},
        {throw, #{card => ?SECRET}, Stack},
        {exit, {timeout, {gen_server, call, [pid, {charge, ?SECRET}]}}},
        {rejected, [?SECRET]}
    ],
    [
        begin
            ?assertEqual(nomatch, binary:match(shigoto_error:text(Reason), ?SECRET)),
            Entry = shigoto_error:entry(#{attempt => 1, worker => ~"my_worker"}, Reason),
            ?assertEqual(nomatch, binary:match(iolist_to_binary(json:encode(Entry)), ?SECRET))
        end
     || Reason <- Reasons
    ],
    ?assertEqual(~"error:badmatch", shigoto_error:text({error, {badmatch, ?SECRET}, Stack})),
    ?assertEqual(~"timeout", shigoto_error:text(timeout)),
    ?assertEqual(~"decrypt_failed", shigoto_error:text(decrypt_failed)).

text_is_as_given_without_a_key() ->
    application:unset_env(shigoto, encryption_key),
    ?assertEqual(
        ~"{card_declined,<<\"4111\">>,3}", shigoto_error:text({card_declined, ~"4111", 3})
    ),
    ?assertEqual(~"error:<<\"4111\">>", shigoto_error:text({error, ~"4111"})),
    %% A stack never keeps its arguments, key or no key.
    Stack = [{my_worker, perform, [#{~"card" => ?SECRET}], []}],
    Text = stacktrace(shigoto_error:entry(#{}, {error, failed, Stack})),
    ?assertEqual(nomatch, binary:match(Text, ?SECRET)).

text_is_bounded_and_always_valid() ->
    application:unset_env(shigoto, encryption_key),
    Text = shigoto_error:text(binary:copy(~"x", 100000)),
    ?assert(byte_size(Text) =< 1024),
    [
        ?assert(is_binary(iolist_to_binary(json:encode(shigoto_error:entry(#{}, Reason)))))
     || Reason <- [<<255, 254, 0, 1>>, [16#10FFFF, 300, -1], {error, <<200, 201>>}, "åäö€"]
    ].

an_entry_has_the_documented_fields() ->
    Entry = shigoto_error:entry(#{attempt => 3, worker => my_worker}, {error, timeout, []}),
    ?assertMatch(
        #{
            ~"error" := ~"error:timeout",
            ~"attempt" := 3,
            ~"worker" := ~"my_worker",
            ~"stacktrace" := ~"[]",
            ~"at" := <<_:19/binary, "Z">>
        },
        Entry
    ),
    Plain = shigoto_error:entry(#{}, timeout),
    ?assertEqual([~"at", ~"attempt", ~"error", ~"worker"], lists:sort(maps:keys(Plain))),
    ?assertMatch(#{~"attempt" := 0, ~"worker" := ~"undefined"}, Plain).

appended_keeps_the_newest_entries() ->
    SQL = shigoto_error:appended(~"errors", ~"$2::jsonb"),
    ?assertNotEqual(nomatch, binary:match(SQL, ~">= 50")),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"(errors - 0) || $2::jsonb")),
    ?assertNotEqual(nomatch, binary:match(SQL, ~"ELSE errors || $2::jsonb END")).

stacktrace(#{~"stacktrace" := Text}) when is_binary(Text) ->
    Text.
