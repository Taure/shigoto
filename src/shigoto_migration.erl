-module(shigoto_migration).
-moduledoc ~"""
Database migration for Shigoto tables. Call `up/1` with a repo module
to create the jobs and cron tables.
""".

-export([up/1, down/1]).

-doc "Create the shigoto_jobs and shigoto_cron tables.".
-spec up(module()) -> ok | {error, term()}.
up(RepoMod) ->
    JobsSQL = <<
        "\n"
        "        CREATE TABLE IF NOT EXISTS shigoto_jobs (\n"
        "            id BIGSERIAL PRIMARY KEY,\n"
        "            queue TEXT NOT NULL DEFAULT 'default',\n"
        "            worker TEXT NOT NULL,\n"
        "            args JSONB NOT NULL DEFAULT '{}',\n"
        "            state TEXT NOT NULL DEFAULT 'available',\n"
        "            priority INTEGER NOT NULL DEFAULT 0,\n"
        "            attempt INTEGER NOT NULL DEFAULT 0,\n"
        "            max_attempts INTEGER NOT NULL DEFAULT 3,\n"
        "            scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n"
        "            attempted_at TIMESTAMPTZ,\n"
        "            completed_at TIMESTAMPTZ,\n"
        "            discarded_at TIMESTAMPTZ,\n"
        "            inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n"
        "            errors JSONB NOT NULL DEFAULT '[]',\n"
        "            meta JSONB NOT NULL DEFAULT '{}'\n"
        "        )\n"
        "    "
    >>,
    IndexSQL1 = <<
        "CREATE INDEX IF NOT EXISTS shigoto_jobs_queue_state_idx "
        "ON shigoto_jobs (queue, state, scheduled_at) "
        "WHERE state = 'available'"
    >>,
    IndexSQL2 = <<
        "CREATE INDEX IF NOT EXISTS shigoto_jobs_state_idx "
        "ON shigoto_jobs (state)"
    >>,
    CronSQL = <<
        "\n"
        "        CREATE TABLE IF NOT EXISTS shigoto_cron (\n"
        "            name TEXT PRIMARY KEY,\n"
        "            worker TEXT NOT NULL,\n"
        "            args JSONB NOT NULL DEFAULT '{}',\n"
        "            schedule TEXT NOT NULL,\n"
        "            queue TEXT NOT NULL DEFAULT 'default',\n"
        "            priority INTEGER NOT NULL DEFAULT 0,\n"
        "            max_attempts INTEGER NOT NULL DEFAULT 3,\n"
        "            last_scheduled_at TIMESTAMPTZ,\n"
        "            inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()\n"
        "        )\n"
        "    "
    >>,
    lists:foreach(
        fun(SQL) -> kura_repo_worker:pgo_query(RepoMod, SQL, []) end,
        [JobsSQL, IndexSQL1, IndexSQL2, CronSQL]
    ),
    ok.

-doc "Drop the shigoto tables.".
-spec down(module()) -> ok | {error, term()}.
down(RepoMod) ->
    kura_repo_worker:pgo_query(RepoMod, <<"DROP TABLE IF EXISTS shigoto_cron">>, []),
    kura_repo_worker:pgo_query(RepoMod, <<"DROP TABLE IF EXISTS shigoto_jobs">>, []),
    ok.
