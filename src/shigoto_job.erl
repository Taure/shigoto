-module(shigoto_job).
-moduledoc false.

%% What may be done with a job row read from the database: which module runs it,
%% and when its encrypted columns are opened.
%%
%% A row is data anyone with write access to the table could have put there. So
%% the worker it names is checked before anything else (`worker/1`), and only for
%% a row that passes are `args`, `meta` and `deps_results` decrypted (`opened/1`).
%% A row naming a module that is not a worker, or one outside the configured
%% `workers`, is never decrypted and nothing in that module is called.
%%
%% Rows are passed around as they were read, still encrypted: the queue, the
%% executor's state and the telemetry events hold ciphertext. The plaintext exists
%% in the process that runs `perform/1` and in the executor while it waits for it.
%%
%% `readable/1` is for showing a job (`shigoto:get_job/1`, `m:shigoto_dashboard`),
%% and `redact/1` is the one way a job map goes into a log, a crash report or an
%% error term.

-export([worker/1, worker_name/1, opened/1, readable/1, redact/1, new_table/0]).

-define(WORKERS, shigoto_workers).
-define(UNKNOWN_FOR, 30).
-define(MAX_NAME_BYTES, 1020).
-define(WRITTEN_NAME_BYTES, 255).
-define(DATA_COLUMNS, [args, meta, result, deps_results, errors, callback_args]).
-define(DEPS, ~"_shigoto_deps").

-doc """
Create the table that remembers which names are workers. The calling process
owns it; `shigoto_executor_sup` calls this. Without the table every job is
checked from scratch, which is what a drain outside the application does.
""".
-spec new_table() -> ok.
new_table() ->
    case ets:whereis(?WORKERS) of
        undefined ->
            _ = ets:new(?WORKERS, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _Table ->
            ok
    end.

-doc """
The module that runs a job, when the job names a worker.

A worker is a module that can be loaded on this node, exports `perform/1` and,
when `shigoto_config:workers/0` is set, is in that list. A name outside the
list is refused before the module is looked for, so it is never loaded. A name
that is no atom on this node is refused without creating one. A name longer
than a module name can be is refused without being looked up, and the error
carries it cut (`worker_name/1`).

The answer is remembered: a known worker costs a table read and an
`erlang:function_exported/3` per job. A name that is not a worker is not asked
about again for 30 seconds.
""".
-spec worker(map() | binary() | atom()) -> {ok, module()} | {error, {unknown_worker, binary()}}.
worker(#{worker := Worker}) ->
    worker(Worker);
worker(Worker) when is_atom(Worker) ->
    worker(atom_to_binary(Worker));
worker(Name) when is_binary(Name), byte_size(Name) > ?MAX_NAME_BYTES ->
    {error, {unknown_worker, worker_name(Name)}};
worker(Name) when is_binary(Name) ->
    case remembered(Name) of
        {ok, Module} ->
            case is_allowed(Module) andalso erlang:function_exported(Module, perform, 1) of
                true -> {ok, Module};
                false -> resolved(Name)
            end;
        unknown ->
            {error, {unknown_worker, Name}};
        none ->
            resolved(Name)
    end;
worker(_Job) ->
    {error, {unknown_worker, ~"undefined"}}.

-doc """
A worker name as it is written to `errors`, a log or an event.

The name is whatever the row holds. A module name has at most 255 characters,
1020 bytes, so a longer name names no module and is cut to its first 255
bytes. Anything else is returned as it is.
""".
-spec worker_name(term()) -> term().
worker_name(Name) when is_binary(Name), byte_size(Name) > ?MAX_NAME_BYTES ->
    case unicode:characters_to_binary(binary:part(Name, 0, ?WRITTEN_NAME_BYTES)) of
        Whole when is_binary(Whole) -> Whole;
        {_Cut, Valid, _Rest} -> Valid
    end;
worker_name(Name) ->
    Name.

resolved(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Module ->
            case is_allowed(Module) andalso is_worker(Module) of
                true ->
                    remember({Name, Module}),
                    {ok, Module};
                false ->
                    remember({Name, unknown, erlang:monotonic_time(second) + ?UNKNOWN_FOR}),
                    {error, {unknown_worker, Name}}
            end
    catch
        error:badarg -> {error, {unknown_worker, Name}}
    end.

is_allowed(Module) ->
    case shigoto_config:workers() of
        undefined -> true;
        Workers -> lists:member(Module, Workers)
    end.

is_worker(Module) ->
    _ = code:ensure_loaded(Module),
    erlang:function_exported(Module, perform, 1).

-spec remembered(binary()) -> {ok, module()} | unknown | none.
remembered(Name) ->
    try ets:lookup(?WORKERS, Name) of
        [{_Name, Module}] when is_atom(Module) ->
            {ok, Module};
        [{_Name, unknown, Until}] when is_integer(Until) ->
            case erlang:monotonic_time(second) < Until of
                true -> unknown;
                false -> none
            end;
        _ ->
            none
    catch
        error:badarg -> none
    end.

remember(Entry) ->
    try
        ets:insert(?WORKERS, Entry)
    catch
        error:badarg -> true
    end.

-doc """
A job ready to run: its worker module, and the job with `args` decoded to a
map, `meta` decrypted and `deps_results` as `#{JobId => Result}`.

Nothing is decrypted unless `worker/1` accepts the job. A column that does not
open is an error, never a value: `decrypt_failed`, `format_refused` or
`plaintext_refused` (`t:shigoto_crypto:failure/0`).
""".
-spec opened(map()) ->
    {ok, module(), map()} | {error, {unknown_worker, binary()} | shigoto_crypto:failure()}.
opened(Job) ->
    case worker(Job) of
        {ok, Module} ->
            Name = atom_to_binary(Module),
            try
                {ok, Module, with_deps_results(with_meta(Job#{args => args(Job, Name)}, Name))}
            catch
                throw:{?MODULE, Reason} -> {error, Reason}
            end;
        {error, _} = Unknown ->
            Unknown
    end.

args(#{args := Args}, _Name) when is_map(Args) ->
    Args;
args(#{args := Args}, Name) when is_binary(Args) ->
    decoded(plain(shigoto_crypto:open(Args, {args, Name})), #{});
args(_Job, _Name) ->
    #{}.

with_meta(#{meta := Meta} = Job, Name) when is_binary(Meta) ->
    Job#{meta => plain(shigoto_crypto:open(Meta, {meta, Name}))};
with_meta(Job, _Name) ->
    Job.

with_deps_results(#{deps_results := Stored} = Job) when is_binary(Stored) ->
    case decoded(Stored, #{}) of
        Results when is_map(Results) ->
            Waited = waited_for(Job),
            Job#{
                deps_results =>
                    #{
                        job_id(Id) => result(job_id(Id), Result, Waited)
                     || Id := Result <- Results
                    }
            };
        _NotAnObject ->
            Job#{deps_results => #{}}
    end;
with_deps_results(Job) ->
    Job.

%% A result is bound to the job that produced it, not to a job that reads it:
%% copied whole into another row it opens. So a job is only handed the results
%% of the jobs it was inserted to wait for. Their ids are in its meta, under
%% `_shigoto_deps`, which is sealed for the job's worker.
%%
%% A job from a release that wrote no list is handed what its row holds, until
%% a plaintext result is refused: by then `shigoto:reencrypt/0,1` has given
%% every waiting job its list.
-spec waited_for(map()) -> any | [term()].
waited_for(Job) ->
    case meta(Job) of
        #{?DEPS := Ids} when is_list(Ids) ->
            Ids;
        #{?DEPS := _NotAList} ->
            [];
        _Unlisted ->
            case shigoto_crypto:is_required(result) of
                true -> [];
                false -> any
            end
    end.

meta(#{meta := Meta}) when is_binary(Meta) -> decoded(Meta, #{});
meta(#{meta := Meta}) -> Meta;
meta(_Job) -> #{}.

result(JobId, Result, Waited) ->
    case Waited =:= any orelse lists:member(JobId, Waited) of
        true -> plain(shigoto_crypto:open_term(Result, {result, JobId}));
        false -> throw({?MODULE, decrypt_failed})
    end.

%% A bigint has at most 19 digits and a sign. Longer text is not converted: a
%% number of millions of digits raises `system_limit`, with the text in the
%% stack frame.
job_id(Id) when is_binary(Id), byte_size(Id) =< 20 ->
    try
        binary_to_integer(Id)
    catch
        error:_ -> throw({?MODULE, decrypt_failed})
    end;
job_id(Id) when is_binary(Id) ->
    throw({?MODULE, decrypt_failed});
job_id(Id) ->
    Id.

plain({ok, Plain}) -> Plain;
plain({error, Reason}) -> throw({?MODULE, Reason}).

decoded(Json, Default) ->
    try
        json:decode(Json)
    catch
        _:_ -> Default
    end.

-doc """
A job as it is shown to someone reading it: `args`, `meta`, `result` and
`deps_results` decrypted, each still JSON text.

A column that does not open is replaced by the JSON string of the reason
(`"decrypt_failed"`, `"format_refused"`), never returned as ciphertext.
Plaintext is shown as it is stored, whatever `require_encrypted` says: that
setting is about what may run. Without a key the row is answered untouched.
""".
-spec readable(map()) -> map().
readable(Job) ->
    case shigoto_crypto:is_enabled() of
        false -> Job;
        true -> shown(Job)
    end.

shown(#{worker := Worker} = Job) when is_binary(Worker) ->
    Columns = [
        {args, {args, Worker}},
        {meta, {meta, Worker}}
        | [{result, {result, Id}} || #{id := Id} <- [Job], is_integer(Id)]
    ],
    shown_deps_results(shown(Columns, Job));
shown(Job) ->
    Job.

shown([], Job) ->
    Job;
shown([{Column, Context} | Columns], Job) ->
    case Job of
        #{Column := Stored} when is_binary(Stored) ->
            shown(Columns, Job#{Column => text(Stored, shigoto_crypto:open(Stored, Context))});
        #{} ->
            shown(Columns, Job)
    end.

text(_Stored, {ok, Plain}) -> Plain;
text(Stored, {error, plaintext_refused}) -> Stored;
text(_Stored, {error, Reason}) -> json_text(atom_to_binary(Reason)).

shown_deps_results(#{deps_results := Stored} = Job) when is_binary(Stored) ->
    case decoded(Stored, undefined) of
        Results when is_map(Results) ->
            Shown = #{Id => shown_result(Id, Result) || Id := Result <- Results},
            Job#{deps_results => json_text(Shown)};
        _NotAnObject ->
            Job
    end;
shown_deps_results(Job) ->
    Job.

shown_result(Id, Result) ->
    try shigoto_crypto:open_term(Result, {result, job_id(Id)}) of
        {ok, Plain} -> Plain;
        {error, plaintext_refused} -> Result;
        {error, Reason} -> atom_to_binary(Reason)
    catch
        throw:{?MODULE, Reason} -> atom_to_binary(Reason)
    end.

json_text(Term) ->
    iolist_to_binary(json:encode(Term)).

-doc """
A job map without the columns that carry job data (`args`, `meta`, `result`,
`deps_results`, `errors`, and a batch's `callback_args`). Use it wherever a job
goes into a log report, an error term or a process state shown by `sys`.
""".
-spec redact(map()) -> map().
redact(Job) when is_map(Job) ->
    maps:without(?DATA_COLUMNS, Job).
