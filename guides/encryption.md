# Encryption

Shigoto supports AES-256-GCM encryption for job args at rest. When configured,
job arguments are encrypted before writing to PostgreSQL and decrypted
transparently when claimed. Workers always receive plaintext args.

## Configuration

Set a 32-byte encryption key in `sys.config`:

```erlang
{shigoto, [
    {pool, my_app_db},
    {encryption_key, <<
        16#a1, 16## b2, 16#c3, 16#d4, 16#e5, 16#f6, 16#07, 16#18,
        16#29, 16#3a, 16#4b, 16#5c, 16#6d, 16#7e, 16#8f, 16#90,
        16#a1, 16#b2, 16#c3, 16#d4, 16#e5, 16#f6, 16#07, 16#18,
        16#29, 16#3a, 16#4b, 16#5c, 16#6d, 16#7e, 16#8f, 16#90
    >>}
]}.
```

Or generate a key at runtime:

```erlang
Key = crypto:strong_rand_bytes(32),
application:set_env(shigoto, encryption_key, Key).
```

## How It Works

1. On `insert/1`: args are JSON-encoded, then encrypted with AES-256-GCM
   using a random 12-byte IV. The ciphertext, IV, and auth tag are stored
   as a single binary in the `args` column.
2. On `claim_jobs/3`: the encrypted args are decrypted and returned as
   the original JSON binary.
3. Workers call `perform/1` with the original plaintext map — no decryption
   needed in worker code.

## Key Rotation

For periodic key rotation, use `encryption_keys` (a list, newest first):

```erlang
{shigoto, [
    {pool, my_app_db},
    {encryption_keys, [
        NewKey,   %% Used for new encryptions
        OldKey    %% Still used for decryption of existing jobs
    ]}
]}.
```

When a job is claimed, shigoto tries decryption with each key in order.
If the current key fails, it falls back to older keys. On successful
decryption with an older key, the args are re-encrypted with the newest
key on the next write.

## What's Encrypted

- Job `args` — the arguments map passed to workers
- Job `meta` - encrypted and decrypted on the same path as `args`

The `unique_key` column is a digest, never the identity it was built from,
so a job with `unique => #{keys => [worker, args]}` does not leak its args
into a neighbouring column. With a key configured the digest is HMAC-SHA-256
under the current key, so a low-entropy argument cannot be confirmed by
guessing it and hashing offline.

Without a key it is a plain SHA-256, which is **not** a confidentiality
control: `queue` and `worker` sit in the clear in their own columns, so an
attacker holding the table only has to guess the args, which are usually a
user id or an email. That is no worse than the unencrypted `args` column
beside it, but do not read it as protection.

### Enabling encryption on a running system

New jobs are digested under the key; jobs already queued were digested
unkeyed, so they stop matching and can be enqueued a second time. To avoid
that, set `accept_unkeyed_unique_digests` for one drain cycle:

```erlang
{shigoto, [{accept_unkeyed_unique_digests, true}]}
```

Lookups then also match the unkeyed digest. Turn it back off once the older
jobs have drained: the unkeyed digest is computable without the key, so while
it is accepted anyone able to write to `shigoto_jobs` can plant a row that
suppresses a unique job. Shigoto logs a warning at boot while it is on.

Disabling encryption cannot be smoothed over the same way - the key needed to
recompute those digests is gone. Leave a retired key in `encryption_keys`
until the jobs digested under it have drained, exactly as decryption already
requires.

Everything else on the row - `queue`, `worker`, `tags`, `errors`, `result`,
`deps_results`, and the timestamps - is stored in the clear. Do not put
sensitive values in a tag, a partition key, or a returned result and expect
encryption to cover them.

## Without Encryption

If no encryption key is configured, args are stored as plaintext JSON.
This is the default. You can enable encryption at any time — new jobs
will be encrypted, existing plaintext jobs continue to work.
