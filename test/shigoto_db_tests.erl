-module(shigoto_db_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POOL, shigoto_db_tests_pool).

%% minato answers `command` as an atom for the command tags it knows and as
%% the tag itself, a binary, for one it does not. No statement shigoto runs
%% has such a tag today, and no released server can be made to send one, so
%% the connection here is a process that answers what it is told to. It
%% stands where shigoto_db keeps the connection of an open transaction, which
%% is the one place a statement is sent to a process this test can be.
db_test_() ->
    {foreach, fun() -> ok end, fun(_) -> erlang:erase({{shigoto_db, holder}, ?POOL}) end, [
        fun a_command_minato_does_not_know_is_answered_as_it_came/0,
        fun a_statement_that_ran_is_ok_whatever_its_command/0,
        fun a_statement_that_failed_is_still_an_error/0,
        fun a_column_under_its_name_as_a_binary_is_passed_on/0,
        fun the_columns_are_named_once/0
    ]}.

a_command_minato_does_not_know_is_answered_as_it_came() ->
    Result = #{command => ~"MERGE", num_rows => 3, rows => []},
    answering(Result),
    ?assertEqual(Result, shigoto_db:query(?POOL, ~"MERGE INTO t USING s ON true", [])),
    ?assertEqual(
        Result, shigoto_db:transaction(?POOL, fun() -> shigoto_db:query(?POOL, ~"x", []) end)
    ).

a_statement_that_ran_is_ok_whatever_its_command() ->
    [
        begin
            answering(#{command => Command, num_rows => 1, rows => []}),
            ?assertEqual({Command, ok}, {Command, shigoto_repo:update_progress(?POOL, 1, 50)}),
            ?assertEqual({Command, ok}, {Command, shigoto_batch:increment_total(?POOL, 1)}),
            ?assertEqual(
                {Command, ok},
                {Command,
                    shigoto_repo:upsert_cron_entry(?POOL, #{
                        name => ~"nightly", worker => shigoto_test_worker, schedule => ~"@daily"
                    })}
            )
        end
     || Command <- [update, insert, ~"UPDATE", ~"SOMETHING NEW"]
    ].

a_statement_that_failed_is_still_an_error() ->
    Refused = {error, {pgsql_error, #{code => ~"42P01"}}},
    answering(Refused),
    ?assertEqual(Refused, shigoto_repo:update_progress(?POOL, 1, 50)),
    ?assertEqual(Refused, shigoto_batch:increment_total(?POOL, 1)),
    ?assertEqual(Refused, shigoto_db:query(?POOL, ~"SELECT 1", [])).

%% What a client that makes no atoms answers for a column no module names.
a_column_under_its_name_as_a_binary_is_passed_on() ->
    Row = #{
        id => 7,
        worker => ~"shigoto_test_worker",
        queue => ~"default",
        state => ~"discarded",
        args => ~"{}",
        meta => ~"{}",
        errors => ~"[]",
        ~"added_by_the_operator" => ~"kept"
    },
    answering(#{command => select, num_rows => 1, rows => [Row]}),
    ?assertEqual({ok, Row}, shigoto_repo:get_job(?POOL, 7)),
    ?assertMatch(#{~"added_by_the_operator" := ~"kept"}, shigoto_job:redact(Row)),
    {ok, shigoto_test_worker, Opened} = shigoto_job:opened(Row),
    ?assertMatch(#{~"added_by_the_operator" := ~"kept", args := #{}}, Opened),
    ?assertMatch(#{~"worker" := ~"shigoto_test_worker"}, shigoto_error:entry(Row, timeout)).

the_columns_are_named_once() ->
    Columns = shigoto_db:columns(),
    ?assertEqual(lists:usort(Columns), Columns),
    ?assert(lists:all(fun is_atom/1, Columns)).

%% minato checks the options of a connection before it opens a socket, so
%% none of these needs a database. Nothing is started for a connection it
%% would refuse: a pool or a listener started only to stop is a crash report.
options_test_() ->
    [
        fun tls_options_without_tls_start_no_pool/0,
        fun tls_options_without_tls_start_no_listener/0,
        fun an_option_minato_does_not_take_as_written_is_named/0,
        fun a_name_minato_keeps_for_itself_is_no_pool/0
    ].

tls_options_without_tls_start_no_pool() ->
    [
        begin
            ?assertEqual(
                {{error, {invalid_option, ssl_options}}, []},
                with_errors_logged(fun() -> shigoto_db:start_pool(?POOL, Config) end)
            ),
            ?assertEqual(undefined, whereis(?POOL))
        end
     || Config <- [
            (connection())#{ssl_options => [{verify, verify_peer}]},
            (connection())#{ssl => false, ssl_options => []}
        ]
    ].

tls_options_without_tls_start_no_listener() ->
    Config = (connection())#{ssl_options => [{verify, verify_peer}]},
    ?assertEqual(
        {{error, {invalid_option, ssl_options}}, []},
        with_errors_logged(fun() -> shigoto_db:start_listener(?POOL, Config) end)
    ),
    ?assertEqual(undefined, whereis(?POOL)).

an_option_minato_does_not_take_as_written_is_named() ->
    [
        ?assertEqual(
            {Key, {{error, {invalid_option, Key}}, []}},
            {Key,
                with_errors_logged(fun() ->
                    shigoto_db:start_pool(?POOL, maps:merge(connection(), Config))
                end)}
        )
     || {Key, Config} <- [
            {ssl, #{ssl => ~"true"}},
            {ssl_options, #{ssl => true, ssl_options => [{reuse_sessions, true}]}},
            {host, #{hostname => 5432}},
            {password, #{password => 5432}}
        ]
    ].

a_name_minato_keeps_for_itself_is_no_pool() ->
    [
        ?assertEqual({error, {reserved_name, Name}}, shigoto_db:start_pool(Name, connection()))
     || Name <- [minato_overdue, minato_sup]
    ].

connection() ->
    #{host => "localhost", database => "shigoto_test", user => "postgres", password => "root"}.

%% What `Fun` answers, with every report logged as an error while it ran.
with_errors_logged(Fun) ->
    ok = shigoto_log_probe:attach(),
    try
        Answer = Fun(),
        {Answer, errors_logged()}
    after
        shigoto_log_probe:detach()
    end.

errors_logged() ->
    receive
        {log, error, Report} -> [Report | errors_logged()];
        {log, _Level, _Report} -> errors_logged()
    after 0 -> []
    end.

answering(Answer) ->
    Connection = spawn_link(fun() -> answer(Answer) end),
    erlang:put({{shigoto_db, holder}, ?POOL}, Connection).

answer(Answer) ->
    receive
        {run, From, Tag, _SQL, _Params, _Opts} ->
            From ! {Tag, Answer},
            answer(Answer)
    end.
