-module(shigoto_crypto).
-moduledoc """
AES-256-GCM encryption for job args at rest.

When encryption is configured, job arguments are encrypted before
insertion and decrypted after claiming. This is transparent to workers.

## Single key

```erlang
{shigoto, [{encryption_key, <<"32-byte-secret-key-here..........">>}]}
```

## Key rotation

Use `encryption_keys` (list, newest first). New jobs are encrypted with
the first key. Decryption tries each key until one succeeds.

```erlang
{shigoto, [{encryption_keys, [
    <<"new-32-byte-key..................">>,
    <<"old-32-byte-key..................">>
]}]}
```

Old jobs are re-encrypted with the current key when claimed and re-inserted
(e.g. via retry). The old key can be removed once all jobs encrypted with
it have been processed.
""".

-export([encrypt/1, decrypt/1, is_enabled/0, unique_key/1]).

-define(AAD, <<"shigoto">>).
-define(UNIQUE_KEY_CONTEXT, ~"shigoto unique_key").

-doc "Encrypt a binary with the current key. Returns the original binary if not configured.".
-spec encrypt(binary()) -> binary().
encrypt(Plaintext) ->
    case current_key() of
        undefined -> Plaintext;
        Key -> do_encrypt(Key, Plaintext)
    end.

-doc "Decrypt a binary, trying all configured keys. Returns the original binary if not encrypted.".
-spec decrypt(binary()) -> binary().
decrypt(MaybeEncrypted) ->
    case all_keys() of
        [] ->
            MaybeEncrypted;
        Keys ->
            Unwrapped = unwrap_json_string(MaybeEncrypted),
            case Unwrapped of
                <<"enc:", _/binary>> -> try_decrypt(Keys, Unwrapped, MaybeEncrypted);
                _ -> MaybeEncrypted
            end
    end.

-doc """
The `unique_key` stored for a unique job, built from `Material`.

With an encryption key configured this is a hex HMAC-SHA256 of `Material`, so
the key carries no arg values; its HMAC key is derived from the current
encryption key for this use alone. Without one it is `Material` as it is.
""".
-spec unique_key(binary()) -> binary().
unique_key(Material) ->
    case current_key() of
        undefined ->
            Material;
        Key ->
            HashKey = crypto:mac(hmac, sha256, Key, ?UNIQUE_KEY_CONTEXT),
            binary:encode_hex(crypto:mac(hmac, sha256, HashKey, Material))
    end.

-doc "Check if encryption is configured.".
-spec is_enabled() -> boolean().
is_enabled() ->
    current_key() =/= undefined.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

current_key() ->
    case shigoto_config:encryption_keys() of
        [Key | _] -> Key;
        [] -> shigoto_config:encryption_key()
    end.

all_keys() ->
    case shigoto_config:encryption_keys() of
        [] ->
            case shigoto_config:encryption_key() of
                undefined -> [];
                Key -> [Key]
            end;
        Keys ->
            Keys
    end.

try_decrypt([], _Encrypted, Original) ->
    Original;
try_decrypt([Key | Rest], Encrypted, Original) ->
    try
        do_decrypt(Key, Encrypted)
    catch
        _:_ -> try_decrypt(Rest, Encrypted, Original)
    end.

do_encrypt(Key, Plaintext) ->
    IV = crypto:strong_rand_bytes(12),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Plaintext, ?AAD, 16, true
    ),
    Encoded = base64:encode(<<IV/binary, Tag/binary, Ciphertext/binary>>),
    iolist_to_binary(json:encode(<<"enc:", Encoded/binary>>)).

do_decrypt(Key, <<"enc:", Encoded/binary>>) ->
    Decoded = base64:decode(Encoded),
    <<IV:12/binary, Tag:16/binary, Ciphertext/binary>> = Decoded,
    crypto:crypto_one_time_aead(
        aes_256_gcm, Key, IV, Ciphertext, ?AAD, Tag, false
    ).

unwrap_json_string(<<"\"", Rest/binary>>) ->
    Size = byte_size(Rest) - 1,
    case Rest of
        <<Inner:Size/binary, "\"">> -> Inner;
        _ -> <<"\"", Rest/binary>>
    end;
unwrap_json_string(Bin) ->
    Bin.
