-module(shigoto_crypto).
-moduledoc """
AES-256-GCM encryption for job args and meta at rest.

When an encryption key is configured, job arguments are encrypted before
insertion and decrypted after claiming. This is transparent to workers.

Configure via:
```erlang
{shigoto, [{encryption_key, <<\"32-byte-secret-key-here.......\">>}]}
```

The key must be exactly 32 bytes for AES-256-GCM.
""".

-export([encrypt/1, decrypt/1, is_enabled/0]).

-define(AAD, <<"shigoto">>).

-doc "Encrypt a binary if encryption is enabled. Returns the original binary otherwise.".
-spec encrypt(binary()) -> binary().
encrypt(Plaintext) ->
    case shigoto_config:encryption_key() of
        undefined -> Plaintext;
        Key -> do_encrypt(Key, Plaintext)
    end.

-doc "Decrypt a binary if encryption is enabled. Returns the original binary otherwise.".
-spec decrypt(binary()) -> binary().
decrypt(MaybeEncrypted) ->
    case shigoto_config:encryption_key() of
        undefined ->
            MaybeEncrypted;
        Key ->
            %% PGO returns JSONB strings with surrounding quotes from json:encode
            Unwrapped = unwrap_json_string(MaybeEncrypted),
            case Unwrapped of
                <<"enc:", _/binary>> -> do_decrypt(Key, Unwrapped);
                _ -> MaybeEncrypted
            end
    end.

-doc "Check if encryption is configured.".
-spec is_enabled() -> boolean().
is_enabled() ->
    shigoto_config:encryption_key() =/= undefined.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

do_encrypt(Key, Plaintext) ->
    IV = crypto:strong_rand_bytes(12),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Plaintext, ?AAD, 16, true
    ),
    Encoded = base64:encode(<<IV/binary, Tag/binary, Ciphertext/binary>>),
    %% Wrap in a JSON string so it's valid JSONB for PostgreSQL
    iolist_to_binary(json:encode(<<"enc:", Encoded/binary>>)).

do_decrypt(Key, <<"enc:", Encoded/binary>>) ->
    Decoded = base64:decode(Encoded),
    <<IV:12/binary, Tag:16/binary, Ciphertext/binary>> = Decoded,
    crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Ciphertext, ?AAD, Tag, false
    ).

unwrap_json_string(<<"\"", Rest/binary>>) ->
    %% Strip surrounding quotes from JSON string value
    Size = byte_size(Rest) - 1,
    case Rest of
        <<Inner:Size/binary, "\"">> -> Inner;
        _ -> <<"\"", Rest/binary>>
    end;
unwrap_json_string(Bin) ->
    Bin.
