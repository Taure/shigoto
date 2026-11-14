-module(shigoto_propagator).
-moduledoc """
Carries a context, such as a trace, from the process that inserts a job to the
processes that run it.

shigoto knows nothing about tracing. An application names a module that
implements this behaviour:

```erlang
{shigoto, [{propagator, my_app_job_context}]}.
```

```erlang
-module(my_app_job_context).
-behaviour(shigoto_propagator).
-export([inject/0, attach/1, detach/1]).

inject() ->
    maps:from_list(otel_propagator_text_map:inject([])).

attach(Carrier) ->
    otel_ctx:attach(otel_propagator_text_map:extract_to(otel_ctx:new(), maps:to_list(Carrier))).

detach(Token) ->
    otel_ctx:detach(Token).
```

## What shigoto does with it

- **Insert.** `inject/0` is called in the process that calls `shigoto:insert/1,2`
  or `shigoto:insert_all/1,2` (inside `shigoto:transaction/1` or not; once per
  call, so every job of one `insert_all` shares a carrier). What it answers,
  the carrier, is stored in the job's `meta` under the one key
  `<<"_shigoto_carrier">>`. A job whose `meta` already has that key keeps it.
  Every `meta` key that starts with `_shigoto` is reserved for shigoto.
  The carrier is encrypted with the rest of `meta` when a key is configured.
- **Run.** Before each attempt `attach/1` is called with the carrier, in the
  executor process (middleware, `backoff/2`, `on_discard/2`) and in the process
  that runs `perform/1`. `detach/1` is called with what `attach/1` answered
  when the attempt is over. Every attempt of a job gets the same carrier.
- **Jobs made by jobs.** A job inserted from `perform/1` is inserted in an
  attached process, so it carries on from the job that inserted it. A batch
  callback is inserted by the job that finished the batch and carries on from
  that one. A cron job is inserted by the scheduler, where nothing is attached:
  what `inject/0` answers there is up to the module. A job that waited on
  another keeps the carrier of its own insert.
- **Telemetry.** `[shigoto, job, start]`, `[shigoto, job, stop]` and
  `[shigoto, job, exception]` have the carrier in their metadata as `carrier`
  (`#{}` when the job has none).

## Bounds

A carrier is a map of binaries to binaries, at most 32 entries and 4096 bytes
of keys and values together. Anything else is dropped whole and
`shigoto_carrier_dropped` is logged: a job is inserted and run without a
carrier rather than refused. The same goes for a callback that raises
(`shigoto_propagator_failed`). A propagator can never fail an insert or a job.

Do not put secrets in a carrier. It is the one part of `meta` that telemetry
metadata carries.
""".

-include_lib("kernel/include/logger.hrl").

-export([key/0, injected/0, stamped/2, carrier/1, attached/1, detached/1, current/0, check/1]).
-export_type([carrier/0]).

-type carrier() :: #{binary() => binary()}.
-type attachment() :: none | {attached, module(), term()}.

-doc "The context of the calling process, in a form that can be stored.".
-callback inject() -> carrier().
-doc "Make the carrier's context the context of the calling process. The answer is handed to `detach/1`.".
-callback attach(carrier()) -> term().
-doc "Undo `attach/1`.".
-callback detach(term()) -> term().

-define(KEY, ~"_shigoto_carrier").
-define(MAX_ENTRIES, 32).
-define(MAX_BYTES, 4096).
-define(CURRENT, {?MODULE, carrier}).

-doc "The `meta` key a job's carrier is stored under.".
-spec key() -> binary().
key() -> ?KEY.

-doc false.
%% The carrier of the calling process: `#{}` without a propagator, or when it has nothing to say.
-spec injected() -> carrier().
injected() ->
    case shigoto_config:propagator() of
        undefined ->
            #{};
        Module ->
            try Module:inject() of
                Carrier -> bounded(Carrier, inject)
            catch
                Class:Reason -> failed(Module, inject, Class, Reason)
            end
    end.

-doc false.
%% Job params with the carrier in their `meta`, unless they bring their own or there is none.
-spec stamped(map(), carrier()) -> map().
stamped(JobParams, Carrier) when map_size(Carrier) =:= 0 ->
    JobParams;
stamped(JobParams, Carrier) ->
    case maps:get(meta, JobParams, #{}) of
        #{?KEY := _Own} -> JobParams;
        Meta when is_map(Meta) -> JobParams#{meta => Meta#{?KEY => Carrier}};
        _NotAMap -> JobParams
    end.

-doc false.
%% The carrier of a job whose `meta` has been opened: `#{}` when it has none, or
%% when what is stored is not a carrier.
-spec carrier(map()) -> carrier().
carrier(#{meta := Meta}) when is_binary(Meta) ->
    try json:decode(Meta) of
        Decoded -> stored(Decoded)
    catch
        error:_ -> #{}
    end;
carrier(#{meta := Meta}) ->
    stored(Meta);
carrier(_Job) ->
    #{}.

-doc false.
%% Attach the carrier to the calling process. Nothing is attached, and `none` is
%% the answer, without a propagator or a carrier, or when `attach/1` raises.
-spec attached(carrier()) -> attachment().
attached(Carrier) when map_size(Carrier) =:= 0 ->
    none;
attached(Carrier) ->
    case shigoto_config:propagator() of
        undefined ->
            none;
        Module ->
            try Module:attach(Carrier) of
                Token ->
                    _ = put(?CURRENT, Carrier),
                    {attached, Module, Token}
            catch
                Class:Reason ->
                    _ = failed(Module, attach, Class, Reason),
                    none
            end
    end.

-doc false.
%% Undo `attached/1`.
-spec detached(attachment()) -> ok.
detached(none) ->
    ok;
detached({attached, Module, Token}) ->
    _ = erase(?CURRENT),
    try Module:detach(Token) of
        _ -> ok
    catch
        Class:Reason ->
            _ = failed(Module, detach, Class, Reason),
            ok
    end.

-doc false.
%% The carrier `attached/1` attached to the calling process, for a process it starts.
-spec current() -> carrier().
current() ->
    case get(?CURRENT) of
        Carrier when is_map(Carrier) -> valid(Carrier);
        _None -> #{}
    end.

-doc false.
%% Whether a `propagator` setting names a module that implements the behaviour.
-spec check(term()) -> ok | {error, {invalid, propagator, term()}}.
check(undefined) ->
    ok;
check(Module) when is_atom(Module) ->
    _ = code:ensure_loaded(Module),
    Callbacks = [{inject, 0}, {attach, 1}, {detach, 1}],
    case
        [
            Callback
         || {Name, Arity} = Callback <- Callbacks, not erlang:function_exported(Module, Name, Arity)
        ]
    of
        [] -> ok;
        _Missing -> {error, {invalid, propagator, Module}}
    end;
check(Other) ->
    {error, {invalid, propagator, Other}}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

stored(#{?KEY := Carrier}) -> valid(Carrier);
stored(_Meta) -> #{}.

-spec valid(term()) -> carrier().
valid(Carrier) when is_map(Carrier) ->
    case problem(Carrier) of
        none -> #{Key => Value || Key := Value <- Carrier, is_binary(Key), is_binary(Value)};
        _Problem -> #{}
    end;
valid(_NotAMap) ->
    #{}.

-spec bounded(term(), atom()) -> carrier().
bounded(Carrier, Callback) ->
    case problem(Carrier) of
        none ->
            valid(Carrier);
        Problem ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_carrier_dropped",
                callback => Callback,
                problem => Problem,
                note => ~"the job goes on without a carrier"
            }),
            #{}
    end.

-spec problem(term()) -> none | not_a_carrier | too_many_entries | too_large.
problem(Carrier) when is_map(Carrier), map_size(Carrier) > ?MAX_ENTRIES ->
    too_many_entries;
problem(Carrier) when is_map(Carrier) ->
    Sizes = [
        case is_binary(Key) andalso is_binary(Value) of
            true -> byte_size(Key) + byte_size(Value);
            false -> not_binaries
        end
     || Key := Value <- Carrier
    ],
    case lists:member(not_binaries, Sizes) of
        true -> not_a_carrier;
        false -> within(lists:sum([Size || Size <- Sizes, is_integer(Size)]))
    end;
problem(_NotAMap) ->
    not_a_carrier.

within(Bytes) when Bytes > ?MAX_BYTES -> too_large;
within(_Bytes) -> none.

-spec failed(module(), atom(), atom(), term()) -> carrier().
failed(Module, Callback, Class, Reason) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_propagator_failed",
        propagator => Module,
        callback => Callback,
        reason => shigoto_error:shape({Class, Reason}),
        note => ~"the job goes on without a carrier"
    }),
    #{}.
