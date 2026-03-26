-module(shigoto_cron_parser).
-moduledoc """
Parses standard 5-field cron expressions and checks if a given datetime
matches. Fields: minute, hour, day-of-month, month, day-of-week.

Supported syntax per field:
- `*` — any value
- `N` — exact value
- `N-M` — inclusive range
- `*/N` — step from start
- `N-M/S` — step within range
- `N,M,O` — comma-separated list (each element may be a value, range, or step)

Aliases: `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`.
""".

-export([parse/1, matches/2]).

-type field() :: star | {step, pos_integer()} | {values, [non_neg_integer()]}.
-type cron_expr() :: #{
    minute := field(),
    hour := field(),
    dom := field(),
    month := field(),
    dow := field()
}.

-export_type([cron_expr/0, field/0]).

-doc "Parse a 5-field cron expression or alias into a structured map.".
-spec parse(binary()) -> {ok, cron_expr()} | {error, term()}.
parse(~"@yearly") ->
    parse(~"0 0 1 1 *");
parse(~"@annually") ->
    parse(~"0 0 1 1 *");
parse(~"@monthly") ->
    parse(~"0 0 1 * *");
parse(~"@weekly") ->
    parse(~"0 0 * * 0");
parse(~"@daily") ->
    parse(~"0 0 * * *");
parse(~"@midnight") ->
    parse(~"0 0 * * *");
parse(~"@hourly") ->
    parse(~"0 * * * *");
parse(Bin) when is_binary(Bin) ->
    Fields = binary:split(Bin, ~" ", [global, trim_all]),
    case Fields of
        [Min, Hour, Dom, Mon, Dow] ->
            try
                {ok, #{
                    minute => parse_field(Min, 0, 59),
                    hour => parse_field(Hour, 0, 23),
                    dom => parse_field(Dom, 1, 31),
                    month => parse_field(Mon, 1, 12),
                    dow => parse_field(Dow, 0, 6)
                }}
            catch
                throw:{parse_error, Reason} -> {error, Reason}
            end;
        _ ->
            {error, {bad_field_count, length(Fields)}}
    end.

-doc "Check if a `calendar:datetime()` matches a parsed cron expression.".
-spec matches(cron_expr(), calendar:datetime()) -> boolean().
matches(Expr, {{Year, Month, Day}, {Hour, Minute, _Second}}) ->
    Dow = day_of_week(Year, Month, Day),
    field_matches(maps:get(minute, Expr), Minute) andalso
        field_matches(maps:get(hour, Expr), Hour) andalso
        field_matches(maps:get(dom, Expr), Day) andalso
        field_matches(maps:get(month, Expr), Month) andalso
        field_matches(maps:get(dow, Expr), Dow).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec parse_field(binary(), non_neg_integer(), non_neg_integer()) -> field().
parse_field(~"*", _Min, _Max) ->
    star;
parse_field(<<"*/", Rest/binary>>, Min, Max) ->
    Step = to_int(Rest),
    validate_step(Step),
    expand_step(Min, Max, Step);
parse_field(Bin, Min, Max) ->
    Parts = binary:split(Bin, ~",", [global]),
    Values = lists:usort(
        lists:flatmap(fun(P) -> parse_part(eqwalizer:fix_me(P), Min, Max) end, Parts)
    ),
    {values, eqwalizer:fix_me(Values)}.

-spec parse_part(binary(), non_neg_integer(), non_neg_integer()) -> [non_neg_integer()].
parse_part(Bin, Min, Max) ->
    case binary:split(Bin, ~"/") of
        [Range, StepBin] ->
            Step = to_int(StepBin),
            validate_step(Step),
            {Lo, Hi} = parse_range(Range, Min, Max),
            expand_step_range(Lo, Hi, Step);
        [_] ->
            case binary:split(Bin, ~"-") of
                [LoBin, HiBin] ->
                    Lo = clamp(to_int(LoBin), Min, Max),
                    Hi = clamp(to_int(HiBin), Min, Max),
                    lists:seq(Lo, Hi);
                [ValBin] ->
                    [clamp(to_int(ValBin), Min, Max)]
            end
    end.

-spec parse_range(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
parse_range(~"*", Min, Max) ->
    {Min, Max};
parse_range(Bin, Min, Max) ->
    case binary:split(Bin, ~"-") of
        [LoBin, HiBin] ->
            {clamp(to_int(LoBin), Min, Max), clamp(to_int(HiBin), Min, Max)};
        [ValBin] ->
            V = clamp(to_int(ValBin), Min, Max),
            {V, V}
    end.

-spec expand_step(non_neg_integer(), non_neg_integer(), pos_integer()) -> field().
expand_step(Min, Max, Step) ->
    {values, expand_step_range(Min, Max, Step)}.

-spec expand_step_range(non_neg_integer(), non_neg_integer(), pos_integer()) ->
    [non_neg_integer()].
expand_step_range(Lo, Hi, Step) ->
    lists:seq(Lo, Hi, Step).

-spec field_matches(field(), non_neg_integer()) -> boolean().
field_matches(star, _Value) ->
    true;
field_matches({values, Values}, Value) ->
    lists:member(Value, Values).

-spec to_int(binary()) -> integer().
to_int(Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> throw({parse_error, {bad_integer, Bin}})
    end.

-spec clamp(integer(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
clamp(V, Min, _Max) when V < Min -> Min;
clamp(V, _Min, Max) when V > Max -> Max;
clamp(V, _Min, _Max) -> V.

-spec validate_step(integer()) -> ok.
validate_step(Step) when Step < 1 ->
    throw({parse_error, {bad_step, Step}});
validate_step(_Step) ->
    ok.

%% Returns 0=Sunday, 1=Monday, ..., 6=Saturday
-spec day_of_week(integer(), 1..12, 1..31) -> 0..6.
day_of_week(Year, Month, Day) ->
    calendar:day_of_the_week(Year, Month, Day) rem 7.
