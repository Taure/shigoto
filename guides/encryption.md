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

| Column | `encryption_write_format` `v2` (default) | `v1` |
|---|---|---|
| job `args` | encrypted, bound to the worker | encrypted |
| job `meta` | encrypted, bound to the worker | encrypted |
| cron entry `args` | encrypted, bound to the worker | encrypted |
| job `result` | encrypted, bound to the job | **plaintext** |
| `deps_results` (results handed to a waiting job) | encrypted, bound to the job each came from | **plaintext** |
| batch `callback_args` | encrypted, bound to the callback worker | **plaintext** |
| `unique_key` | HMAC-SHA256 of the unique fields | the same |
| `errors` | plaintext, values removed (see [Security](security.md#what-is-recorded-about-a-failure)) | the same |
| `worker`, `queue`, `tags`, `partition_key`, `state`, timestamps, cron `name` and `schedule` | plaintext | plaintext |

`v2` is written unless `{encryption_write_format, v1}` is set. `v1` is the
frame releases up to 1.10 write, and covers what they covered. It exists for a
rolling upgrade from 1.10: a 1.10 node cannot open a v2 frame.

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

1. If 1.10 nodes and nodes on this release will run side by side (a rolling
   deploy), set `{encryption_write_format, v1}` in the configuration this
   release is deployed with. If every node is stopped and upgraded together,
   skip this step and step 3.
2. Deploy this release to every node. It reads v1 and v2.
3. Once no 1.10 node is left, remove `{encryption_write_format, v1}` on every
   node. New values are written as v2.
4. Run `shigoto:reencrypt()` once. It rewrites stored jobs, archived jobs and
   batches as v2 and encrypts what was plaintext.
5. When it reports `failed => 0` and `skipped => 0`, set
   `{encryption_read_formats, [v2]}` and `{require_encrypted, true}`.

After step 5 a v1 frame, or a plaintext row inserted by hand, is refused
instead of run.

What happens without step 1: a 1.10 node that claims a job written as v2
cannot open its args. It does not fail the job itself; it passes the stored
string to `perform/1` in place of the args map. A worker that matches on a
map fails with `function_clause`, the attempt is counted and the job is
retried, on whichever node claims it next. A job that only 1.10 nodes claim
runs out of attempts and is discarded. No plaintext is exposed.

While `v1` is set, `shigoto_encryption_write_format_v1` is logged once per
boot.

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

`args`, `meta` and cron args are objects in the clear, so a string that starts
with `enc:` is a ciphertext there. A result is whatever the worker returned,
and a worker may return `{ok, <<"enc:hello">>}`. In `result`, `deps_results`
and `callback_args` such a string is only taken for a ciphertext when the rest
is base64 of at least a frame's header (28 bytes for v1, 32 for v2). A result
that does have that form is stored encrypted, also in `v1`, so it is read back
as what the worker returned.

One case is left: a result of that exact form stored in the clear by 1.10 or
earlier, or before a key was configured, cannot be told from a ciphertext and
fails to open.

## Without encryption

If no key is configured, everything is stored as plaintext JSON. This is the
default.
