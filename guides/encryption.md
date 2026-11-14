# Encryption

With a key configured, shigoto encrypts job data with AES-256-GCM before it is
written to PostgreSQL and decrypts it when a job is run or read. Workers
always receive plaintext args. For who this protects against, see
[Security](security.md).

## Configuration

Set a 32-byte key in `sys.config`:

```erlang
{shigoto, [
    {pool, my_app_db},
    {encryption_key, <<
        16#a1, 16#b2, 16#c3, 16#d4, 16#e5, 16#f6, 16#07, 16#18,
        16#29, 16#3a, 16#4b, 16#5c, 16#6d, 16#7e, 16#8f, 16#90,
        16#a1, 16#b2, 16#c3, 16#d4, 16#e5, 16#f6, 16#07, 16#18,
        16#29, 16#3a, 16#4b, 16#5c, 16#6d, 16#7e, 16#8f, 16#90
    >>}
]}.
```

Generate one with `crypto:strong_rand_bytes(32)` and keep it out of the
repository. The application does not start with a key of another size.

## What is encrypted

| Column | `encryption_write_format` `v1` (default) | `v2` |
|---|---|---|
| job `args` | encrypted | encrypted, bound to the worker |
| job `meta` | encrypted | encrypted, bound to the worker |
| cron entry `args` | encrypted | encrypted, bound to the worker |
| job `result` | **plaintext** | encrypted, bound to the job |
| `deps_results` (results handed to a waiting job) | **plaintext** | encrypted, bound to the job each came from |
| batch `callback_args` | **plaintext** | encrypted, bound to the callback worker |
| `unique_key` | HMAC-SHA256 of the unique fields | the same |
| `errors` | plaintext, values removed (see [Security](security.md#what-is-recorded-about-a-failure)) | the same |
| `worker`, `queue`, `tags`, `partition_key`, `state`, timestamps, cron `name` and `schedule` | plaintext | plaintext |

`v1` is the frame releases up to 1.10 write, and covers what they covered. It
stays the default for one release so that a rolling deploy is safe: a 1.10
node handed a v2 frame does not fail the job, it passes the frame to the
worker as if it were the args.

## How it works

1. On insert the args are JSON-encoded and encrypted under a fresh random
   96-bit nonce. The stored value is a JSON string, `"enc:..."` or
   `"enc:v2:..."`.
2. A claimed job is passed around as stored. It is decrypted when it is about
   to run, after its worker has been checked, and the plaintext exists only in
   the process running it.
3. A value that does not decrypt never reaches `perform/1`. The job fails with
   `decrypt_failed`, retries, and is discarded when it is out of attempts.
4. `shigoto:get_job/1`, `shigoto:get_batch/1` and `m:shigoto_dashboard`
   answer decrypted values. A value that does not open is shown as
   `"decrypt_failed"`, never as ciphertext.

Insert functions answer the row as stored: `args` in the map returned by
`shigoto:insert/1` is the ciphertext.

## Upgrading encryption

From a release that writes v1 (1.10 and earlier), with a key configured:

1. Deploy this release to every node. Nothing changes on disk.
2. Set `{encryption_write_format, v2}` on every node, then run
   `shigoto:reencrypt()` once. It rewrites stored jobs, archived jobs and
   batches as v2 and encrypts what was plaintext.
3. When it reports `failed => 0` and `skipped => 0`, set
   `{encryption_read_formats, [v2]}` and `{require_encrypted, true}`.

After step 3 a v1 frame, or a plaintext row inserted by hand, is refused
instead of run. `v2` becomes the default write format in the next minor
release.

`shigoto:reencrypt/0,1` is safe while the queue runs and can be run again at
any time: each value is written back only if the row still holds what was
read, and a row that changed is counted as `skipped`. It answers counts per
table:

```erlang
{ok, #{
    jobs := #{scanned := 1200, rewritten := 2350, skipped := 0, failed := 0},
    archive := #{...},
    batches := #{...}
}} = shigoto:reencrypt(#{batch_size => 500}).
```

`failed` counts values that do not open under any configured key. They are
left as they are.

Turning encryption on for a table that already holds plaintext jobs is the
same procedure from step 2.

## Key rotation

Use `encryption_keys`, a list. Values are written under the first key and
read under whichever key wrote them:

1. Deploy `{encryption_keys, [OldKey, NewKey]}` to every node. Every node can
   now read the new key; none writes under it.
2. Deploy `{encryption_keys, [NewKey, OldKey]}`. New values are written under
   `NewKey`.
3. Run `shigoto:reencrypt()`.
4. Deploy `{encryption_keys, [NewKey]}`.

Do not skip step 1 in a rolling deploy: a node that has not been given
`NewKey` yet fails the jobs written under it.

A unique job is looked up under every listed key and stored under the first,
so duplicates are still found across steps 1 to 3. `unique_key` is a hash and
is not rewritten by `reencrypt`: once `OldKey` is removed, a job inserted
under it is no longer found as a duplicate. Keep `OldKey` listed until those
jobs have left the states or the period their uniqueness covers. The same
goes for turning encryption on: a job inserted without a key and one inserted
with it are not deduplicated against each other.

A key should encrypt fewer than 2^32 values. In `v1` that counts every value
the key ever wrote. In `v2` each worker and column has its own derived key, so
the bound applies to each separately.

## Requiring encryption

By default a row with plaintext args is run even though a key is configured,
so that jobs inserted before encryption was turned on keep working. It also
means someone who can write to the table can enqueue a job without knowing
the key. `{require_encrypted, true}` closes that: plaintext `args` or `meta`
fail the job with `plaintext_refused`, and in `v2` a plaintext result is not
handed to a waiting job.

## Filtering on args

Stored args are ciphertext, so PostgreSQL cannot match them. With an encryption
key configured, an `args` filter on `shigoto:cancel_by/1,2`,
`shigoto:retry_by/1,2` or `shigoto_repo:find_jobs/2` (and so the DB-backed
`shigoto_testing` assertions) answers
`{error, args_filter_unsupported_with_encryption}` rather than matching
nothing. Filter on `worker`, `queue`, `tags` or `state` instead.

## Results that look like a frame

With a key configured, a stored JSON string that starts with `enc:` is taken
for a ciphertext. A worker that returns `{ok, <<"enc:...">>}` as its result
gets a result that fails to open. Return a map.

## Without encryption

If no key is configured, everything is stored as plaintext JSON. This is the
default.
