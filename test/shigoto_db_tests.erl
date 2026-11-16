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
        fun a_name_minato_keeps_for_itself_is_no_pool/0,
        fun every_option_of_a_minato_connection_is_handed_on/0,
        fun an_option_handed_on_is_one_minato_can_refuse/0,
        fun a_key_nothing_reads_is_warned_about_by_name/0,
        fun a_key_of_a_pool_or_of_a_kura_repo_is_not_warned_about/0
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

%% As written, apart from the name of the host, the database, the user and
%% the password, which keep the spellings and the types shigoto has always
%% taken. `pool_size` is the pool's and no part of a connection.
every_option_of_a_minato_connection_is_handed_on() ->
    Password = fun() -> ~"secret" end,
    AsWritten = #{
        port => 6543,
        parameters => #{~"application_name" => ~"shigoto"},
        ssl => true,
        ssl_options => [{verify, verify_peer}],
        channel_binding => require,
        auth => [scram_sha_256],
        connect_timeout => 1000,
        timeout => 60000,
        cancel_timeout => 2000,
        socket_options => [{send_timeout, 30000}],
        transport => inet,
        prepared_statements => 0,
        frame_opts => #{max_message_length => 1048576}
    },
    ?assertEqual(
        {ok, AsWritten#{
            host => "db.internal", database => ~"jobs", user => ~"shigoto", password => ~"secret"
        }},
        shigoto_db:connection(AsWritten#{
            hostname => ~"db.internal",
            database => jobs,
            username => "shigoto",
            password => "secret",
            pool_size => 3
        })
    ),
    ?assertEqual(
        {ok, #{host => "db.internal", user => ~"shigoto", password => Password}},
        shigoto_db:connection(#{host => 'db.internal', user => shigoto, password => Password})
    ).

an_option_handed_on_is_one_minato_can_refuse() ->
    [
        begin
            ?assertEqual(
                {Key, {{error, {invalid_option, Key}}, []}},
                {Key,
                    with_errors_logged(fun() ->
                        shigoto_db:start_pool(?POOL, (connection())#{Key => Value})
                    end)}
            ),
            ?assertEqual(
                {Key, {error, {invalid_option, Key}}},
                {Key, shigoto_db:start_listener(?POOL, (connection())#{Key => Value})}
            )
        end
     || {Key, Value} <- [
            {timeout, "5000"},
            {connect_timeout, -1},
            {cancel_timeout, soon},
            {channel_binding, required},
            {auth, scram_sha_256}
        ]
    ].

%% `sslmode` is libpq's and `ssl_optons` is misspelt: neither is read, and
%% the connection is opened without what they were meant to set. The warning
%% names them and holds no value, nor a key that is not an atom.
a_key_nothing_reads_is_warned_about_by_name() ->
    Config = (nowhere())#{
        sslmode => ~"require_and_verify",
        ssl_optons => [{cacertfile, "/secret/ca.pem"}],
        ~"secret_password" => true,
        "secret_host" => true
    },
    Expected = [#{name => ?POOL, keys => [not_an_atom, ssl_optons, sslmode]}],
    Pool = keys_not_read(fun() ->
        {ok, _} = shigoto_db:start_pool(?POOL, Config),
        minato:stop_pool(?POOL)
    end),
    Listener = keys_not_read(fun() ->
        {ok, _} = shigoto_db:start_listener(?POOL, Config),
        minato:stop_listener(?POOL)
    end),
    ?assertEqual(Expected, [maps:with([name, keys], Report) || Report <- Pool]),
    ?assertEqual(Expected, [maps:with([name, keys], Report) || Report <- Listener]),
    ?assertEqual(
        nomatch, re:run(io_lib:format("~0tp", [Pool ++ Listener]), "secret|require_and_verify")
    ).

%% Every key shigoto or minato reads, and the keys of a kura repo's
%% configuration, which is a map people hand to shigoto as it is.
a_key_of_a_pool_or_of_a_kura_repo_is_not_warned_about() ->
    Config = (nowhere())#{
        hostname => "localhost",
        username => "postgres",
        parameters => #{~"application_name" => ~"shigoto"},
        ssl => false,
        channel_binding => disable,
        auth => [scram_sha_256],
        connect_timeout => 1000,
        timeout => 60000,
        cancel_timeout => 2000,
        socket_options => [{send_timeout, 30000}],
        transport => inet,
        prepared_statements => 0,
        frame_opts => #{max_message_length => 1048576},
        pool_size => 1,
        pool => my_repo,
        pool_module => kura_pool_minato,
        driver_module => kura_driver_minato,
        backend => kura_backend_postgres,
        dialect => kura_dialect_pg,
        read_only => false,
        replicas => [],
        uuid_version => v7,
        encryption => #{},
        keyring => kura_keyring_env,
        queue_target => 50,
        queue_interval => 1000
    },
    ?assertEqual(
        [],
        keys_not_read(fun() ->
            {ok, _} = shigoto_db:start_pool(?POOL, Config),
            ok = minato:stop_pool(?POOL),
            {ok, _} = shigoto_db:start_listener(?POOL, Config),
            minato:stop_listener(?POOL)
        end)
    ).

%% A port nothing listens on: a pool and a listener start without a server.
nowhere() ->
    (connection())#{port => 1}.

keys_not_read(Fun) ->
    ok = shigoto_log_probe:attach(),
    try
        ok = Fun(),
        keys_not_read()
    after
        shigoto_log_probe:detach()
    end.

keys_not_read() ->
    receive
        {log, warning, #{msg := ~"shigoto_connection_keys_not_read"} = Report} ->
            [Report | keys_not_read()];
        {log, _Level, _Report} ->
            keys_not_read()
    after 0 -> []
    end.

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
