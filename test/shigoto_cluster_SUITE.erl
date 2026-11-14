-module(shigoto_cluster_SUITE).
-moduledoc """
Two nodes on one database. The second is a `peer` node that shares nothing
with this one but PostgreSQL, which is all two shigoto nodes ever share: there
is no distribution between them, so what happened is read from the rows.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    two_nodes_run_every_job_once/1,
    a_job_whose_node_died_runs_again_elsewhere/1,
    a_cancel_reaches_the_node_running_the_job/1,
    one_node_schedules_a_cron_minute/1
]).

-define(POOL, shigoto_test_pool).
-define(QUEUE, ~"cluster").

all() ->
    [
        two_nodes_run_every_job_once,
        a_job_whose_node_died_runs_again_elsewhere,
        a_cancel_reaches_the_node_running_the_job,
        one_node_schedules_a_cron_minute
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(minato),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = shigoto_test_repo:start(),
    ok = shigoto_migration:up(?POOL),
    Config.

end_per_suite(_Config) ->
    shigoto_migration:down(?POOL),
    ok.

init_per_testcase(_TestCase, Config) ->
    ok = clean(),
    Config.

end_per_testcase(_TestCase, Config) ->
    _ = [stop_peer(Peer) || {peer, Peer} <- Config],
    _ = application:stop(shigoto),
    _ = application:stop(seki),
    _ = [application:unset_env(shigoto, Key) || Key := _ <- env(main)],
    _ = application:unset_env(shigoto, cron),
    ok = clean().

%%----------------------------------------------------------------------
%% Cases
%%----------------------------------------------------------------------

two_nodes_run_every_job_once(_Config) ->
    Peer = peer(second),
    try
        ok = shigoto_cluster_node:start(env(main)),
        {ok, Jobs} = shigoto:insert_all([
            #{worker => shigoto_cluster_worker, args => #{~"n" => N}, queue => ?QUEUE}
         || N <- lists:seq(1, 200)
        ]),
        ok = wait_for(fun() -> count(~"state = 'completed'") =:= length(Jobs) end),
        %% A claim is an attempt: a job two nodes had claimed would be at 2.
        ?assertEqual(200, count(~"state = 'completed' AND attempt = 1")),
        ?assertEqual(0, count(~"errors <> '[]'::jsonb")),
        Nodes = ran_on(),
        ?assertEqual(200, lists:sum(maps:values(Nodes))),
        %% Both took part, or one node would have passed this on its own.
        #{~"main" := Main, ~"second" := Second} = Nodes,
        ?assert(Main > 0 andalso Second > 0)
    after
        stop_peer(Peer)
    end.

a_job_whose_node_died_runs_again_elsewhere(_Config) ->
    Peer = peer(blocking),
    {ok, #{id := Id}} = insert(),
    ok = wait_for(fun() -> count(~"state = 'executing' AND attempt = 1") =:= 1 end),
    %% No shutdown, no terminate/2: the node is gone with the job claimed.
    ok = kill_peer(Peer),
    ?assertEqual(1, count(~"state = 'executing'")),
    ok = shigoto_cluster_node:start(env(main)),
    ok = wait_for(fun() -> count(~"state = 'completed'") =:= 1 end),
    #{rows := [Row]} = shigoto_db:query(
        ?POOL,
        ~"SELECT attempt, errors::text AS errors, result::text AS result FROM shigoto_jobs WHERE id = $1",
        [Id]
    ),
    #{attempt := Attempt, errors := Errors, result := Result} = Row,
    ?assertEqual(2, Attempt),
    ?assertMatch([#{~"error" := ~"rescued", ~"attempt" := 1}], decoded(Errors)),
    ?assertEqual(#{~"ran_on" => ~"main"}, decoded(Result)).

a_cancel_reaches_the_node_running_the_job(_Config) ->
    Peer = peer(blocking),
    try
        {ok, #{id := Id}} = insert(),
        ok = wait_for(fun() -> peer:call(Peer, shigoto_executor, running, [Id]) =/= [] end),
        %% This node does not run the job: all it can do is change the row.
        ok = shigoto:cancel(Id),
        ?assertEqual(1, count(~"state = 'cancelled'")),
        %% The other node's heartbeat finds its claim gone and stops the run.
        ok = wait_for(fun() -> peer:call(Peer, shigoto_executor, running, [Id]) =:= [] end),
        ?assertEqual(1, count(~"state = 'cancelled' AND attempt = 1")),
        ?assertEqual(0, count(~"errors <> '[]'::jsonb"))
    after
        stop_peer(Peer)
    end.

one_node_schedules_a_cron_minute(_Config) ->
    Cron = [{~"cluster-cron", ~"* * * * *", shigoto_cluster_worker, #{}}],
    Peer = peer(second, #{cron => Cron}),
    try
        ok = shigoto_cluster_node:start((env(main))#{cron => Cron}),
        %% Both nodes make a pass for the same minute, again and again.
        Passes = [
            {shigoto_cron:schedule_once(), peer:call(Peer, shigoto_cron, schedule_once, [])}
         || _ <- lists:seq(1, 5)
        ],
        ?assertEqual(lists:duplicate(5, {ok, ok}), Passes),
        Scheduled = count(~"worker = 'shigoto_cluster_worker'"),
        #{rows := [#{minutes := Minutes}]} = shigoto_db:query(
            ?POOL,
            ~"SELECT count(DISTINCT date_trunc('minute', scheduled_at)) AS minutes FROM shigoto_jobs",
            []
        ),
        ?assertEqual(Minutes, Scheduled),
        ?assert(Scheduled >= 1)
    after
        stop_peer(Peer),
        shigoto_db:query(?POOL, ~"DELETE FROM shigoto_cron", [])
    end.

%%----------------------------------------------------------------------
%% Nodes
%%----------------------------------------------------------------------

env(Role) ->
    #{
        cluster_role => Role,
        queues => [{?QUEUE, 5}],
        poll_interval => 50,
        heartbeat_interval => 300,
        rescue_interval => 200,
        stage_interval => 200,
        workers => [shigoto_cluster_worker]
    }.

peer(Role) ->
    peer(Role, #{}).

peer(Role, Extra) ->
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io,
        args => code_path_args(code:get_path()),
        env => [{"SHIGOTO_TEST_DB_PORT", integer_to_list(shigoto_test_repo:port())}]
    }),
    ok = peer:call(Peer, shigoto_cluster_node, start, [maps:merge(env(Role), Extra)], 30000),
    Peer.

-spec code_path_args([string()]) -> [string()].
code_path_args([]) ->
    [];
code_path_args([Dir | Dirs]) ->
    case filelib:is_dir(Dir) of
        true -> ["-pa", Dir | code_path_args(Dirs)];
        false -> code_path_args(Dirs)
    end.

stop_peer(Peer) ->
    try
        peer:stop(Peer)
    catch
        _:_ -> ok
    end.

kill_peer(Peer) ->
    unlink(Peer),
    Ref = monitor(process, Peer),
    ok = peer:cast(Peer, erlang, halt, [0, [{flush, false}]]),
    receive
        {'DOWN', Ref, process, Peer, _} -> ok
    after 10000 -> ct:fail(peer_did_not_die)
    end.

%%----------------------------------------------------------------------
%% Rows
%%----------------------------------------------------------------------

insert() ->
    shigoto:insert(#{worker => shigoto_cluster_worker, args => #{}, queue => ?QUEUE}).

count(Where) ->
    #{rows := [#{count := Count}]} = shigoto_db:query(
        ?POOL, [~"SELECT count(*) AS count FROM shigoto_jobs WHERE ", Where], []
    ),
    Count.

ran_on() ->
    #{rows := Rows} = shigoto_db:query(
        ?POOL,
        ~"SELECT result->>'ran_on' AS node, count(*) AS jobs FROM shigoto_jobs GROUP BY 1",
        []
    ),
    #{Node => Jobs || #{node := Node, jobs := Jobs} <- Rows}.

decoded(Json) when is_binary(Json) ->
    json:decode(Json).

wait_for(Check) ->
    wait_for(Check, 400).

wait_for(_Check, 0) ->
    ct:fail(never_true);
wait_for(Check, Tries) ->
    case Check() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_for(Check, Tries - 1)
    end.

clean() ->
    [
        #{} = shigoto_db:query(?POOL, SQL, [])
     || SQL <- [
            ~"DELETE FROM shigoto_jobs",
            ~"DELETE FROM shigoto_jobs_archive",
            ~"DELETE FROM shigoto_batches"
        ]
    ],
    ok.
