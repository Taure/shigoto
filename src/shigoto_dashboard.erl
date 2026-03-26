-module(shigoto_dashboard).
-moduledoc """
Dashboard queries for Shigoto. Provides statistics and search functions
for building admin UIs, monitoring dashboards, and Nova Liveboard pages.

## Queue Statistics

```erlang
shigoto_dashboard:queue_stats() ->
    [#{queue => <<\"default\">>, available => 42, executing => 5,
       retryable => 2, completed => 1000, discarded => 3}]
```

## Job Search

```erlang
shigoto_dashboard:search_jobs(#{worker => my_worker, state => failed, limit => 20})
```
""".

-export([
    queue_stats/0,
    worker_stats/0,
    job_counts/0,
    search_jobs/1,
    recent_failures/1,
    stale_jobs/0,
    batch_stats/0
]).

-define(POOL, (shigoto_config:pool())).
-define(DECODE_OPTS, [return_rows_as_maps, column_name_as_atom]).

-doc "Get per-queue job counts grouped by state.".
-spec queue_stats() -> {ok, [map()]} | {error, term()}.
queue_stats() ->
    SQL =
        <<
            "SELECT queue, state, count(*) as count\n"
            "FROM shigoto_jobs\n"
            "GROUP BY queue, state\n"
            "ORDER BY queue, state"
        >>,
    case query(SQL, []) of
        #{rows := Rows} -> {ok, pivot_queue_stats(Rows)};
        {error, _} = Err -> Err
    end.

-doc "Get per-worker job counts and average execution stats.".
-spec worker_stats() -> {ok, [map()]} | {error, term()}.
worker_stats() ->
    SQL =
        <<
            "SELECT worker,\n"
            "  count(*) as total,\n"
            "  count(*) FILTER (WHERE state = 'completed') as completed,\n"
            "  count(*) FILTER (WHERE state = 'executing') as executing,\n"
            "  count(*) FILTER (WHERE state = 'discarded') as discarded,\n"
            "  count(*) FILTER (WHERE state = 'retryable') as retryable,\n"
            "  count(*) FILTER (WHERE state = 'available') as available\n"
            "FROM shigoto_jobs\n"
            "GROUP BY worker\n"
            "ORDER BY total DESC"
        >>,
    case query(SQL, []) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Get global job counts by state.".
-spec job_counts() -> {ok, map()} | {error, term()}.
job_counts() ->
    SQL =
        <<
            "SELECT\n"
            "  count(*) FILTER (WHERE state = 'available') as available,\n"
            "  count(*) FILTER (WHERE state = 'executing') as executing,\n"
            "  count(*) FILTER (WHERE state = 'retryable') as retryable,\n"
            "  count(*) FILTER (WHERE state = 'completed') as completed,\n"
            "  count(*) FILTER (WHERE state = 'discarded') as discarded,\n"
            "  count(*) FILTER (WHERE state = 'cancelled') as cancelled,\n"
            "  count(*) as total\n"
            "FROM shigoto_jobs"
        >>,
    case query(SQL, []) of
        #{rows := [Row]} -> {ok, Row};
        {error, _} = Err -> Err
    end.

-doc "Search jobs with filters. Supports: worker, queue, state, tags, limit, offset.".
-spec search_jobs(map()) -> {ok, [map()]} | {error, term()}.
search_jobs(Filters) ->
    Limit = maps:get(limit, Filters, 50),
    Offset = maps:get(offset, Filters, 0),
    SearchFilters = maps:without([limit, offset], Filters),
    {WhereClauses, Params, NextIdx} = build_search_clauses(SearchFilters, 1),
    WhereSQL =
        case WhereClauses of
            [] -> ~"true";
            _ -> iolist_to_binary(lists:join(~" AND ", WhereClauses))
        end,
    LimitIdx = integer_to_binary(NextIdx),
    OffsetIdx = integer_to_binary(NextIdx + 1),
    SQL = iolist_to_binary([
        ~"SELECT * FROM shigoto_jobs WHERE ",
        WhereSQL,
        ~" ORDER BY id DESC LIMIT $",
        LimitIdx,
        ~" OFFSET $",
        OffsetIdx
    ]),
    case query(SQL, Params ++ [Limit, Offset]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Get the most recent failed jobs.".
-spec recent_failures(pos_integer()) -> {ok, [map()]} | {error, term()}.
recent_failures(Limit) ->
    SQL =
        <<
            "SELECT * FROM shigoto_jobs\n"
            "WHERE state IN ('retryable', 'discarded')\n"
            "ORDER BY attempted_at DESC\n"
            "LIMIT $1"
        >>,
    case query(SQL, [Limit]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Get jobs stuck in executing state (potential zombies).".
-spec stale_jobs() -> {ok, [map()]} | {error, term()}.
stale_jobs() ->
    Threshold = shigoto_config:heartbeat_interval() * 2 div 1000,
    SQL =
        <<
            "SELECT * FROM shigoto_jobs\n"
            "WHERE state = 'executing'\n"
            "AND (\n"
            "  (heartbeat_at IS NOT NULL AND heartbeat_at < now() - make_interval(secs => $1))\n"
            "  OR\n"
            "  (heartbeat_at IS NULL AND attempted_at < now() - make_interval(secs => $1))\n"
            ")"
        >>,
    case query(SQL, [Threshold]) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

-doc "Get batch statistics.".
-spec batch_stats() -> {ok, [map()]} | {error, term()}.
batch_stats() ->
    SQL =
        <<
            "SELECT * FROM shigoto_batches\n"
            "WHERE state != 'finished'\n"
            "ORDER BY inserted_at DESC\n"
            "LIMIT 100"
        >>,
    case query(SQL, []) of
        #{rows := Rows} -> {ok, Rows};
        {error, _} = Err -> Err
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

query(SQL, Params) ->
    pgo:query(SQL, Params, #{pool => ?POOL, decode_opts => ?DECODE_OPTS}).

pivot_queue_stats(Rows) ->
    GroupedByQueue = lists:foldl(
        fun(#{queue := Queue, state := State, count := Count}, Acc) ->
            QueueMap = maps:get(Queue, Acc, #{queue => Queue}),
            StateAtom = binary_to_existing_atom(State, utf8),
            Acc#{Queue => QueueMap#{StateAtom => Count}}
        end,
        #{},
        Rows
    ),
    maps:values(GroupedByQueue).

build_search_clauses(Filters, StartIdx) ->
    maps:fold(
        fun(Key, Value, {Clauses, Params, Idx}) ->
            case search_clause(Key, Value, Idx) of
                skip -> {Clauses, Params, Idx};
                {Clause, NewParams, NewIdx} -> {[Clause | Clauses], Params ++ NewParams, NewIdx}
            end
        end,
        {[], [], StartIdx},
        Filters
    ).

search_clause(worker, Worker, Idx) ->
    IBin = integer_to_binary(Idx),
    WorkerBin =
        case Worker of
            W when is_atom(W) -> atom_to_binary(W, utf8);
            W when is_binary(W) -> W
        end,
    {<<"worker = $", IBin/binary>>, [WorkerBin], Idx + 1};
search_clause(queue, Queue, Idx) ->
    IBin = integer_to_binary(Idx),
    {<<"queue = $", IBin/binary>>, [Queue], Idx + 1};
search_clause(state, State, Idx) ->
    IBin = integer_to_binary(Idx),
    StateBin =
        case State of
            S when is_atom(S) -> atom_to_binary(S, utf8);
            S when is_binary(S) -> S
        end,
    {<<"state = $", IBin/binary>>, [StateBin], Idx + 1};
search_clause(tags, Tags, Idx) when is_list(Tags) ->
    IBin = integer_to_binary(Idx),
    {<<"tags @> $", IBin/binary>>, [Tags], Idx + 1};
search_clause(_, _, _Idx) ->
    skip.
