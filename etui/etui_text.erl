-module(etui_text).
-export([
    visible_width/1,
    wrap/2,
    truncate/2,
    pad/2,
    strip_ansi/1
]).

%% Calculate the visible (column) width of a string, ignoring ANSI escapes.
%% Fast path: pure ASCII printable → byte length.
visible_width(Str) when is_binary(Str) ->
    visible_width(binary_to_list(Str));
visible_width([]) -> 0;
visible_width(Str) ->
    case is_ascii(Str) of
        true -> length(Str);
        false -> visible_width_scan(Str, 0)
    end.

is_ascii([]) -> true;
is_ascii([C | Rest]) when C >= 16#20, C =< 16#7E -> is_ascii(Rest);
is_ascii(_) -> false.

visible_width_scan([], W) -> W;
%% Skip ANSI CSI sequences: ESC [ ... final_byte
visible_width_scan([$\e, $[ | Rest], W) ->
    visible_width_scan(skip_csi(Rest), W);
%% Skip ANSI OSC sequences: ESC ] ... BEL/ST
visible_width_scan([$\e, $] | Rest], W) ->
    visible_width_scan(skip_osc(Rest), W);
%% Skip ANSI APC sequences: ESC _ ... BEL/ST
visible_width_scan([$\e, $_ | Rest], W) ->
    visible_width_scan(skip_osc(Rest), W);
%% Skip other ESC sequences (2-byte)
visible_width_scan([$\e, _ | Rest], W) ->
    visible_width_scan(Rest, W);
%% CJK fullwidth characters (approximate ranges)
visible_width_scan([C | Rest], W) when
    (C >= 16#1100 andalso C =< 16#115F);    % Hangul Jamo
    (C >= 16#2E80 andalso C =< 16#9FFF);    % CJK
    (C >= 16#AC00 andalso C =< 16#D7AF);    % Hangul Syllables
    (C >= 16#F900 andalso C =< 16#FAFF);    % CJK Compatibility
    (C >= 16#FE10 andalso C =< 16#FE6F);    % CJK forms
    (C >= 16#FF01 andalso C =< 16#FF60);    % Fullwidth Forms
    (C >= 16#FFE0 andalso C =< 16#FFE6);    % Fullwidth Signs
    (C >= 16#20000 andalso C =< 16#2FA1F);  % CJK Ext B-F
    (C >= 16#30000 andalso C =< 16#3134F)   % CJK Ext G
    ->
    visible_width_scan(Rest, W + 2);
%% Regular printable character
visible_width_scan([C | Rest], W) when C >= 16#20 ->
    visible_width_scan(Rest, W + 1);
%% Control chars (width 0)
visible_width_scan([_ | Rest], W) ->
    visible_width_scan(Rest, W).

skip_csi([]) -> [];
skip_csi([C | Rest]) when C >= 16#40, C =< 16#7E -> Rest; % final byte
skip_csi([_ | Rest]) -> skip_csi(Rest).

skip_osc([]) -> [];
skip_osc([7 | Rest]) -> Rest;             % BEL
skip_osc([$\e, $\\ | Rest]) -> Rest;      % ST
skip_osc([_ | Rest]) -> skip_osc(Rest).

%% Strip all ANSI escape sequences from a string
strip_ansi(Str) when is_binary(Str) ->
    list_to_binary(strip_ansi(binary_to_list(Str)));
strip_ansi([]) -> [];
strip_ansi([$\e, $[ | Rest]) ->
    strip_ansi(skip_csi(Rest));
strip_ansi([$\e, $] | Rest]) ->
    strip_ansi(skip_osc(Rest));
strip_ansi([$\e, $_ | Rest]) ->
    strip_ansi(skip_osc(Rest));
strip_ansi([$\e, _ | Rest]) ->
    strip_ansi(Rest);
strip_ansi([C | Rest]) ->
    [C | strip_ansi(Rest)].

%% Word-wrap text to Width columns, preserving ANSI codes across line breaks.
wrap(Text, Width) when is_binary(Text) ->
    wrap(binary_to_list(Text), Width);
wrap(Text, Width) ->
    InputLines = string:split(Text, "\n", all),
    Tracker = etui_ansi:new(),
    {Result, _} = lists:foldl(fun(Line, {Acc, Tr}) ->
        {Wrapped, Tr2} = wrap_line(Line, Width, Tr),
        {Acc ++ Wrapped, Tr2}
    end, {[], Tracker}, InputLines),
    Result.

wrap_line([], _Width, Tracker) ->
    {[""], Tracker};
wrap_line(Line, Width, Tracker) ->
    Words = split_words(Line),
    {Lines, CurLine, _CurWidth, Tr2} = lists:foldl(
        fun({Word, WType}, {Ls, Cur, CW, Tr}) ->
            Tr1 = etui_ansi:process_string(Word, Tr),
            WW = visible_width(Word),
            case WType of
                space ->
                    if CW + WW =< Width ->
                        {Ls, Cur ++ Word, CW + WW, Tr1};
                    true ->
                        %% Don't add trailing spaces to wrapped lines
                        {Ls, Cur, CW, Tr1}
                    end;
                word ->
                    if CW == 0 ->
                        %% First word on line
                        if WW =< Width ->
                            {Ls, Cur ++ Word, WW, Tr1};
                        true ->
                            %% Break long word
                            {Ls2, LastPart, LastW} = break_long_word(
                                Word, Width - CW, Width, Ls, Cur, Tr),
                            {Ls2, LastPart, LastW, Tr1}
                        end;
                    CW + WW =< Width ->
                        {Ls, Cur ++ Word, CW + WW, Tr1};
                    WW =< Width ->
                        %% Wrap to next line
                        Prefix = etui_ansi:active_codes(Tr),
                        {Ls ++ [lists:flatten(Cur)],
                         lists:flatten(Prefix) ++ Word, WW, Tr1};
                    true ->
                        %% Word wider than Width, break it
                        Prefix = etui_ansi:active_codes(Tr),
                        {Ls2, LastPart, LastW} = break_long_word(
                            Word, Width - CW, Width,
                            Ls ++ [lists:flatten(Cur)],
                            lists:flatten(Prefix), Tr),
                        {Ls2, LastPart, LastW, Tr1}
                    end
            end
        end, {[], lists:flatten(etui_ansi:active_codes(Tracker)), 0, Tracker}, Words),
    {Lines ++ [lists:flatten(CurLine)], Tr2}.

%% Split a line into alternating word/space tokens
split_words([]) -> [];
split_words(Str) ->
    split_words(Str, [], []).

split_words([], [], Acc) -> lists:reverse(Acc);
split_words([], Cur, Acc) -> lists:reverse([{lists:reverse(Cur), word} | Acc]);
split_words([$\e | _] = Str, Cur, Acc) ->
    %% ANSI sequences are part of the current token
    {Esc, Rest} = extract_ansi(Str),
    split_words(Rest, lists:reverse(Esc) ++ Cur, Acc);
split_words([C | Rest], Cur, Acc) when C == $\s; C == $\t ->
    Acc2 = case Cur of
        [] -> Acc;
        _ -> [{lists:reverse(Cur), word} | Acc]
    end,
    {Spaces, Rest2} = collect_spaces([C | Rest]),
    split_words(Rest2, [], [{Spaces, space} | Acc2]);
split_words([C | Rest], Cur, Acc) ->
    split_words(Rest, [C | Cur], Acc).

collect_spaces(Str) -> collect_spaces(Str, []).
collect_spaces([C | Rest], Acc) when C == $\s; C == $\t ->
    collect_spaces(Rest, [C | Acc]);
collect_spaces(Rest, Acc) -> {lists:reverse(Acc), Rest}.

extract_ansi([$\e, $[ | Rest]) ->
    {Seq, Rest2} = extract_csi(Rest, [$[, $\e]),
    {lists:reverse(Seq), Rest2};
extract_ansi([$\e, $] | Rest]) ->
    {Seq, Rest2} = extract_osc(Rest, [$], $\e]),
    {lists:reverse(Seq), Rest2};
extract_ansi([$\e, C | Rest]) ->
    {[$\e, C], Rest};
extract_ansi(Str) ->
    {[], Str}.

extract_csi([C | Rest], Acc) when C >= 16#40, C =< 16#7E ->
    {[C | Acc], Rest};
extract_csi([C | Rest], Acc) ->
    extract_csi(Rest, [C | Acc]);
extract_csi([], Acc) ->
    {Acc, []}.

extract_osc([7 | Rest], Acc) -> {[7 | Acc], Rest};
extract_osc([$\e, $\\ | Rest], Acc) -> {[$\\, $\e | Acc], Rest};
extract_osc([C | Rest], Acc) -> extract_osc(Rest, [C | Acc]);
extract_osc([], Acc) -> {Acc, []}.

%% Break a word that's wider than available width into multiple lines.
break_long_word(Word, _FirstAvail, Width, Lines, CurLine, _Tracker) ->
    %% Simple char-by-char break (ignoring ANSI for simplicity)
    Chars = strip_ansi(Word),
    break_chars(Chars, Width, Lines, CurLine, 0).

break_chars([], _Width, Lines, Cur, CurW) ->
    {Lines, Cur, CurW};
break_chars([C | Rest], Width, Lines, Cur, CurW) ->
    CW = char_width(C),
    if CurW + CW > Width, CurW > 0 ->
        break_chars([C | Rest], Width, Lines ++ [lists:flatten(Cur)], "", 0);
    true ->
        break_chars(Rest, Width, Lines, Cur ++ [C], CurW + CW)
    end.

char_width(C) when
    (C >= 16#1100 andalso C =< 16#115F);
    (C >= 16#2E80 andalso C =< 16#9FFF);
    (C >= 16#AC00 andalso C =< 16#D7AF);
    (C >= 16#F900 andalso C =< 16#FAFF);
    (C >= 16#FE10 andalso C =< 16#FE6F);
    (C >= 16#FF01 andalso C =< 16#FF60);
    (C >= 16#FFE0 andalso C =< 16#FFE6);
    (C >= 16#20000 andalso C =< 16#2FA1F);
    (C >= 16#30000 andalso C =< 16#3134F)
    -> 2;
char_width(_) -> 1.

%% Truncate text to MaxWidth visible columns, appending "…" if truncated.
truncate(Text, MaxWidth) when is_binary(Text) ->
    truncate(binary_to_list(Text), MaxWidth);
truncate(Text, MaxWidth) ->
    W = visible_width(Text),
    if W =< MaxWidth -> Text;
    true ->
        truncate_scan(Text, MaxWidth - 1, 0, []) ++ "…"
    end.

truncate_scan(_, Max, W, Acc) when W >= Max -> lists:reverse(Acc);
truncate_scan([], _, _, Acc) -> lists:reverse(Acc);
truncate_scan([$\e | _] = Str, Max, W, Acc) ->
    {Esc, Rest} = extract_ansi(Str),
    truncate_scan(Rest, Max, W, lists:reverse(Esc) ++ Acc);
truncate_scan([C | Rest], Max, W, Acc) ->
    CW = char_width(C),
    if W + CW > Max -> lists:reverse(Acc);
    true -> truncate_scan(Rest, Max, W + CW, [C | Acc])
    end.

%% Pad text with spaces to reach Width visible columns.
pad(Text, Width) when is_binary(Text) ->
    pad(binary_to_list(Text), Width);
pad(Text, Width) ->
    W = visible_width(Text),
    if W >= Width -> Text;
    true -> Text ++ lists:duplicate(Width - W, $\s)
    end.
