-module(shigoto_crypto).
-moduledoc """
AES-256-GCM encryption for the columns that carry job data.

With a key configured, `seal/2` encrypts a value before it is written and
`open/2` decrypts it when a job is run or read. Workers never see ciphertext:
a value that cannot be opened fails the job (`decrypt_failed`) instead of
reaching `perform/1`.

## Keys

```erlang
{shigoto, [{encryption_key, Key}]}                 %% one key
{shigoto, [{encryption_keys, [NewKey, OldKey]}]}   %% rotation, newest first
```

A key is exactly 32 bytes. New values are written under the first key and read
under whichever key wrote them. `check_keys/0` runs at boot and stops the
application for a key of another size or a key listed twice.

## Frames

A ciphertext is stored as a JSON string, so it fits the JSONB columns.

**v1**, `"enc:" ++ base64(IV:12, Tag:16, CipherText)`, is what releases up to
1.10 write. Its associated data is a constant, so it is not bound to anything:
a v1 ciphertext copied into another row or column decrypts there.

**v2**, `"enc:v2:" ++ base64(KeyId:4, IV:12, Tag:16, CipherText)`, is bound to
its `t:context/0`: the column, and the worker the row names (or, for a result,
the id of the job that produced it). Both go into the associated data and into
the derivation of the key the value is encrypted under, a subkey of the
configured key (HKDF-SHA256). A v2 ciphertext moved to another column, or to a
row with another worker, fails to open. It is not bound to the row: someone
who can write to the table can still copy `args` between two jobs of the same
worker, which runs that worker again with args it has already been given.

`KeyId` names the key, so a v2 frame is opened with that key alone. A v1 frame
is tried under every configured key.

Which frame is written is `shigoto_config:encryption_write_format/0`: `v2`
unless `v1` is set. Releases up to 1.10 cannot open a v2 frame, so `v1` is for
the time such nodes run beside this release. In `v1` only what those releases
encrypt is encrypted: `args`, `meta` and cron entry args. In `v2` job results
and batch callback args are as well.

Which frames are read is `shigoto_config:encryption_read_formats/0`.

## A string that starts with `enc:`

`args`, `meta` and cron args are JSON objects in the clear, so a string that
starts with `enc:` is a frame there and nothing else. A job's result is
whatever the worker returned, and releases up to 1.10 never encrypted it, nor
batch callback args. In those two columns a string that starts with `enc:` is
a frame only when what follows is base64 of at least a frame's header (28
bytes for v1, 32 for v2); anything else is the plaintext it looks like. A
plaintext that would be read as a frame is always written sealed, also while
the write format is `v1`, so what this release writes is never mistaken. A
value an earlier release left in the clear that has the form of a frame cannot
be told from a ciphertext that does not open, and fails with `decrypt_failed`.

## Nonces

Every value gets a fresh 96-bit nonce from `crypto:strong_rand_bytes/1`. With
random nonces a key should encrypt fewer than 2^32 values: past that the
chance of a repeated nonce, which breaks GCM for the two values involved,
passes 2^-32. A v1 frame is encrypted under the configured key itself, so the
bound counts every value that key ever sealed; rotate the key before then. A
v2 frame is encrypted under a subkey per column and worker (per job, for a
result), so the bound applies to each of those separately.

## Failures

`open/2` answers `{error, Reason}` and `seal/2` raises
`error({shigoto_crypto, Reason})`. `Reason` is an atom: no key, plaintext or
ciphertext is ever part of it, since it ends up in logs and in the `errors`
column.
""".

-export([
    seal/2,
    open/2,
    open_term/2,
    reseal/2,
    is_enabled/0,
    is_frame/1,
    is_frame/2,
    unique_key/1,
    unique_keys/1,
    check_keys/0,
    encrypt/1,
    decrypt/1
]).

-export_type([context/0, failure/0]).

-doc """
What a v2 ciphertext is bound to: the column and the worker its row names, or
for a job's result the id of that job.
""".
-type context() ::
    {args | meta | cron_args | callback_args, Worker :: binary()} | {result, JobId :: integer()}.

-doc """
Why a value was not opened: it does not decrypt under any configured key
(`decrypt_failed`), its frame is one `encryption_read_formats` leaves out
(`format_refused`), or it is plaintext and `require_encrypted` is set
(`plaintext_refused`).
""".
-type failure() :: decrypt_failed | format_refused | plaintext_refused.

-define(V1_AAD, ~"shigoto").
-define(V2_AAD_PREFIX, ~"shigoto").
-define(V2_SALT, ~"shigoto/enc/v2").
-define(V2_KEY_INFO, ~"shigoto/v2/gcm").
-define(V2_KEY_ID_INFO, ~"shigoto/v2/key-id").
-define(UNIQUE_KEY_CONTEXT, ~"shigoto unique_key").
-define(KEY_BYTES, 32).
-define(IV_BYTES, 12).
-define(TAG_BYTES, 16).
-define(KEY_ID_BYTES, 4).

-doc """
Encrypt `Plain`, the JSON text of a value, for the column `Context`.

Answers the JSON text to store. That is `Plain` itself when no key is
configured, and for a result or batch callback args while the write format is
`v1`, which does not cover them.
""".
-spec seal(binary(), context()) -> binary().
seal(Plain, Context) when is_binary(Plain) ->
    case keys() of
        [] -> Plain;
        [Key | _] -> sealed(shigoto_config:encryption_write_format(), Key, Plain, Context)
    end.

sealed(v1, Key, Plain, {Column, _Bound} = Context) when
    Column =:= result; Column =:= callback_args
->
    case frame(Plain, Context) of
        plaintext -> Plain;
        _WouldReadAsAFrame -> json_string([~"enc:", base64:encode(sealed_v1(Key, Plain))])
    end;
sealed(v1, Key, Plain, _Context) ->
    json_string([~"enc:", base64:encode(sealed_v1(Key, Plain))]);
sealed(v2, Key, Plain, Context) ->
    json_string([~"enc:v2:", base64:encode(sealed_v2(Key, Plain, Context))]).

-doc """
Decrypt a stored value of the column `Context`.

A value that is not a frame is plaintext, and is answered as it is unless
`require_encrypted` is set and the configured write format would have
encrypted that column. An empty `meta` is always accepted: it is the column's
default.
""".
-spec open(binary(), context()) -> {ok, binary()} | {error, failure()}.
open(Stored, Context) when is_binary(Stored) ->
    case {frame(Stored, Context), keys()} of
        {plaintext, []} -> {ok, Stored};
        {plaintext, _Keys} -> plaintext(Stored, Context);
        {_Frame, []} -> unreadable(Stored, Context);
        {Frame, Keys} -> opened(Frame, Keys, Context)
    end.

%% Without a key nothing can be opened. A result is the one column a worker
%% writes freely, so a string that only looks like a frame is left alone there.
unreadable(Stored, {result, _JobId}) -> {ok, Stored};
unreadable(_Stored, _Context) -> {error, decrypt_failed}.

plaintext(Stored, {Column, _Bound}) ->
    case shigoto_config:require_encrypted() andalso is_covered(Column, Stored) of
        true -> {error, plaintext_refused};
        false -> {ok, Stored}
    end.

is_covered(meta, Stored) ->
    Stored =/= ~"{}";
is_covered(Column, _Stored) when Column =:= result; Column =:= callback_args ->
    shigoto_config:encryption_write_format() =:= v2;
is_covered(_Column, _Stored) ->
    true.

opened({Version, Encoded}, Keys, Context) ->
    case lists:member(Version, shigoto_config:encryption_read_formats()) of
        false ->
            {error, format_refused};
        true ->
            try base64:decode(Encoded) of
                Frame -> opened(Version, Frame, Keys, Context)
            catch
                _:_ -> {error, decrypt_failed}
            end
    end.

opened(v1, Frame, Keys, _Context) ->
    opened_v1(Keys, Frame);
opened(
    v2,
    <<KeyId:?KEY_ID_BYTES/binary, IV:?IV_BYTES/binary, Tag:?TAG_BYTES/binary, Cipher/binary>>,
    Keys,
    Context
) ->
    case [Key || Key <- Keys, key_id(Key) =:= KeyId] of
        [Key | _] ->
            Ctx = context_bytes(Context),
            decrypted(subkey(Key, Ctx), IV, Cipher, v2_aad(KeyId, Ctx), Tag);
        [] ->
            {error, decrypt_failed}
    end;
opened(v2, _Frame, _Keys, _Context) ->
    {error, decrypt_failed}.

opened_v1([], _Frame) ->
    {error, decrypt_failed};
opened_v1([Key | Rest], <<IV:?IV_BYTES/binary, Tag:?TAG_BYTES/binary, Cipher/binary>> = Frame) ->
    case decrypted(Key, IV, Cipher, ?V1_AAD, Tag) of
        {ok, _Plain} = Opened -> Opened;
        {error, _} -> opened_v1(Rest, Frame)
    end;
opened_v1(_Keys, _Frame) ->
    {error, decrypt_failed}.

-doc """
`open/2` for a value already decoded from JSON, such as one entry of a job's
`deps_results`. Answers the decoded plaintext.
""".
-spec open_term(term(), context()) -> {ok, term()} | {error, failure()}.
open_term(null, _Context) ->
    {ok, null};
open_term(<<"enc:", _/binary>> = Term, Context) ->
    Stored = json_string(Term),
    case frame(Stored, Context) of
        plaintext -> plain_term(Term, Context);
        _Frame -> opened_term(open(Stored, Context))
    end;
open_term(Term, Context) ->
    plain_term(Term, Context).

opened_term({ok, Plain}) ->
    try
        {ok, json:decode(Plain)}
    catch
        _:_ -> {error, decrypt_failed}
    end;
opened_term({error, _} = Failed) ->
    Failed.

plain_term(Term, {Column, _Bound}) ->
    Refused =
        keys() =/= [] andalso shigoto_config:require_encrypted() andalso
            is_covered(Column, <<>>),
    case Refused of
        true -> {error, plaintext_refused};
        false -> {ok, Term}
    end.

-doc """
A stored value as the current settings would write it, when it is not already:
a v1 frame while the write format is `v2`, a value under an older key, or
plaintext in a column the write format encrypts.

`current` when there is nothing to do, including when no key is configured.
""".
-spec reseal(binary(), context()) -> current | {resealed, binary()} | {error, failure()}.
reseal(Stored, Context) when is_binary(Stored) ->
    case keys() of
        [] ->
            current;
        [Key | _] ->
            case frame(Stored, Context) of
                plaintext -> resealed(Stored, Stored, Context);
                Frame -> reopened(Frame, Key, Stored, Context)
            end
    end.

%% A frame is opened before it is called current: one that was moved to
%% another row or column names the right key and still does not open here.
reopened(Frame, Key, Stored, Context) ->
    case open(Stored, Context) of
        {ok, Plain} ->
            case is_current(Frame, Key) of
                true -> current;
                false -> resealed(Plain, Stored, Context)
            end;
        {error, _} = Failed ->
            Failed
    end.

%% Plaintext is taken as it is: `require_encrypted` says what may run, and
%% encrypting what is still in the clear is how a table gets there.
resealed(Plain, Stored, Context) ->
    case seal(Plain, Context) of
        Stored -> current;
        Sealed -> {resealed, Sealed}
    end.

%% A v1 frame does not say which key wrote it; it is current when the newest
%% key opens it.
is_current({Version, Encoded}, Key) ->
    shigoto_config:encryption_write_format() =:= Version andalso
        try base64:decode(Encoded) of
            Frame -> is_under(Version, Frame, Key)
        catch
            _:_ -> false
        end.

is_under(v2, <<KeyId:?KEY_ID_BYTES/binary, _/binary>>, Key) ->
    KeyId =:= key_id(Key);
is_under(v1, Frame, Key) ->
    opened_v1([Key], Frame) =/= {error, decrypt_failed};
is_under(_Version, _Frame, _Key) ->
    false.

-doc """
Whether a stored value has the form of a ciphertext frame: a JSON string that
starts with `enc:`. `is_frame/2` says whether it is read as one in its column.
""".
-spec is_frame(binary()) -> boolean().
is_frame(Stored) when is_binary(Stored) ->
    frame(Stored) =/= plaintext.

-doc "Whether a stored value of the column `Context` is read as a ciphertext frame.".
-spec is_frame(binary(), context()) -> boolean().
is_frame(Stored, Context) when is_binary(Stored) ->
    frame(Stored, Context) =/= plaintext.

-doc """
The `unique_key` stored for a unique job, built from `Material`.

With an encryption key configured this is a hex HMAC-SHA256 of `Material`, so
the key carries no arg values; its HMAC key is derived from the current
encryption key for this use alone. Without one it is `Material` as it is.
""".
-spec unique_key(binary()) -> binary().
unique_key(Material) ->
    [Current | _Older] = unique_keys(Material),
    Current.

-doc """
Every `unique_key` a job with this `Material` may have been stored under: one
per configured key, the current key's first. A unique insert looks for all of
them, so rotating to a new key does not hide the jobs inserted before it.
""".
-spec unique_keys(binary()) -> [binary(), ...].
unique_keys(Material) ->
    case keys() of
        [] -> [Material];
        Keys -> [unique_digest(Key, Material) || Key <- Keys]
    end.

unique_digest(Key, Material) ->
    HashKey = crypto:mac(hmac, sha256, Key, ?UNIQUE_KEY_CONTEXT),
    binary:encode_hex(crypto:mac(hmac, sha256, HashKey, Material)).

-doc "Check if encryption is configured.".
-spec is_enabled() -> boolean().
is_enabled() ->
    keys() =/= [].

-doc """
Check the configured keys: each exactly 32 bytes, none listed twice.

The answer names the setting, the position of the key and what is wrong with
it, never the key.
""".
-spec check_keys() -> ok | {error, term()}.
check_keys() ->
    Single = shigoto_config:encryption_key(),
    Listed = shigoto_config:encryption_keys(),
    case {Single, Listed} of
        {undefined, []} ->
            ok;
        {_, Keys} when is_list(Keys), Keys =/= [] ->
            checked_keys(encryption_keys, Keys);
        {Key, []} ->
            checked_keys(encryption_key, [Key]);
        {_, _NotAList} ->
            {error, {invalid_encryption_key, #{setting => encryption_keys, problem => not_a_list}}}
    end.

checked_keys(Setting, Keys) ->
    Problems = [
        #{setting => Setting, position => Position, problem => Problem}
     || {Position, Key} <- lists:enumerate(Keys), Problem <- [key_problem(Key)], Problem =/= none
    ],
    case Problems of
        [Problem | _] ->
            {error, {invalid_encryption_key, Problem}};
        [] ->
            case length(lists:usort([key_id(Key) || Key <- Keys])) =:= length(Keys) of
                true ->
                    ok;
                false ->
                    {error,
                        {invalid_encryption_key, #{setting => Setting, problem => duplicate_key}}}
            end
    end.

key_problem(Key) when is_binary(Key), byte_size(Key) =:= ?KEY_BYTES -> none;
key_problem(Key) when is_binary(Key) -> {bytes, byte_size(Key)};
key_problem(_Key) -> not_a_binary.

-doc """
Encrypt a binary as a v1 frame, which is bound to nothing. Kept for callers of
earlier releases; shigoto itself uses `seal/2`.
""".
-spec encrypt(binary()) -> binary().
encrypt(Plain) when is_binary(Plain) ->
    case keys() of
        [] -> Plain;
        [Key | _] -> json_string([~"enc:", base64:encode(sealed_v1(Key, Plain))])
    end.

-doc """
Decrypt a v1 frame; anything else is answered as it is. Raises
`error({shigoto_crypto, decrypt_failed})` for a frame that does not open, where
earlier releases answered the ciphertext. shigoto itself uses `open/2`.
""".
-spec decrypt(binary()) -> binary().
decrypt(Stored) when is_binary(Stored) ->
    case {frame(Stored), keys()} of
        {{v1, Encoded}, [_ | _] = Keys} ->
            case opened({v1, Encoded}, Keys, {args, <<>>}) of
                {ok, Plain} -> Plain;
                {error, Reason} -> error({shigoto_crypto, Reason})
            end;
        {plaintext, _Keys} ->
            Stored;
        {_Frame, _Keys} ->
            error({shigoto_crypto, decrypt_failed})
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec keys() -> [binary()].
keys() ->
    case shigoto_config:encryption_keys() of
        [] ->
            case shigoto_config:encryption_key() of
                undefined -> [];
                Key -> [Key]
            end;
        Keys ->
            Keys
    end.

%% In a column earlier releases left in the clear, a string that starts with
%% "enc:" is only a frame when the rest can be one.
-spec frame(binary(), context()) -> plaintext | {v1 | v2, binary()}.
frame(Stored, {Column, _Bound}) when Column =:= result; Column =:= callback_args ->
    case frame(Stored) of
        {Version, Encoded} = Frame ->
            case is_well_formed(Version, Encoded) of
                true -> Frame;
                false -> plaintext
            end;
        plaintext ->
            plaintext
    end;
frame(Stored, _Context) ->
    frame(Stored).

is_well_formed(Version, Encoded) ->
    try base64:decode(Encoded) of
        Bytes -> byte_size(Bytes) >= header_bytes(Version)
    catch
        _:_ -> false
    end.

header_bytes(v1) -> ?IV_BYTES + ?TAG_BYTES;
header_bytes(v2) -> ?KEY_ID_BYTES + ?IV_BYTES + ?TAG_BYTES.

%% A frame is a JSON string that starts with "enc:".
-spec frame(binary()) -> plaintext | {v1 | v2, binary()}.
frame(<<"\"enc:v2:", Rest/binary>>) -> unquoted(v2, Rest);
frame(<<"\"enc:", Rest/binary>>) -> unquoted(v1, Rest);
frame(_Stored) -> plaintext.

unquoted(Version, Rest) ->
    Size = byte_size(Rest) - 1,
    case Rest of
        <<Encoded:Size/binary, "\"">> -> {Version, Encoded};
        _ -> {Version, <<>>}
    end.

json_string(Chars) ->
    iolist_to_binary([$", Chars, $"]).

%% Every crypto call sits in a try: an exception from the NIF carries the call's
%% arguments, the key among them, in its stacktrace.
sealed_v1(Key, Plain) ->
    IV = crypto:strong_rand_bytes(?IV_BYTES),
    {Cipher, Tag} = encrypted(Key, IV, Plain, ?V1_AAD),
    <<IV/binary, Tag/binary, Cipher/binary>>.

sealed_v2(Key, Plain, Context) ->
    Ctx = context_bytes(Context),
    KeyId = key_id(Key),
    IV = crypto:strong_rand_bytes(?IV_BYTES),
    {Cipher, Tag} = encrypted(subkey(Key, Ctx), IV, Plain, v2_aad(KeyId, Ctx)),
    <<KeyId/binary, IV/binary, Tag/binary, Cipher/binary>>.

-spec encrypted(binary(), binary(), binary(), binary()) -> {binary(), binary()}.
encrypted(Key, IV, Plain, AAD) ->
    try crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Plain, AAD, ?TAG_BYTES, true) of
        {Cipher, Tag} when is_binary(Cipher), is_binary(Tag) -> {Cipher, Tag}
    catch
        _:_ -> error({shigoto_crypto, encrypt_failed})
    end.

-spec decrypted(binary(), binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, decrypt_failed}.
decrypted(Key, IV, Cipher, AAD, Tag) ->
    try crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Cipher, AAD, Tag, false) of
        Plain when is_binary(Plain) -> {ok, Plain};
        _Error -> {error, decrypt_failed}
    catch
        _:_ -> {error, decrypt_failed}
    end.

v2_aad(KeyId, Ctx) ->
    <<?V2_AAD_PREFIX/binary, 2, KeyId/binary, Ctx/binary>>.

-spec context_bytes(context()) -> binary().
context_bytes({result, JobId}) when is_integer(JobId) ->
    context_bytes(~"result", integer_to_binary(JobId));
context_bytes({Column, Worker}) when is_atom(Column), is_binary(Worker) ->
    context_bytes(atom_to_binary(Column), Worker).

context_bytes(Column, Bound) ->
    <<(byte_size(Column)):16, Column/binary, (byte_size(Bound)):16, Bound/binary>>.

%% HKDF-SHA256 (RFC 5869) with one block of output, which is a key's length.
subkey(Key, Ctx) ->
    expanded(Key, <<?V2_KEY_INFO/binary, 0, Ctx/binary>>).

key_id(Key) ->
    binary:part(expanded(Key, ?V2_KEY_ID_INFO), 0, ?KEY_ID_BYTES).

expanded(Key, Info) ->
    try
        PRK = crypto:mac(hmac, sha256, ?V2_SALT, Key),
        crypto:mac(hmac, sha256, PRK, <<Info/binary, 1>>)
    catch
        _:_ -> error({shigoto_crypto, invalid_key})
    end.
