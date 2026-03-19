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
        fun(SQL) -> pgo:query(SQL, [], #{pool => Pool, decode_opts => ?DECODE_OPTS}) end,
        v1_statements() ++ v2_statements() ++ v3_statements()
    ),
    ok.

-doc "Drop the shigoto tables.".
-spec down(atom()) -> ok | {error, term()}.
down(Pool) ->
    _ = pgo:query(~"DROP TRIGGER IF EXISTS shigoto_jobs_insert_trigger ON shigoto_jobs", [], #{
        pool => Pool
    }),
    _ = pgo:query(~"DROP FUNCTION IF EXISTS shigoto_notify_insert", [], #{pool => Pool}),
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
        ~"""
        CREATE OR REPLACE FUNCTION shigoto_notify_insert() RETURNS trigger AS $$
        BEGIN
          PERFORM pg_notify('shigoto_jobs_insert', NEW.queue);
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """,
        ~"""
        DO $$ BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = 'shigoto_jobs_insert_trigger'
          ) THEN
            CREATE TRIGGER shigoto_jobs_insert_trigger
            AFTER INSERT ON shigoto_jobs
            FOR EACH ROW EXECUTE FUNCTION shigoto_notify_insert();
          END IF;
        END $$
        """
    ].
