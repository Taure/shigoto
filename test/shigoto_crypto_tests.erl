-module(shigoto_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY_A, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>).
-define(KEY_B, <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>).

with_env(Env, Fun) ->
    Saved = [{K, application:get_env(shigoto, K)} || {K, _} <- Env],
    [application:set_env(shigoto, K, V) || {K, V} <- Env],
    try
        Fun()
    after
        [
            case Old of
                undefined -> application:unset_env(shigoto, K);
                {ok, V} -> application:set_env(shigoto, K, V)
            end
         || {K, Old} <- Saved
        ]
    end.

unkeyed_digest_is_hex_sha256_test() ->
    with_env([{encryption_key, undefined}, {encryption_keys, []}], fun() ->
        Identity = <<"{\"ssn\":\"191212121212\"}:my_worker">>,
        Expected = binary:encode_hex(crypto:hash(sha256, Identity), lowercase),
        ?assertEqual([Expected], shigoto_crypto:unique_digests(Identity)),
        ?assertEqual(Expected, shigoto_crypto:unique_digest(Identity))
    end).

digest_never_contains_the_identity_test() ->
    Identity = <<"{\"ssn\":\"191212121212\"}:my_worker">>,
    Envs = [
        [{encryption_key, undefined}, {encryption_keys, []}],
        [{encryption_key, ?KEY_A}, {encryption_keys, []}]
    ],
    [
        with_env(Env, fun() ->
            Digest = shigoto_crypto:unique_digest(Identity),
            ?assertEqual(nomatch, binary:match(Digest, <<"191212121212">>)),
            ?assertEqual(64, byte_size(Digest))
        end)
     || Env <- Envs
    ].

keyed_digest_differs_from_unkeyed_test() ->
    Identity = <<"worker:args">>,
    Unkeyed = with_env([{encryption_key, undefined}, {encryption_keys, []}], fun() ->
        shigoto_crypto:unique_digest(Identity)
    end),
    Keyed = with_env([{encryption_key, ?KEY_A}, {encryption_keys, []}], fun() ->
        shigoto_crypto:unique_digest(Identity)
    end),
    ?assertNotEqual(Unkeyed, Keyed).

unkeyed_digest_is_rejected_by_default_test() ->
    Identity = <<"worker:args">>,
    Unkeyed = unkeyed_digest(Identity),
    with_env([{encryption_key, ?KEY_A}, {encryption_keys, []}], fun() ->
        ?assertNot(lists:member(Unkeyed, shigoto_crypto:unique_digests(Identity)))
    end).

unkeyed_digest_accepted_only_behind_the_flag_test() ->
    Identity = <<"worker:args">>,
    Unkeyed = unkeyed_digest(Identity),
    Env = [
        {encryption_key, ?KEY_A},
        {encryption_keys, []},
        {accept_unkeyed_unique_digests, true}
    ],
    with_env(Env, fun() ->
        Candidates = shigoto_crypto:unique_digests(Identity),
        %% Stored value stays the HMAC; the flag only widens lookup.
        ?assertNotEqual(Unkeyed, hd(Candidates)),
        ?assertEqual(Unkeyed, lists:last(Candidates))
    end).

unkeyed_digest(Identity) ->
    with_env([{encryption_key, undefined}, {encryption_keys, []}], fun() ->
        shigoto_crypto:unique_digest(Identity)
    end).

rotation_yields_a_candidate_per_key_current_first_test() ->
    Identity = <<"worker:args">>,
    Current = with_env([{encryption_key, undefined}, {encryption_keys, [?KEY_A]}], fun() ->
        shigoto_crypto:unique_digest(Identity)
    end),
    Old = with_env([{encryption_key, undefined}, {encryption_keys, [?KEY_B]}], fun() ->
        shigoto_crypto:unique_digest(Identity)
    end),
    with_env([{encryption_key, undefined}, {encryption_keys, [?KEY_A, ?KEY_B]}], fun() ->
        ?assertEqual([Current, Old], shigoto_crypto:unique_digests(Identity))
    end).

distinct_identities_give_distinct_digests_test() ->
    with_env([{encryption_key, ?KEY_A}, {encryption_keys, []}], fun() ->
        ?assertNotEqual(
            shigoto_crypto:unique_digest(<<"a:worker">>),
            shigoto_crypto:unique_digest(<<"b:worker">>)
        )
    end).

roundtrip_encrypt_decrypt_test() ->
    with_env([{encryption_key, ?KEY_A}, {encryption_keys, []}], fun() ->
        Plaintext = <<"{\"ssn\":\"191212121212\"}">>,
        Encrypted = shigoto_crypto:encrypt(Plaintext),
        ?assertEqual(nomatch, binary:match(Encrypted, <<"191212121212">>)),
        ?assertEqual(Plaintext, shigoto_crypto:decrypt(Encrypted))
    end).
