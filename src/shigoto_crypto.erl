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

-export([encrypt/1, decrypt/1, is_enabled/0, unique_digest/1, unique_digests/1]).

-define(AAD, <<"shigoto">>).

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

-doc "Check if encryption is configured.".
-spec is_enabled() -> boolean().
is_enabled() ->
    current_key() =/= undefined.

-doc """
Digest a uniqueness identity for storage in `shigoto_jobs.unique_key`.

The identity is built from the job's worker, args and queue, so storing it
verbatim would put args in the clear next to the encrypted `args` column.
Only equality matters to deduplication, so a digest is enough. With a key
configured the digest is HMAC-SHA-256 under the current key, which stops a
reader of the table from confirming a guessed argument offline.
""".
-spec unique_digest(binary()) -> binary().
unique_digest(Identity) ->
    hd(unique_digests(Identity)).

-doc """
Every digest a stored `unique_key` could carry for this identity, current
key first. Under key rotation an in-flight job was keyed with an older key,
so a lookup has to match any of them.

The unkeyed digest is a candidate only when no key is configured, or when
`accept_unkeyed_unique_digests` is set. It is computable without the key, so
accepting it lets anyone who can write to `shigoto_jobs` plant a row that
suppresses a unique job - use it for one drain cycle when adopting
encryption, not as a standing setting.

Neither switch covers *disabling* encryption: the key needed to recompute
those digests is gone. Leave a retired key in `encryption_keys` until the
jobs digested under it have drained, exactly as decryption requires.
""".
-spec unique_digests(binary()) -> [binary(), ...].
unique_digests(Identity) ->
    Unkeyed = hex(crypto:hash(sha256, Identity)),
    case all_keys() of
        [] ->
            [Unkeyed];
        Keys ->
            Keyed = [hex(crypto:mac(hmac, sha256, Key, Identity)) || Key <- Keys],
            case shigoto_config:accept_unkeyed_unique_digests() of
                true -> Keyed ++ [Unkeyed];
                false -> Keyed
            end
    end.

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

hex(Bin) ->
    binary:encode_hex(Bin, lowercase).

unwrap_json_string(<<"\"", Rest/binary>>) ->
    Size = byte_size(Rest) - 1,
    case Rest of
        <<Inner:Size/binary, "\"">> -> Inner;
        _ -> <<"\"", Rest/binary>>
    end;
unwrap_json_string(Bin) ->
    Bin.
