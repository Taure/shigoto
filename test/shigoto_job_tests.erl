-module(shigoto_job_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WORKER, ~"shigoto_test_worker").
-define(ENV, [encryption_key, encryption_write_format, require_encrypted, workers]).

job_test_() ->
    {foreach,
        fun() ->
            set(#{encryption_key => binary:copy(<<1>>, 32), encryption_write_format => v2}),
            shigoto_job:new_table()
        end,
        fun(_) ->
            set(#{}),
            [ets:delete(shigoto_workers) || ets:whereis(shigoto_workers) =/= undefined]
        end,
        [
            fun a_worker_exports_perform/0,
            fun a_name_that_is_no_atom_creates_none/0,
            fun the_allow_list_is_checked_before_the_module_is_loaded/0,
            fun the_answer_is_remembered_and_follows_the_allow_list/0,
            fun a_job_is_checked_without_the_table/0,
            fun an_opened_job_has_decoded_columns/0,
            fun a_job_for_another_worker_is_not_opened/0,
            fun a_job_that_names_no_worker_is_not_opened/0,
            fun deps_results_open_per_job/0,
            fun a_readable_job_shows_reasons_not_ciphertext/0,
            fun a_redacted_job_has_no_data/0,
            fun the_table_is_made_once/0,
            fun a_name_that_is_no_worker_is_not_asked_about_for_30_seconds/0,
            fun args_already_a_map_are_kept/0,
            fun a_readable_job_shows_its_result/0,
            fun a_readable_job_shows_what_it_waited_for/0,
            fun refused_plaintext_is_shown_as_stored/0
        ]}.

a_worker_exports_perform() ->
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(?WORKER)),
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(shigoto_test_worker)),
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(#{worker => ?WORKER})),
    [
        ?assertEqual({error, {unknown_worker, Name}}, shigoto_job:worker(Name))
     || Name <- [~"lists", ~"erlang", ~"os", ~"shigoto_repo", ~"", ~"undefined"]
    ],
    ?assertEqual({error, {unknown_worker, ~"undefined"}}, shigoto_job:worker(#{})).

a_name_that_is_no_atom_creates_none() ->
    Name =
        <<"shigoto_no_such_worker_",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Before = erlang:system_info(atom_count),
    [?assertEqual({error, {unknown_worker, Name}}, shigoto_job:worker(Name)) || _ <- [1, 2, 3]],
    ?assertEqual(Before, erlang:system_info(atom_count)),
    ?assertError(badarg, binary_to_existing_atom(Name)).

the_allow_list_is_checked_before_the_module_is_loaded() ->
    set(#{workers => [shigoto_test_worker]}),
    _ = code:delete(shigoto_snooze_worker),
    _ = code:purge(shigoto_snooze_worker),
    ?assertEqual(
        {error, {unknown_worker, ~"shigoto_snooze_worker"}},
        shigoto_job:worker(~"shigoto_snooze_worker")
    ),
    ?assertEqual(false, code:is_loaded(shigoto_snooze_worker)),
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(?WORKER)).

the_answer_is_remembered_and_follows_the_allow_list() ->
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(?WORKER)),
    ?assertEqual([{?WORKER, shigoto_test_worker}], ets:lookup(shigoto_workers, ?WORKER)),
    ?assertMatch({error, _}, shigoto_job:worker(~"lists")),
    ?assertMatch([{~"lists", unknown, _Until}], ets:lookup(shigoto_workers, ~"lists")),
    %% A worker taken off the list is refused although it was remembered.
    set(#{workers => [shigoto_snooze_worker]}),
    ?assertEqual({error, {unknown_worker, ?WORKER}}, shigoto_job:worker(?WORKER)).

a_job_is_checked_without_the_table() ->
    ets:delete(shigoto_workers),
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(?WORKER)),
    ?assertMatch({error, _}, shigoto_job:worker(~"lists")).

an_opened_job_has_decoded_columns() ->
    Job = job(?WORKER, #{~"card" => ~"4111"}, #{~"trace" => ~"t1"}),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, maps:get(args, Job)),
    {ok, Module, Opened} = shigoto_job:opened(Job),
    ?assertEqual(shigoto_test_worker, Module),
    ?assertEqual(#{~"card" => ~"4111"}, maps:get(args, Opened)),
    ?assertEqual(#{~"trace" => ~"t1"}, json:decode(maps:get(meta, Opened))),
    ?assertEqual(maps:get(id, Job), maps:get(id, Opened)).

a_job_for_another_worker_is_not_opened() ->
    Job = job(?WORKER, #{~"card" => ~"4111"}, #{}),
    ?assertEqual(
        {error, decrypt_failed}, shigoto_job:opened(Job#{worker := ~"shigoto_snooze_worker"})
    ),
    ?assertEqual(
        {error, decrypt_failed}, shigoto_job:opened(Job#{meta := maps:get(args, Job)})
    ),
    set(#{
        encryption_key => binary:copy(<<1>>, 32),
        encryption_write_format => v2,
        require_encrypted => true
    }),
    ?assertEqual({error, plaintext_refused}, shigoto_job:opened(Job#{args := ~"{\"n\":1}"})).

a_job_that_names_no_worker_is_not_opened() ->
    Job = job(?WORKER, #{~"card" => ~"4111"}, #{}),
    ?assertEqual({error, {unknown_worker, ~"lists"}}, shigoto_job:opened(Job#{worker := ~"lists"})),
    set(#{}),
    %% Without a key too: a frame is never passed on as the args.
    ?assertEqual({error, decrypt_failed}, shigoto_job:opened(Job)).

deps_results_open_per_job() ->
    Result = json:decode(shigoto_crypto:seal(~"{\"total\":9}", {result, 5})),
    Job = job(?WORKER, #{}, #{}),
    Stored = fun(Results) -> iolist_to_binary(json:encode(Results)) end,
    {ok, _, Opened} = shigoto_job:opened(Job#{deps_results => Stored(#{~"5" => Result})}),
    ?assertEqual(#{5 => #{~"total" => 9}}, maps:get(deps_results, Opened)),
    ?assertEqual(
        {error, decrypt_failed}, shigoto_job:opened(Job#{deps_results => Stored(#{~"6" => Result})})
    ),
    ?assertEqual(
        {error, decrypt_failed},
        shigoto_job:opened(Job#{deps_results => Stored(#{~"not-an-id" => Result})})
    ),
    {ok, _, Empty} = shigoto_job:opened(Job#{deps_results => ~"{}"}),
    ?assertEqual(#{}, maps:get(deps_results, Empty)).

a_readable_job_shows_reasons_not_ciphertext() ->
    Job = job(?WORKER, #{~"card" => ~"4111"}, #{~"trace" => ~"t1"}),
    Shown = shigoto_job:readable(Job),
    ?assertEqual(#{~"card" => ~"4111"}, json:decode(maps:get(args, Shown))),
    ?assertEqual(#{~"trace" => ~"t1"}, json:decode(maps:get(meta, Shown))),
    Moved = shigoto_job:readable(Job#{worker := ~"lists"}),
    ?assertEqual(~"\"decrypt_failed\"", maps:get(args, Moved)),
    ?assertEqual(~"\"decrypt_failed\"", maps:get(meta, Moved)),
    Plain = shigoto_job:readable(Job#{args := ~"{\"n\":1}"}),
    ?assertEqual(~"{\"n\":1}", maps:get(args, Plain)),
    set(#{}),
    ?assertEqual(Job, shigoto_job:readable(Job)).

a_redacted_job_has_no_data() ->
    Job = (job(?WORKER, #{~"card" => ~"4111"}, #{}))#{
        result => ~"{}", deps_results => ~"{}", errors => ~"[]", callback_args => ~"{}"
    },
    ?assertEqual(
        [id, queue, worker],
        lists:sort(maps:keys(shigoto_job:redact(Job)))
    ).

the_table_is_made_once() ->
    Table = ets:whereis(shigoto_workers),
    ?assertNotEqual(undefined, Table),
    ?assertEqual(ok, shigoto_job:new_table()),
    ?assertEqual(Table, ets:whereis(shigoto_workers)),
    ets:delete(shigoto_workers),
    ?assertEqual(ok, shigoto_job:new_table()),
    ?assertNotEqual(undefined, ets:whereis(shigoto_workers)).

a_name_that_is_no_worker_is_not_asked_about_for_30_seconds() ->
    set(#{workers => [shigoto_snooze_worker]}),
    Before = erlang:monotonic_time(second),
    ?assertEqual({error, {unknown_worker, ?WORKER}}, shigoto_job:worker(?WORKER)),
    After = erlang:monotonic_time(second),
    Until =
        case ets:lookup(shigoto_workers, ?WORKER) of
            [{?WORKER, unknown, At}] when is_integer(At) -> At
        end,
    ?assert(Before =< Until - 30 andalso Until - 30 =< After),
    %% On the list now, and still refused: the answer is the remembered one.
    set(#{workers => [shigoto_test_worker]}),
    ?assertEqual({error, {unknown_worker, ?WORKER}}, shigoto_job:worker(?WORKER)),
    ets:insert(shigoto_workers, {?WORKER, unknown, erlang:monotonic_time(second)}),
    ?assertEqual({ok, shigoto_test_worker}, shigoto_job:worker(?WORKER)),
    ?assertEqual([{?WORKER, shigoto_test_worker}], ets:lookup(shigoto_workers, ?WORKER)).

args_already_a_map_are_kept() ->
    Job = job(?WORKER, #{}, #{}),
    {ok, _, Opened} = shigoto_job:opened(Job#{args := #{~"card" => ~"4111"}}),
    ?assertEqual(#{~"card" => ~"4111"}, maps:get(args, Opened)),
    {ok, _, Without} = shigoto_job:opened(maps:remove(args, Job)),
    ?assertEqual(#{}, maps:get(args, Without)).

a_readable_job_shows_its_result() ->
    Job = job(?WORKER, #{}, #{}),
    Sealed = shigoto_crypto:seal(~"{\"total\":9}", {result, 1}),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, Sealed),
    ?assertEqual(
        ~"{\"total\":9}", maps:get(result, shigoto_job:readable(Job#{result => Sealed}))
    ),
    %% A result is bound to the job that wrote it.
    ?assertEqual(
        ~"\"decrypt_failed\"",
        maps:get(result, shigoto_job:readable(Job#{id := 2, result => Sealed}))
    ),
    %% Without an id there is nothing to open it with: it stays as stored.
    NoId = maps:remove(id, Job#{result => Sealed}),
    ?assertEqual(Sealed, maps:get(result, shigoto_job:readable(NoId))).

a_readable_job_shows_what_it_waited_for() ->
    Result = json:decode(shigoto_crypto:seal(~"{\"total\":9}", {result, 5})),
    Job = job(?WORKER, #{}, #{}),
    Shown = fun(Results) ->
        Stored = iolist_to_binary(json:encode(Results)),
        json:decode(maps:get(deps_results, shigoto_job:readable(Job#{deps_results => Stored})))
    end,
    ?assertEqual(#{~"5" => #{~"total" => 9}}, Shown(#{~"5" => Result})),
    ?assertEqual(
        #{~"5" => #{~"total" => 9}, ~"6" => ~"decrypt_failed", ~"not-an-id" => ~"decrypt_failed"},
        Shown(#{~"5" => Result, ~"6" => Result, ~"not-an-id" => Result})
    ),
    ?assertEqual(
        #{~"7" => #{~"n" => 1}, ~"8" => null}, Shown(#{~"7" => #{~"n" => 1}, ~"8" => null})
    ),
    %% What is not an object of results is shown as it is stored.
    ?assertEqual([1, 2], Shown([1, 2])),
    ?assertEqual(
        ~"not json", maps:get(deps_results, shigoto_job:readable(Job#{deps_results => ~"not json"}))
    ),
    ?assertNot(maps:is_key(deps_results, shigoto_job:readable(Job))).

refused_plaintext_is_shown_as_stored() ->
    set(#{
        encryption_key => binary:copy(<<1>>, 32),
        encryption_write_format => v2,
        require_encrypted => true
    }),
    Job = job(?WORKER, #{}, #{}),
    ?assertEqual({error, plaintext_refused}, shigoto_job:opened(Job#{args := ~"{\"n\":1}"})),
    Shown = shigoto_job:readable(Job#{
        args := ~"{\"n\":1}", deps_results => ~"{\"7\":{\"n\":1}}"
    }),
    ?assertEqual(~"{\"n\":1}", maps:get(args, Shown)),
    ?assertEqual(#{~"7" => #{~"n" => 1}}, json:decode(maps:get(deps_results, Shown))).

job(Worker, Args, Meta) ->
    #{
        id => 1,
        queue => ~"default",
        worker => Worker,
        args => shigoto_crypto:seal(iolist_to_binary(json:encode(Args)), {args, Worker}),
        meta => shigoto_crypto:seal(iolist_to_binary(json:encode(Meta)), {meta, Worker})
    }.

set(Env) ->
    [application:unset_env(shigoto, Key) || Key <- ?ENV],
    [application:set_env(shigoto, Key, Value) || Key := Value <- Env],
    ok.
