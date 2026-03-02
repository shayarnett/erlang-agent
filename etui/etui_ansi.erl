-module(etui_ansi).
-export([
    new/0,
    process/2,
    process_string/2,
    active_codes/1
]).

-record(ansi_state, {
    bold = false,
    dim = false,
    italic = false,
    underline = false,
    inverse = false,
    strikethrough = false,
    fg = none,       % none | {standard, N} | {bright, N} | {c256, N} | {rgb, R, G, B}
    bg = none        % same
}).

new() -> #ansi_state{}.

%% Process a single SGR code string like "\e[1m" or "\e[38;2;255;0;0m"
process(Code, State) ->
    case parse_sgr(Code) of
        {ok, Params} -> apply_params(Params, State);
        error -> State
    end.

%% Process all SGR codes found in a string
process_string(Str, State) ->
    process_string_scan(Str, State).

process_string_scan([], State) -> State;
process_string_scan([$\e, $[ | Rest], State) ->
    case collect_sgr(Rest, []) of
        {Params, [$m | After]} ->
            State2 = apply_params(Params, State),
            process_string_scan(After, State2);
        {_, After} ->
            process_string_scan(After, State)
    end;
process_string_scan([_ | Rest], State) ->
    process_string_scan(Rest, State);
%% Handle binaries
process_string_scan(<<>>, State) -> State;
process_string_scan(Bin, State) when is_binary(Bin) ->
    process_string_scan(binary_to_list(Bin), State).

collect_sgr([$m | Rest], Acc) ->
    {lists:reverse(Acc), [$m | Rest]};
collect_sgr([$; | Rest], Acc) ->
    collect_sgr(Rest, Acc);
collect_sgr([C | Rest], Acc) when C >= $0, C =< $9 ->
    {Num, Rest2} = collect_number([C | Rest]),
    collect_sgr(Rest2, [Num | Acc]);
collect_sgr(Other, Acc) ->
    {lists:reverse(Acc), Other}.

collect_number(Str) -> collect_number(Str, 0).
collect_number([C | Rest], N) when C >= $0, C =< $9 ->
    collect_number(Rest, N * 10 + (C - $0));
collect_number(Rest, N) -> {N, Rest}.

parse_sgr([$\e, $[ | Rest]) ->
    case collect_sgr(Rest, []) of
        {Params, [$m | _]} -> {ok, Params};
        _ -> error
    end;
parse_sgr(_) -> error.

%% Apply a list of SGR parameters
apply_params([], State) -> State;
apply_params([0 | Rest], _State) ->
    apply_params(Rest, #ansi_state{});
apply_params([1 | Rest], State) ->
    apply_params(Rest, State#ansi_state{bold = true});
apply_params([2 | Rest], State) ->
    apply_params(Rest, State#ansi_state{dim = true});
apply_params([3 | Rest], State) ->
    apply_params(Rest, State#ansi_state{italic = true});
apply_params([4 | Rest], State) ->
    apply_params(Rest, State#ansi_state{underline = true});
apply_params([7 | Rest], State) ->
    apply_params(Rest, State#ansi_state{inverse = true});
apply_params([9 | Rest], State) ->
    apply_params(Rest, State#ansi_state{strikethrough = true});
apply_params([22 | Rest], State) ->
    apply_params(Rest, State#ansi_state{bold = false, dim = false});
apply_params([23 | Rest], State) ->
    apply_params(Rest, State#ansi_state{italic = false});
apply_params([24 | Rest], State) ->
    apply_params(Rest, State#ansi_state{underline = false});
apply_params([27 | Rest], State) ->
    apply_params(Rest, State#ansi_state{inverse = false});
apply_params([29 | Rest], State) ->
    apply_params(Rest, State#ansi_state{strikethrough = false});
%% Standard foreground 30-37
apply_params([N | Rest], State) when N >= 30, N =< 37 ->
    apply_params(Rest, State#ansi_state{fg = {standard, N - 30}});
%% Extended foreground
apply_params([38, 5, N | Rest], State) ->
    apply_params(Rest, State#ansi_state{fg = {c256, N}});
apply_params([38, 2, R, G, B | Rest], State) ->
    apply_params(Rest, State#ansi_state{fg = {rgb, R, G, B}});
apply_params([39 | Rest], State) ->
    apply_params(Rest, State#ansi_state{fg = none});
%% Standard background 40-47
apply_params([N | Rest], State) when N >= 40, N =< 47 ->
    apply_params(Rest, State#ansi_state{bg = {standard, N - 40}});
%% Extended background
apply_params([48, 5, N | Rest], State) ->
    apply_params(Rest, State#ansi_state{bg = {c256, N}});
apply_params([48, 2, R, G, B | Rest], State) ->
    apply_params(Rest, State#ansi_state{bg = {rgb, R, G, B}});
apply_params([49 | Rest], State) ->
    apply_params(Rest, State#ansi_state{bg = none});
%% Bright foreground 90-97
apply_params([N | Rest], State) when N >= 90, N =< 97 ->
    apply_params(Rest, State#ansi_state{fg = {bright, N - 90}});
%% Bright background 100-107
apply_params([N | Rest], State) when N >= 100, N =< 107 ->
    apply_params(Rest, State#ansi_state{bg = {bright, N - 100}});
%% Unknown param, skip
apply_params([_ | Rest], State) ->
    apply_params(Rest, State).

%% Reconstruct the minimal escape sequence to restore the current state
active_codes(#ansi_state{bold=false, dim=false, italic=false, underline=false,
                          inverse=false, strikethrough=false, fg=none, bg=none}) ->
    "";
active_codes(State) ->
    Codes = lists:flatten([
        case State#ansi_state.bold of true -> [1]; false -> [] end,
        case State#ansi_state.dim of true -> [2]; false -> [] end,
        case State#ansi_state.italic of true -> [3]; false -> [] end,
        case State#ansi_state.underline of true -> [4]; false -> [] end,
        case State#ansi_state.inverse of true -> [7]; false -> [] end,
        case State#ansi_state.strikethrough of true -> [9]; false -> [] end,
        fg_codes(State#ansi_state.fg),
        bg_codes(State#ansi_state.bg)
    ]),
    case Codes of
        [] -> "";
        _ ->
            Strs = [integer_to_list(C) || C <- Codes],
            ["\e[", lists:join($;, Strs), $m]
    end.

fg_codes(none) -> [];
fg_codes({standard, N}) -> [30 + N];
fg_codes({bright, N}) -> [90 + N];
fg_codes({c256, N}) -> [38, 5, N];
fg_codes({rgb, R, G, B}) -> [38, 2, R, G, B].

bg_codes(none) -> [];
bg_codes({standard, N}) -> [40 + N];
bg_codes({bright, N}) -> [100 + N];
bg_codes({c256, N}) -> [48, 5, N];
bg_codes({rgb, R, G, B}) -> [48, 2, R, G, B].
