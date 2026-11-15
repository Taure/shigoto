-module(shigoto_reencrypt).
-moduledoc false.

%% Rewrites stored job data in the form the current settings write
%% (`shigoto:reencrypt/0,1`).
%%
%% Run it after changing what is written: after setting
%% `encryption_write_format` to `v2`, after putting a new key first in
%% `encryption_keys`, or after configuring a key for a table that already holds
%% plaintext jobs. It walks `shigoto_jobs`, `shigoto_jobs_archive` and
%% `shigoto_batches` by id and, for every value that is not already in the
%% current form (`shigoto_crypto:reseal/2`), decrypts it and encrypts it again:
%% `args`, `meta`, `result`, each entry of `deps_results`, and a batch's
%% `callback_args`.
%%
%% It also moves the `unique_key` of every row in `shigoto_jobs` to the digest
%% under the current key (`shigoto_crypto:unique_rekey/2`): a key stored in the
%% clear before encryption was turned on, and one stored under an older key. A
%% unique insert looks for a job under every listed key, and in the clear while
%% `require_encrypted` is not set, so duplicates are found before, during and
%% after the run. Once it reports `failed => 0` and `skipped => 0` an old key can
%% be removed and `require_encrypted` set. A `unique_key` written under a key that
%% is no longer listed cannot be moved and is counted as `failed`. Archived jobs
%% are not looked up by a unique insert, and their keys are left as they are.
%%
%% It is safe while the queue runs. Rows are read in batches without a lock, and
%% each value is written back with a compare-and-swap (`UPDATE ... WHERE id = $1
%% AND column = <the value read>`), so a row that changed in the meantime is left
%% alone and counted as `skipped`; run it again to pick those up. A running job
%% is not affected by its row being rewritten. It can be stopped and started again
%% at any point, and running it twice changes nothing the second time.
%%
%% A v1 ciphertext is bound to nothing, so this is also the moment a v1 value
%% that was moved between rows gets bound to the row it was moved to. Run it soon
%% after the upgrade, then drop `v1` from `encryption_read_formats`.

-export([run/2]).

-export_type([counts/0]).

-type counts() :: shigoto:reencrypt_counts().

-define(TABLES, [
    {jobs, ~"shigoto_jobs",
        ~"id, worker, queue, unique_key, args, meta, result, deps_results, depends_on"},
    {archive, ~"shigoto_jobs_archive", ~"id, worker, args, meta, result, deps_results"},
    {batches, ~"shigoto_batches", ~"id, callback_worker, callback_args"}
]).

-doc """
Rewrite every table. `Opts` may set `batch_size` (rows read per statement,
default 500). Answers the counts per table, or the first database error.
""".
-spec run(atom(), map()) ->
    {ok, #{jobs := counts(), archive := counts(), batches := counts()}} | {error, term()}.
run(Pool, Opts) ->
    case shigoto_crypto:is_enabled() of
        false -> {error, no_encryption_key};
        true -> tables(Pool, maps:get(batch_size, Opts, 500), ?TABLES, #{})
    end.

tables(_Pool, _BatchSize, [], Done) ->
    {ok, Done};
tables(Pool, BatchSize, [{Name, Table, Columns} | Tables], Done) ->
    Zero = #{scanned => 0, rewritten => 0, skipped => 0, failed => 0},
    case table(Pool, BatchSize, Table, Columns, 0, Zero) of
        {ok, Counts} -> tables(Pool, BatchSize, Tables, Done#{Name => Counts});
        {error, _} = Failed -> Failed
    end.

table(Pool, BatchSize, Table, Columns, After, Counts) ->
    SQL = iolist_to_binary([
        ~"SELECT ", Columns, ~" FROM ", Table, ~" WHERE id > $1 ORDER BY id LIMIT $2"
    ]),
    case shigoto_db:query(Pool, SQL, [After, BatchSize]) of
        #{rows := []} ->
            {ok, Counts};
        #{rows := Rows} ->
            case rows(Pool, Table, Rows, Counts) of
                {ok, Counted} ->
                    #{id := Last} = lists:last(Rows),
                    table(Pool, BatchSize, Table, Columns, Last, Counted);
                {error, _} = Failed ->
                    Failed
            end;
        {error, Reason} ->
            {error, shigoto_db:reduced(Reason)}
    end.

rows(_Pool, _Table, [], Counts) ->
    {ok, Counts};
rows(Pool, Table, [#{id := Id} = Row | Rows], #{scanned := Scanned} = Counts) ->
    case values(Pool, Table, Id, changes(Row), Counts#{scanned := Scanned + 1}) of
        {ok, Counted} -> rows(Pool, Table, Rows, Counted);
        {error, _} = Failed -> Failed
    end.

values(_Pool, _Table, _Id, [], Counts) ->
    {ok, Counts};
values(Pool, Table, Id, [{_Column, _Stored, failed} | Changes], #{failed := Failed} = Counts) ->
    values(Pool, Table, Id, Changes, Counts#{failed := Failed + 1});
values(Pool, Table, Id, [{Column, Stored, Sealed} | Changes], Counts) ->
    Cast = cast(Column),
    SQL = iolist_to_binary([
        ~"UPDATE ",
        Table,
        ~" SET ",
        Column,
        ~" = $2",
        Cast,
        ~" WHERE id = $1 AND ",
        Column,
        ~" = $3",
        Cast
    ]),
    case shigoto_db:query(Pool, SQL, [Id, Sealed, Stored]) of
        #{num_rows := 1} ->
            values(Pool, Table, Id, Changes, counted(rewritten, Counts));
        #{num_rows := 0} ->
            values(Pool, Table, Id, Changes, counted(skipped, Counts));
        {error, Reason} ->
            {error, shigoto_db:reduced(Reason)}
    end.

cast(~"unique_key") -> ~"::text";
cast(_Column) -> ~"::jsonb".

counted(Key, Counts) ->
    Counts#{Key := maps:get(Key, Counts) + 1}.

%% The values of a row that are not in the current form, each with what to
%% write instead, or `failed` when it does not open.
-spec changes(map()) -> [{binary(), binary(), binary() | failed}].
changes(#{callback_args := Stored} = Batch) ->
    Worker =
        case Batch of
            #{callback_worker := Name} when is_binary(Name) -> Name;
            #{} -> <<>>
        end,
    change(~"callback_args", Stored, {callback_args, Worker});
changes(#{id := Id, worker := Worker} = Job) when is_binary(Worker) ->
    change(~"args", maps:get(args, Job, null), {args, Worker}) ++
        meta_change(Job, Worker) ++
        change(~"result", maps:get(result, Job, null), {result, Id}) ++
        deps_results_change(maps:get(deps_results, Job, null)) ++
        unique_key_change(Job);
changes(_Row) ->
    [].

change(Column, Stored, Context) when is_binary(Stored), Stored =/= ~"null" ->
    case shigoto_crypto:reseal(Stored, Context) of
        current -> [];
        {resealed, Sealed} -> [{Column, Stored, Sealed}];
        {error, _} -> [{Column, Stored, failed}]
    end;
change(_Column, _Null, _Context) ->
    [].

%% A job is handed the results of the jobs named in its meta
%% (`shigoto_job:opened/1`). One inserted by a release that wrote no such list,
%% or before a key was configured, gets it here, from what it waits for and
%% what it has been given so far: once `require_encrypted` is set a waiting job
%% without the list is handed nothing. Like plaintext that is encrypted here,
%% the row is taken as it is. Only shigoto_jobs is read with `depends_on`:
%% an archived job does not run.
meta_change(#{meta := Stored, depends_on := DependsOn} = Job, Worker) when
    is_binary(Stored), is_list(DependsOn)
->
    Waited = lists:usort(
        [Id || Id <- DependsOn, is_integer(Id)] ++ given(maps:get(deps_results, Job, null))
    ),
    case listed(Stored, Worker, Waited) of
        {ok, Listed} -> [{~"meta", Stored, shigoto_crypto:seal(Listed, {meta, Worker})}];
        unchanged -> change(~"meta", Stored, {meta, Worker})
    end;
meta_change(Job, Worker) ->
    change(~"meta", maps:get(meta, Job, null), {meta, Worker}).

-spec listed(binary(), binary(), [integer()]) -> {ok, binary()} | unchanged.
listed(_Stored, _Worker, []) ->
    unchanged;
listed(Stored, Worker, Waited) ->
    try json:decode(plain_meta(Stored, Worker)) of
        #{~"_shigoto_deps" := _Listed} ->
            unchanged;
        Meta when is_map(Meta) ->
            {ok, iolist_to_binary(json:encode(Meta#{~"_shigoto_deps" => Waited}))};
        _NotAnObject ->
            unchanged
    catch
        _:_ -> unchanged
    end.

%% Plaintext is taken as it is, as `shigoto_crypto:reseal/2` takes it. A frame
%% that does not open is left to `change/3`, which counts it as failed.
plain_meta(Stored, Worker) ->
    case shigoto_crypto:is_frame(Stored) of
        false ->
            Stored;
        true ->
            {ok, Plain} = shigoto_crypto:open(Stored, {meta, Worker}),
            Plain
    end.

-spec given(term()) -> [integer()].
given(Stored) when is_binary(Stored) ->
    try json:decode(Stored) of
        Results when is_map(Results) ->
            [binary_to_integer(Id) || Id := _Result <- Results, is_binary(Id), is_id(Id)];
        _NotAnObject ->
            []
    catch
        _:_ -> []
    end;
given(_Null) ->
    [].

is_id(Id) ->
    byte_size(Id) =< 20 andalso
        re:run(Id, ~"^[0-9]+$", [dollar_endonly, {capture, none}]) =:= match.

%% Only shigoto_jobs is read with its unique_key: a unique insert never looks
%% in the archive.
unique_key_change(#{unique_key := Stored, worker := Worker, queue := Queue} = Job) when
    is_binary(Stored), is_binary(Queue)
->
    Materials = shigoto_repo:unique_materials(Worker, args_json(Job), Queue),
    case shigoto_crypto:unique_rekey(Stored, Materials) of
        current -> [];
        {rekeyed, Digest} -> [{~"unique_key", Stored, Digest}];
        {error, unknown_key} -> [{~"unique_key", Stored, failed}]
    end;
unique_key_change(_Job) ->
    [].

%% The args as they were encoded at insert. Only a ciphertext keeps that text:
%% PostgreSQL normalises plaintext jsonb, and a job stored in the clear has
%% its unique key in the clear as well, which needs no args to move.
args_json(#{args := Stored, worker := Worker}) when is_binary(Stored) ->
    case shigoto_crypto:is_frame(Stored) of
        true ->
            case shigoto_crypto:open(Stored, {args, Worker}) of
                {ok, Plain} -> Plain;
                {error, _} -> undefined
            end;
        false ->
            undefined
    end;
args_json(_Job) ->
    undefined.

%% deps_results is an object of job id to that job's result, each entry
%% encrypted on its own for the job it came from.
deps_results_change(Stored) when is_binary(Stored) ->
    try json:decode(Stored) of
        Results when is_map(Results), map_size(Results) > 0 ->
            Entries = [entry(Id, Result) || Id := Result <- Results],
            case {lists:member(failed, Entries), [E || {_Id, {resealed, _}} = E <- Entries]} of
                {true, _} ->
                    [{~"deps_results", Stored, failed}];
                {false, []} ->
                    [];
                {false, _Resealed} ->
                    Sealed = #{Id => Value || {Id, {_How, Value}} <- Entries},
                    [{~"deps_results", Stored, iolist_to_binary(json:encode(Sealed))}]
            end;
        _Empty ->
            []
    catch
        _:_ -> []
    end;
deps_results_change(_Null) ->
    [].

entry(Id, null) ->
    {Id, {current, null}};
entry(Id, Result) ->
    try binary_to_integer(Id) of
        JobId ->
            case shigoto_crypto:reseal(iolist_to_binary(json:encode(Result)), {result, JobId}) of
                current -> {Id, {current, Result}};
                {resealed, Sealed} -> {Id, {resealed, json:decode(Sealed)}};
                {error, _} -> failed
            end
    catch
        error:badarg -> failed
    end.
