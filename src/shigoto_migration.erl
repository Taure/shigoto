-module(shigoto_migration).
-moduledoc ~"""
Database migrations for Shigoto tables. Call `up/1` with a pgo pool name
to create or update the jobs and cron tables.

Migrations are idempotent and safe to run multiple times.
""".

-export([up/1, down/1]).

-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

-doc "Create or update the shigoto_jobs and shigoto_cron tables.".
-spec up(atom()) -> ok | {error, term()}.
up(Pool) ->
    lists:foreach(
        fun(SQL) ->
            pgo:query(SQL, [], #{pool => Pool, decode_opts => ?DECODE_OPTS})
        end,
        v1_statements() ++ v2_statements() ++ v3_statements() ++ v4_statements() ++ v5_statements()
    ),
    ok.

-doc "Drop the shigoto tables.".
-spec down(atom()) -> ok | {error, term()}.
down(Pool) ->
    _ = pgo:query(~"DROP TRIGGER IF EXISTS shigoto_jobs_insert_trigger ON shigoto_jobs", [], #{
        pool => Pool
    }),
    _ = pgo:query(~"DROP FUNCTION IF EXISTS shigoto_notify_insert", [], #{pool => Pool}),
    _ = pgo:query(~"DROP TABLE IF EXISTS shigoto_jobs_archive", [], #{pool => Pool}),
    _ = pgo:query(~"DROP TABLE IF EXISTS shigoto_batches CASCADE", [], #{pool => Pool}),
    _ = pgo:query(~"DROP TABLE IF EXISTS shigoto_cron", [], #{pool => Pool}),
    _ = pgo:query(~"DROP TABLE IF EXISTS shigoto_jobs", [], #{pool => Pool}),
    ok.

%%----------------------------------------------------------------------
%% Migration versions
%%----------------------------------------------------------------------

v1_statements() ->
    [
        ~"""
        CREATE TABLE IF NOT EXISTS shigoto_jobs (
          id BIGSERIAL PRIMARY KEY,
          queue TEXT NOT NULL DEFAULT 'default',
          worker TEXT NOT NULL,
          args JSONB NOT NULL DEFAULT '{}',
          state TEXT NOT NULL DEFAULT 'available',
          priority INTEGER NOT NULL DEFAULT 0,
          attempt INTEGER NOT NULL DEFAULT 0,
          max_attempts INTEGER NOT NULL DEFAULT 3,
          scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          attempted_at TIMESTAMPTZ,
          completed_at TIMESTAMPTZ,
          discarded_at TIMESTAMPTZ,
          inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          errors JSONB NOT NULL DEFAULT '[]',
          meta JSONB NOT NULL DEFAULT '{}'
        )
        """,
        ~"""
        CREATE INDEX IF NOT EXISTS shigoto_jobs_queue_state_idx
        ON shigoto_jobs (queue, state, scheduled_at)
        WHERE state = 'available'
        """,
        ~"""
        CREATE INDEX IF NOT EXISTS shigoto_jobs_state_idx
        ON shigoto_jobs (state)
        """,
        ~"""
        CREATE TABLE IF NOT EXISTS shigoto_cron (
          name TEXT PRIMARY KEY,
          worker TEXT NOT NULL,
          args JSONB NOT NULL DEFAULT '{}',
          schedule TEXT NOT NULL,
          queue TEXT NOT NULL DEFAULT 'default',
          priority INTEGER NOT NULL DEFAULT 0,
          max_attempts INTEGER NOT NULL DEFAULT 3,
          last_scheduled_at TIMESTAMPTZ,
          inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    ].

v2_statements() ->
    [
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS unique_key TEXT",
        ~"""
        CREATE INDEX IF NOT EXISTS shigoto_jobs_unique_key_idx
        ON shigoto_jobs (unique_key)
        WHERE unique_key IS NOT NULL
        """
    ].

v3_statements() ->
    [
        <<
            "CREATE OR REPLACE FUNCTION shigoto_notify_insert() RETURNS trigger AS $$\n"
            "BEGIN\n"
            "  PERFORM pg_notify('shigoto_jobs_insert', NEW.queue);\n"
            "  RETURN NEW;\n"
            "END;\n"
            "$$ LANGUAGE plpgsql"
        >>,
        <<
            "DO $$ BEGIN\n"
            "  IF NOT EXISTS (\n"
            "    SELECT 1 FROM pg_trigger WHERE tgname = 'shigoto_jobs_insert_trigger'\n"
            "  ) THEN\n"
            "    CREATE TRIGGER shigoto_jobs_insert_trigger\n"
            "    AFTER INSERT ON shigoto_jobs\n"
            "    FOR EACH ROW EXECUTE FUNCTION shigoto_notify_insert();\n"
            "  END IF;\n"
            "END $$"
        >>
    ].

v4_statements() ->
    [
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT '{}'",
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_tags_idx ON shigoto_jobs USING GIN (tags)",
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS progress INTEGER NOT NULL DEFAULT 0",
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS batch_id BIGINT",
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ",
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ",
        <<
            "CREATE TABLE IF NOT EXISTS shigoto_batches (\n"
            "  id BIGSERIAL PRIMARY KEY,\n"
            "  callback_worker TEXT,\n"
            "  callback_args JSONB NOT NULL DEFAULT '{}',\n"
            "  total_jobs INTEGER NOT NULL DEFAULT 0,\n"
            "  completed_jobs INTEGER NOT NULL DEFAULT 0,\n"
            "  discarded_jobs INTEGER NOT NULL DEFAULT 0,\n"
            "  state TEXT NOT NULL DEFAULT 'active',\n"
            "  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n"
            "  completed_at TIMESTAMPTZ\n"
            ")"
        >>,
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_batch_id_idx ON shigoto_jobs (batch_id) WHERE batch_id IS NOT NULL"
    ].

v5_statements() ->
    [
        %% Partitioned queues
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS partition_key TEXT",
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_partition_idx ON shigoto_jobs (queue, partition_key, state, scheduled_at) WHERE state = 'available' AND partition_key IS NOT NULL",
        %% Job dependencies
        ~"ALTER TABLE shigoto_jobs ADD COLUMN IF NOT EXISTS depends_on BIGINT[] NOT NULL DEFAULT '{}'",
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_depends_on_idx ON shigoto_jobs USING GIN (depends_on) WHERE depends_on != '{}'",
        %% Archive table (same schema as jobs)
        <<
            "CREATE TABLE IF NOT EXISTS shigoto_jobs_archive (\n"
            "  id BIGINT PRIMARY KEY,\n"
            "  queue TEXT NOT NULL,\n"
            "  worker TEXT NOT NULL,\n"
            "  args JSONB NOT NULL DEFAULT '{}',\n"
            "  state TEXT NOT NULL,\n"
            "  priority INTEGER NOT NULL DEFAULT 0,\n"
            "  attempt INTEGER NOT NULL DEFAULT 0,\n"
            "  max_attempts INTEGER NOT NULL DEFAULT 3,\n"
            "  scheduled_at TIMESTAMPTZ NOT NULL,\n"
            "  attempted_at TIMESTAMPTZ,\n"
            "  completed_at TIMESTAMPTZ,\n"
            "  discarded_at TIMESTAMPTZ,\n"
            "  cancelled_at TIMESTAMPTZ,\n"
            "  inserted_at TIMESTAMPTZ NOT NULL,\n"
            "  errors JSONB NOT NULL DEFAULT '[]',\n"
            "  meta JSONB NOT NULL DEFAULT '{}',\n"
            "  unique_key TEXT,\n"
            "  tags TEXT[] NOT NULL DEFAULT '{}',\n"
            "  progress INTEGER NOT NULL DEFAULT 0,\n"
            "  batch_id BIGINT,\n"
            "  heartbeat_at TIMESTAMPTZ,\n"
            "  partition_key TEXT,\n"
            "  depends_on BIGINT[] NOT NULL DEFAULT '{}',\n"
            "  archived_at TIMESTAMPTZ NOT NULL DEFAULT now()\n"
            ")"
        >>,
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_archive_worker_idx ON shigoto_jobs_archive (worker)",
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_archive_queue_idx ON shigoto_jobs_archive (queue)",
        ~"CREATE INDEX IF NOT EXISTS shigoto_jobs_archive_inserted_at_idx ON shigoto_jobs_archive (inserted_at)"
    ].
