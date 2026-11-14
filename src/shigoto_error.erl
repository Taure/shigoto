-module(shigoto_error).
-moduledoc """
How a job's failure is written down: the entry added to its `errors` column,
and the `reason` in logs and telemetry.

`errors` is never encrypted, and logs and telemetry leave the node, so nothing
written here may carry job args.

- A stack frame keeps its module, function, arity, file and line. The argument
  list of a `function_clause` or `undef` frame, which for `perform/1` is the
  args map, becomes its length, and `error_info` is dropped.
- With an encryption key configured the reason is cut down to its shape
  (`shape/1`): atoms stay, every other value becomes `'_'`, and the errors that
  embed the value they failed on (`{badmatch, V}`, `{case_clause, V}`,
  `{badkey, K}`, ...) keep their tag only. That goes for what `perform/1`
  returns in `{error, Reason}` too.
- Without a key the reason is written as it is. The args are in the clear in
  the same row then.
- Either way the reason is cut at 1024 bytes, the stack at 16 frames and 4096
  bytes, and a job keeps its 50 newest entries.
""".

-export([entry/2, text/1, shape/1, stack/1, appended/2]).

-define(MAX_REASON_BYTES, 1024).
-define(MAX_STACK_BYTES, 4096).
-define(MAX_FRAMES, 16).
-define(MAX_ENTRIES, 50).
-define(MAX_DEPTH, 4).
-define(MAX_ELEMENTS, 8).
-define(IS_CLASS(Class), (Class =:= error orelse Class =:= exit orelse Class =:= throw)).
-define(VALUE_ERRORS, [
    badmatch,
    case_clause,
    try_clause,
    else_clause,
    badkey,
    badmap,
    badfun,
    badarity,
    badrecord,
    badarg,
    nocatch,
    bad_generator,
    bad_filter,
    badrpc
]).

-doc """
The entry added to a job's `errors` for `Reason`: `error`, `at`, `attempt`,
`worker`, and `stacktrace` when `Reason` is `{Class, Reason, Stacktrace}`.

`{Class, Reason}` and `{Class, Reason, Stacktrace}` with `Class` one of
`error`, `exit` and `throw` are written as `Class:Reason`, the way an exception
prints. Any other reason is written as the term it is.
""".
-spec entry(map(), term()) -> #{binary() => binary() | integer()}.
entry(Job, Reason) ->
    {Error, Stack} = described(Reason),
    Entry = #{
        ~"error" => Error,
        ~"at" => timestamp(),
        ~"attempt" => maps:get(attempt, Job, 0),
        ~"worker" => worker_name(maps:get(worker, Job, undefined))
    },
    case Stack of
        <<>> -> Entry;
        _ -> Entry#{~"stacktrace" => Stack}
    end.

-doc "A failure reason as text for a log report or telemetry metadata.".
-spec text(term()) -> binary().
text(Reason) ->
    {Error, _Stack} = described(Reason),
    Error.

%% Only what a catch produced is a class and a reason. `{error, Reason}` from
%% perform/1 may carry any tuple, and `{rejected, quota}` is not an exception.
described({Class, Reason, Stack}) when ?IS_CLASS(Class), is_list(Stack) ->
    {
        printed("~0tp:~0tp", [safe(Class), safe(Reason)], ?MAX_REASON_BYTES),
        printed("~0tp", [stack(Stack)], ?MAX_STACK_BYTES)
    };
described({Class, Reason}) when ?IS_CLASS(Class) ->
    {printed("~0tp:~0tp", [safe(Class), safe(Reason)], ?MAX_REASON_BYTES), <<>>};
described(Reason) ->
    {printed("~0tp", [safe(Reason)], ?MAX_REASON_BYTES), <<>>}.

safe(Term) ->
    case shigoto_crypto:is_enabled() of
        true -> shape(Term);
        false -> Term
    end.

-doc """
A term with every value that is not an atom replaced by `'_'`. Tuples keep
their structure, to a depth of 4 and 8 elements; an error that embeds the value
it failed on keeps only its tag.
""".
-spec shape(term()) -> term().
shape(Term) ->
    shape(Term, ?MAX_DEPTH).

shape(Atom, _Depth) when is_atom(Atom) ->
    Atom;
shape(_Term, 0) ->
    '_';
shape({Tag, Value}, Depth) when is_atom(Tag) ->
    case lists:member(Tag, ?VALUE_ERRORS) of
        true -> Tag;
        false -> {Tag, shape(Value, Depth - 1)}
    end;
shape(Tuple, Depth) when is_tuple(Tuple) ->
    list_to_tuple([
        shape(Element, Depth - 1)
     || Element <- lists:sublist(tuple_to_list(Tuple), ?MAX_ELEMENTS)
    ]);
shape(_Other, _Depth) ->
    '_'.

-doc """
A stacktrace that is safe to store: at most 16 frames, each with its arity in
place of an argument list and only `file` and `line` of its location.
""".
-spec stack(list()) -> [{module(), atom(), arity(), [{file | line, term()}]} | '_'].
stack(Stack) when is_list(Stack) ->
    [frame(Frame) || Frame <- lists:sublist(Stack, ?MAX_FRAMES)].

frame({Module, Function, Args, Location}) when is_list(Args) ->
    frame({Module, Function, length(Args), Location});
frame({Module, Function, Arity, Location}) when
    is_atom(Module), is_atom(Function), is_integer(Arity), is_list(Location)
->
    {Module, Function, Arity, [
        {Key, Value}
     || {Key, Value} <- Location, Key =:= file orelse Key =:= line
    ]};
frame(_Frame) ->
    '_'.

-doc """
The SQL expression that adds `Entry` (an SQL expression of type `jsonb`) to the
`errors` column `Column`, dropping the oldest entry once there are 50.
""".
-spec appended(binary(), binary()) -> binary().
appended(Column, Entry) ->
    iolist_to_binary([
        ~"CASE WHEN jsonb_typeof(",
        Column,
        ~") = 'array' AND jsonb_array_length(",
        Column,
        ~") >= ",
        integer_to_binary(?MAX_ENTRIES),
        ~" THEN (",
        Column,
        ~" - 0) || ",
        Entry,
        ~" ELSE ",
        Column,
        ~" || ",
        Entry,
        ~" END"
    ]).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec printed(string(), [term()], pos_integer()) -> binary().
printed(Format, Terms, Max) ->
    case unicode:characters_to_binary(io_lib:format(Format, Terms, [{chars_limit, Max}])) of
        Text when is_binary(Text) -> cut(Text, Max);
        _Invalid -> ~"unprintable"
    end.

%% `chars_limit` is a soft limit. This one is not, and never ends inside a
%% character.
cut(Text, Max) when byte_size(Text) =< Max ->
    Text;
cut(Text, Max) ->
    case unicode:characters_to_binary(binary:part(Text, 0, Max)) of
        Whole when is_binary(Whole) -> Whole;
        {incomplete, Whole, _Rest} -> Whole;
        {error, Whole, _Rest} -> Whole
    end.

worker_name(Worker) when is_atom(Worker) -> atom_to_binary(Worker);
worker_name(Worker) when is_binary(Worker) -> Worker;
worker_name(_Worker) -> ~"unknown".

timestamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])
    ).
