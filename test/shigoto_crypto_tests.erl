-module(shigoto_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ARGS, {args, ~"my_worker"}).
-define(PLAIN, ~"{\"card\":\"4111\"}").
-define(ENV, [
    encryption_key,
    encryption_keys,
    encryption_write_format,
    encryption_read_formats,
    require_encrypted
]).

crypto_test_() ->
    {foreach, fun() -> set(#{encryption_key => key(1), encryption_write_format => v2}) end,
        fun(_) -> set(#{}) end, [
            fun v2_round_trip/0,
            fun v1_round_trip/0,
            fun v2_is_the_default_write_format/0,
            fun v2_is_the_documented_frame/0,
            fun v2_is_bound_to_worker_and_column/0,
            fun a_result_is_bound_to_its_job/0,
            fun v1_is_bound_to_nothing/0,
            fun a_changed_frame_does_not_open/0,
            fun every_value_gets_its_own_nonce/0,
            fun an_older_key_still_opens/0,
            fun a_removed_key_does_not_open/0,
            fun a_format_left_out_is_refused/0,
            fun plaintext_is_refused_when_encryption_is_required/0,
            fun v1_leaves_results_and_callback_args_alone/0,
            fun without_a_key_nothing_is_changed_or_opened/0,
            fun open_term_opens_a_decoded_value/0,
            fun reseal_rewrites_what_is_not_current/0,
            fun reseal_reports_a_moved_ciphertext/0,
            fun a_string_that_only_looks_like_a_frame_is_plaintext/0,
            fun a_plaintext_that_would_read_as_a_frame_is_sealed/0,
            fun unique_keys_cover_every_key/0,
            fun keys_are_checked_without_being_shown/0,
            fun a_bad_key_is_not_in_the_error/0,
            fun the_legacy_calls_still_work/0
        ]}.

v2_round_trip() ->
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, Sealed),
    ?assert(is_binary(json:decode(Sealed))),
    ?assertEqual(nomatch, binary:match(Sealed, ~"4111")),
    ?assert(shigoto_crypto:is_frame(Sealed)),
    ?assertNot(shigoto_crypto:is_frame(?PLAIN)),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Sealed, ?ARGS)).

v2_is_the_default_write_format() ->
    set(#{encryption_key => key(1)}),
    ?assertEqual(v2, shigoto_config:encryption_write_format()),
    ?assertEqual([v1, v2], shigoto_config:encryption_read_formats()),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, shigoto_crypto:seal(?PLAIN, ?ARGS)),
    ?assertMatch(<<"\"enc:v2:", _/binary>>, shigoto_crypto:seal(~"1", {result, 1})).

v1_round_trip() ->
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertMatch(<<"\"enc:", _/binary>>, Sealed),
    ?assertNotMatch(<<"\"enc:v2:", _/binary>>, Sealed),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Sealed, ?ARGS)),
    %% What releases up to 1.10 read: IV, tag, ciphertext under the key itself.
    <<IV:12/binary, Tag:16/binary, Cipher/binary>> = frame_bytes(Sealed, ~"enc:"),
    ?assertEqual(
        ?PLAIN,
        crypto:crypto_one_time_aead(aes_256_gcm, key(1), IV, Cipher, ~"shigoto", Tag, false)
    ).

%% The frame built here from the description alone opens, so a change to the
%% derivation or the associated data fails this test.
v2_is_the_documented_frame() ->
    Ctx = <<4:16, "args", 9:16, "my_worker">>,
    PRK = crypto:mac(hmac, sha256, ~"shigoto/enc/v2", key(1)),
    <<KeyId:4/binary, _/binary>> = crypto:mac(hmac, sha256, PRK, <<"shigoto/v2/key-id", 1>>),
    Subkey = crypto:mac(hmac, sha256, PRK, <<"shigoto/v2/gcm", 0, Ctx/binary, 1>>),
    IV = binary:copy(<<7>>, 12),
    AAD = <<"shigoto", 2, KeyId/binary, Ctx/binary>>,
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Subkey, IV, ?PLAIN, AAD, 16, true),
    Frame = base64:encode(<<KeyId/binary, IV/binary, Tag/binary, Cipher/binary>>),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(<<"\"enc:v2:", Frame/binary, "\"">>, ?ARGS)).

v2_is_bound_to_worker_and_column() ->
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    [
        ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Sealed, Context))
     || Context <- [
            {args, ~"other_worker"},
            {args, <<>>},
            {meta, ~"my_worker"},
            {cron_args, ~"my_worker"},
            {callback_args, ~"my_worker"},
            {result, 1}
        ]
    ],
    %% The two parts of a context cannot be shifted into each other.
    Shifted = shigoto_crypto:seal(?PLAIN, {args, ~"smeta"}),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Shifted, {meta, ~"args"})).

a_result_is_bound_to_its_job() ->
    Sealed = shigoto_crypto:seal(?PLAIN, {result, 41}),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Sealed, {result, 41})),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Sealed, {result, 42})),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Sealed, {args, ~"41"})).

v1_is_bound_to_nothing() ->
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Sealed, {meta, ~"other_worker"})).

a_changed_frame_does_not_open() ->
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    Bytes = frame_bytes(Sealed, ~"enc:v2:"),
    [
        ?assertEqual(
            {error, decrypt_failed},
            shigoto_crypto:open(framed(~"enc:v2:", flipped(Bytes, Position)), ?ARGS)
        )
     || Position <- lists:seq(0, byte_size(Bytes) - 1)
    ],
    [
        ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Broken, ?ARGS))
     || Broken <- [
            ~"\"enc:v2:\"",
            ~"\"enc:v2:not base64!\"",
            ~"\"enc:v2:AAAA\"",
            ~"\"enc:\"",
            ~"\"enc:AAAA\"",
            ~"\"enc:v2:AAAA",
            framed(~"enc:v2:", binary:part(Bytes, 0, 20)),
            framed(~"enc:", Bytes)
        ]
    ].

every_value_gets_its_own_nonce() ->
    Sealed = [shigoto_crypto:seal(?PLAIN, ?ARGS) || _ <- lists:seq(1, 200)],
    Nonces = [binary:part(frame_bytes(S, ~"enc:v2:"), 4, 12) || S <- Sealed],
    ?assertEqual(200, length(lists:usort(Nonces))).

an_older_key_still_opens() ->
    V2 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    V1 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_keys => [key(2), key(1)], encryption_write_format => v2}),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(V2, ?ARGS)),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(V1, ?ARGS)),
    New = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_keys => [key(2)], encryption_write_format => v2}),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(New, ?ARGS)).

a_removed_key_does_not_open() ->
    V2 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    V1 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_key => key(2)}),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(V2, ?ARGS)),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(V1, ?ARGS)).

a_format_left_out_is_refused() ->
    V2 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    V1 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{encryption_key => key(1), encryption_read_formats => [v2]}),
    ?assertEqual({error, format_refused}, shigoto_crypto:open(V1, ?ARGS)),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(V2, ?ARGS)),
    set(#{encryption_key => key(1), encryption_read_formats => [v1]}),
    ?assertEqual({error, format_refused}, shigoto_crypto:open(V2, ?ARGS)).

plaintext_is_refused_when_encryption_is_required() ->
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(?PLAIN, ?ARGS)),
    set(#{encryption_key => key(1), encryption_write_format => v2, require_encrypted => true}),
    ?assertEqual({error, plaintext_refused}, shigoto_crypto:open(?PLAIN, ?ARGS)),
    ?assertEqual({error, plaintext_refused}, shigoto_crypto:open(~"{}", ?ARGS)),
    ?assertEqual({error, plaintext_refused}, shigoto_crypto:open(?PLAIN, {meta, ~"my_worker"})),
    ?assertEqual({error, plaintext_refused}, shigoto_crypto:open(?PLAIN, {result, 1})),
    ?assertEqual({error, plaintext_refused}, shigoto_crypto:open_term(#{}, {result, 1})),
    %% The default of the meta column, which no insert writes.
    ?assertEqual({ok, ~"{}"}, shigoto_crypto:open(~"{}", {meta, ~"my_worker"})),
    ?assertEqual({ok, null}, shigoto_crypto:open_term(null, {result, 1})),
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Sealed, ?ARGS)).

v1_leaves_results_and_callback_args_alone() ->
    set(#{encryption_key => key(1), encryption_write_format => v1, require_encrypted => true}),
    ?assertEqual(?PLAIN, shigoto_crypto:seal(?PLAIN, {result, 1})),
    ?assertEqual(?PLAIN, shigoto_crypto:seal(?PLAIN, {callback_args, ~"my_worker"})),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(?PLAIN, {result, 1})),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(?PLAIN, {callback_args, ~"my_worker"})),
    ?assertMatch(<<"\"enc:", _/binary>>, shigoto_crypto:seal(?PLAIN, {meta, ~"my_worker"})),
    ?assertMatch(<<"\"enc:", _/binary>>, shigoto_crypto:seal(?PLAIN, {cron_args, ~"my_worker"})).

without_a_key_nothing_is_changed_or_opened() ->
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    set(#{}),
    ?assertNot(shigoto_crypto:is_enabled()),
    ?assertEqual(?PLAIN, shigoto_crypto:seal(?PLAIN, ?ARGS)),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(?PLAIN, ?ARGS)),
    ?assertEqual(current, shigoto_crypto:reseal(?PLAIN, ?ARGS)),
    %% Ciphertext is never handed on as if it were the value.
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Sealed, ?ARGS)),
    ?assertEqual({ok, ~"\"enc:mine\""}, shigoto_crypto:open(~"\"enc:mine\"", {result, 1})).

open_term_opens_a_decoded_value() ->
    Sealed = json:decode(shigoto_crypto:seal(~"{\"n\":1}", {result, 7})),
    ?assertEqual({ok, #{~"n" => 1}}, shigoto_crypto:open_term(Sealed, {result, 7})),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:open_term(Sealed, {result, 8})),
    ?assertEqual({ok, #{~"n" => 1}}, shigoto_crypto:open_term(#{~"n" => 1}, {result, 7})).

reseal_rewrites_what_is_not_current() ->
    Current = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertEqual(current, shigoto_crypto:reseal(Current, ?ARGS)),
    {resealed, FromPlain} = shigoto_crypto:reseal(?PLAIN, ?ARGS),
    ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(FromPlain, ?ARGS)),
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    V1 = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertEqual(current, shigoto_crypto:reseal(V1, ?ARGS)),
    ?assertEqual(current, shigoto_crypto:reseal(?PLAIN, {result, 1})),
    set(#{encryption_keys => [key(2), key(1)], encryption_write_format => v2}),
    {resealed, FromV1} = shigoto_crypto:reseal(V1, ?ARGS),
    {resealed, FromOldKey} = shigoto_crypto:reseal(Current, ?ARGS),
    set(#{encryption_key => key(2), encryption_write_format => v2}),
    [
        begin
            ?assertEqual({ok, ?PLAIN}, shigoto_crypto:open(Resealed, ?ARGS)),
            ?assertEqual(current, shigoto_crypto:reseal(Resealed, ?ARGS))
        end
     || Resealed <- [FromV1, FromOldKey]
    ],
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:reseal(Current, ?ARGS)).

reseal_reports_a_moved_ciphertext() ->
    Sealed = shigoto_crypto:seal(?PLAIN, ?ARGS),
    ?assertEqual(current, shigoto_crypto:reseal(Sealed, ?ARGS)),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:reseal(Sealed, {args, ~"other_worker"})),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:reseal(Sealed, {meta, ~"my_worker"})),
    Result = shigoto_crypto:seal(~"1", {result, 1}),
    ?assertEqual({error, decrypt_failed}, shigoto_crypto:reseal(Result, {result, 2})).

a_string_that_only_looks_like_a_frame_is_plaintext() ->
    Result = {result, 7},
    Callback = {callback_args, ~"my_worker"},
    Lookalikes = [
        ~"\"enc:hello\"",
        ~"\"enc:\"",
        ~"\"enc:v2:hello\"",
        ~"\"enc:v2:aGVsbG8=\"",
        ~"\"enc:a \\\"quoted\\\" word\""
    ],
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    [
        begin
            ?assertEqual(Plain, shigoto_crypto:seal(Plain, Result)),
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Plain, Result)),
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Plain, Callback)),
            ?assertEqual(
                {ok, json:decode(Plain)}, shigoto_crypto:open_term(json:decode(Plain), Result)
            ),
            ?assertEqual(current, shigoto_crypto:reseal(Plain, Result)),
            ?assertNot(shigoto_crypto:is_frame(Plain, Result)),
            %% Args and meta are never strings in the clear.
            ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Plain, ?ARGS))
        end
     || Plain <- Lookalikes
    ],
    set(#{encryption_key => key(1), encryption_write_format => v2}),
    [
        begin
            Sealed = shigoto_crypto:seal(Plain, Result),
            ?assertMatch(<<"\"enc:v2:", _/binary>>, Sealed),
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Sealed, Result)),
            %% Stored in the clear by an earlier release.
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Plain, Result)),
            {resealed, Resealed} = shigoto_crypto:reseal(Plain, Result),
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Resealed, Result))
        end
     || Plain <- Lookalikes
    ],
    set(#{encryption_key => key(1), encryption_write_format => v2, require_encrypted => true}),
    [
        ?assertEqual({error, plaintext_refused}, shigoto_crypto:open(Plain, Result))
     || Plain <- Lookalikes
    ],
    set(#{}),
    [
        ?assertEqual({ok, Plain}, shigoto_crypto:open(Plain, Context))
     || Plain <- Lookalikes, Context <- [Result, Callback]
    ],
    ok.

a_plaintext_that_would_read_as_a_frame_is_sealed() ->
    Result = {result, 7},
    set(#{encryption_key => key(1), encryption_write_format => v1}),
    [
        begin
            Sealed = shigoto_crypto:seal(Plain, Result),
            ?assertNotEqual(Plain, Sealed),
            ?assertEqual({ok, Plain}, shigoto_crypto:open(Sealed, Result)),
            ?assertEqual(
                {ok, json:decode(Plain)}, shigoto_crypto:open_term(json:decode(Sealed), Result)
            ),
            ?assertEqual(current, shigoto_crypto:reseal(Sealed, Result)),
            %% Left in the clear by an earlier release, it cannot be told from a
            %% frame that does not open.
            ?assertEqual({error, decrypt_failed}, shigoto_crypto:open(Plain, Result))
        end
     || Plain <- [
            framed(~"enc:", binary:copy(<<7>>, 40)),
            framed(~"enc:v2:", binary:copy(<<7>>, 40))
        ]
    ],
    ok.

unique_keys_cover_every_key() ->
    Material = ~"{\"card\":\"4111\"}:my_worker",
    [Digest] = shigoto_crypto:unique_keys(Material),
    ?assertEqual(Digest, shigoto_crypto:unique_key(Material)),
    ?assertEqual(64, byte_size(Digest)),
    ?assertEqual(nomatch, binary:match(Digest, ~"4111")),
    set(#{encryption_keys => [key(2), key(1)]}),
    ?assertMatch([New, Digest] when New =/= Digest, shigoto_crypto:unique_keys(Material)),
    set(#{}),
    ?assertEqual([Material], shigoto_crypto:unique_keys(Material)).

keys_are_checked_without_being_shown() ->
    ?assertEqual(ok, shigoto_crypto:check_keys()),
    Short = ~"only sixteen byt",
    Bad = [
        #{encryption_key => Short},
        #{encryption_key => binary:copy(~"k", 33)},
        #{encryption_key => "a list of thirty-two characters!"},
        #{encryption_keys => [key(1), Short]},
        #{encryption_keys => [key(1), key(2), key(1)]},
        #{encryption_keys => key(1)}
    ],
    [
        begin
            set(Env),
            {error, {invalid_encryption_key, Problem}} = shigoto_crypto:check_keys(),
            Text = iolist_to_binary(io_lib:format("~0p", [Problem])),
            [?assertEqual(nomatch, binary:match(Text, Key)) || Key <- [Short, key(1), key(2)]]
        end
     || Env <- Bad
    ],
    set(#{encryption_keys => [key(1), Short]}),
    ?assertEqual(
        {error,
            {invalid_encryption_key, #{
                setting => encryption_keys, position => 2, problem => {bytes, 16}
            }}},
        shigoto_crypto:check_keys()
    ),
    set(#{}),
    ?assertEqual(ok, shigoto_crypto:check_keys()).

a_bad_key_is_not_in_the_error() ->
    Short = ~"only sixteen byt",
    set(#{encryption_key => Short, encryption_write_format => v1}),
    try shigoto_crypto:seal(?PLAIN, ?ARGS) of
        Sealed -> ?assertEqual(nomatch, binary:match(Sealed, Short))
    catch
        error:Reason:Stack ->
            ?assertMatch({shigoto_crypto, _}, Reason),
            Text = iolist_to_binary(io_lib:format("~0p", [{Reason, Stack}])),
            ?assertEqual(nomatch, binary:match(Text, Short))
    end.

the_legacy_calls_still_work() ->
    Sealed = shigoto_crypto:encrypt(?PLAIN),
    ?assertMatch(<<"\"enc:", _/binary>>, Sealed),
    ?assertEqual(?PLAIN, shigoto_crypto:decrypt(Sealed)),
    ?assertEqual(?PLAIN, shigoto_crypto:decrypt(?PLAIN)),
    set(#{encryption_key => key(2)}),
    ?assertError({shigoto_crypto, decrypt_failed}, shigoto_crypto:decrypt(Sealed)),
    set(#{}),
    ?assertEqual(?PLAIN, shigoto_crypto:encrypt(?PLAIN)),
    ?assertError({shigoto_crypto, decrypt_failed}, shigoto_crypto:decrypt(Sealed)).

key(N) ->
    binary:copy(<<N>>, 32).

set(Env) ->
    [application:unset_env(shigoto, Key) || Key <- ?ENV],
    [application:set_env(shigoto, Key, Value) || Key := Value <- Env],
    ok.

frame_bytes(Sealed, Prefix) ->
    Frame = json:decode(Sealed),
    Size = byte_size(Prefix),
    <<Prefix:Size/binary, Encoded/binary>> = Frame,
    base64:decode(Encoded).

framed(Prefix, Bytes) ->
    iolist_to_binary([$", Prefix, base64:encode(Bytes), $"]).

flipped(Bytes, Position) ->
    <<Before:Position/binary, Byte, After/binary>> = Bytes,
    <<Before/binary, (Byte bxor 1), After/binary>>.
