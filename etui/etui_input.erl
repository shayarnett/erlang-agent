-module(etui_input).
-export([
    new/0,
    new/1,
    handle_key/2,
    render/2,
    get_value/1,
    set_value/2
]).

-record(input_state, {
    value = "" :: string(),
    cursor = 0 :: non_neg_integer(),  % character index in value
    prompt = "> " :: string(),
    focused = true :: boolean()
}).

new() -> #input_state{}.
new(Prompt) -> #input_state{prompt = Prompt}.

get_value(#input_state{value = V}) -> V.

set_value(State, Value) ->
    State#input_state{value = Value, cursor = string:length(Value)}.

%% Handle a parsed key event. Returns:
%%   {updated, State} — input was modified
%%   {submit, Value}  — user pressed Enter
%%   {escape, State}  — user pressed Escape
%%   {ignore, State}  — key not handled
handle_key({key, enter}, #input_state{value = V}) ->
    {submit, V};
handle_key({key, escape}, State) ->
    {escape, State};

%% Cursor movement
handle_key({key, left}, #input_state{cursor = C} = S) when C > 0 ->
    {updated, S#input_state{cursor = C - 1}};
handle_key({key, right}, #input_state{cursor = C, value = V} = S) ->
    Len = string:length(V),
    if C < Len -> {updated, S#input_state{cursor = C + 1}};
       true -> {ignore, S}
    end;
handle_key({key, home}, S) ->
    {updated, S#input_state{cursor = 0}};
handle_key({key, a, [ctrl]}, S) ->
    {updated, S#input_state{cursor = 0}};
handle_key({key, 'end'}, #input_state{value = V} = S) ->
    {updated, S#input_state{cursor = string:length(V)}};
handle_key({key, e, [ctrl]}, #input_state{value = V} = S) ->
    {updated, S#input_state{cursor = string:length(V)}};

%% Word movement
handle_key({key, left, [ctrl]}, S) ->
    {updated, word_left(S)};
handle_key({key, left, [alt]}, S) ->
    {updated, word_left(S)};
handle_key({key, b, [alt]}, S) ->
    {updated, word_left(S)};
handle_key({key, right, [ctrl]}, S) ->
    {updated, word_right(S)};
handle_key({key, right, [alt]}, S) ->
    {updated, word_right(S)};
handle_key({key, f, [alt]}, S) ->
    {updated, word_right(S)};

%% Backspace
handle_key({key, backspace}, #input_state{cursor = 0} = S) ->
    {ignore, S};
handle_key({key, backspace}, #input_state{value = V, cursor = C} = S) ->
    Before = string:slice(V, 0, C - 1),
    After = string:slice(V, C),
    {updated, S#input_state{value = unicode:characters_to_list([Before, After]),
                            cursor = C - 1}};

%% Delete
handle_key({key, delete}, #input_state{value = V, cursor = C} = S) ->
    Len = string:length(V),
    if C >= Len -> {ignore, S};
       true ->
           Before = string:slice(V, 0, C),
           After = string:slice(V, C + 1),
           {updated, S#input_state{value = unicode:characters_to_list([Before, After])}}
    end;
handle_key({key, d, [ctrl]}, S) ->
    handle_key({key, delete}, S);

%% Kill to end of line (Ctrl+K)
handle_key({key, k, [ctrl]}, #input_state{value = V, cursor = C} = S) ->
    Before = string:slice(V, 0, C),
    {updated, S#input_state{value = unicode:characters_to_list(Before)}};

%% Kill to start of line (Ctrl+U)
handle_key({key, u, [ctrl]}, #input_state{value = V, cursor = C} = S) ->
    After = string:slice(V, C),
    {updated, S#input_state{value = unicode:characters_to_list(After), cursor = 0}};

%% Delete word backward (Ctrl+W / Alt+Backspace)
handle_key({key, w, [ctrl]}, S) ->
    {updated, delete_word_backward(S)};
handle_key({key, backspace, [alt]}, S) ->
    {updated, delete_word_backward(S)};

%% Character input
handle_key({char, Ch}, #input_state{value = V, cursor = C} = S) ->
    Before = string:slice(V, 0, C),
    After = string:slice(V, C),
    ChStr = if is_binary(Ch) -> unicode:characters_to_list(Ch);
               true -> Ch
            end,
    ChLen = string:length(ChStr),
    {updated, S#input_state{
        value = unicode:characters_to_list([Before, ChStr, After]),
        cursor = C + ChLen
    }};

%% Paste
handle_key({paste, Text}, #input_state{value = V, cursor = C} = S) ->
    Before = string:slice(V, 0, C),
    After = string:slice(V, C),
    PasteStr = if is_binary(Text) -> unicode:characters_to_list(Text);
                  true -> Text
               end,
    %% Strip newlines from pasted text
    Clean = lists:filter(fun(Ch) -> Ch =/= $\n andalso Ch =/= $\r end, PasteStr),
    PLen = string:length(Clean),
    {updated, S#input_state{
        value = unicode:characters_to_list([Before, Clean, After]),
        cursor = C + PLen
    }};

handle_key(_, S) ->
    {ignore, S}.

%% Render the input line. Returns an iolist.
render(#input_state{value = V, cursor = C, prompt = Prompt, focused = Focused}, Width) ->
    PromptW = etui_text:visible_width(Prompt),
    AvailW = max(1, Width - PromptW),
    ValLen = string:length(V),
    %% Determine visible window
    {Start, _End} = scroll_window(C, ValLen, AvailW),
    Visible = string:slice(V, Start, AvailW),
    VisW = etui_text:visible_width(Visible),
    %% Build cursor display
    CursorPos = C - Start,
    {BeforeCur, AtCur, AfterCur} = split_at_cursor(Visible, CursorPos),
    CursorChar = case AtCur of
        "" -> " ";
        _ -> AtCur
    end,
    CursorDisplay = if
        Focused -> ["\e[7m", CursorChar, "\e[27m"];
        true -> CursorChar
    end,
    Padding = max(0, AvailW - VisW - (case AtCur of "" -> 1; _ -> 0 end)),
    ["\e[2K\r", Prompt, BeforeCur, CursorDisplay, AfterCur, lists:duplicate(Padding, $\s)].

scroll_window(Cursor, _Len, AvailW) ->
    if Cursor < AvailW ->
        {0, AvailW};
    true ->
        Start = Cursor - (AvailW div 2),
        {max(0, Start), max(0, Start) + AvailW}
    end.

split_at_cursor(Str, Pos) ->
    Len = string:length(Str),
    Before = string:slice(Str, 0, Pos),
    if Pos >= Len ->
        {unicode:characters_to_list(Before), "", ""};
    true ->
        At = string:slice(Str, Pos, 1),
        After = string:slice(Str, Pos + 1),
        {unicode:characters_to_list(Before),
         unicode:characters_to_list(At),
         unicode:characters_to_list(After)}
    end.

%% Word movement helpers
word_left(#input_state{cursor = 0} = S) -> S;
word_left(#input_state{value = V, cursor = C} = S) ->
    Chars = unicode:characters_to_list(string:slice(V, 0, C)),
    %% Skip trailing spaces, then skip word chars
    NewC = skip_back_spaces(lists:reverse(Chars), C),
    NewC2 = skip_back_word(lists:reverse(unicode:characters_to_list(string:slice(V, 0, NewC))), NewC),
    S#input_state{cursor = NewC2}.

word_right(#input_state{value = V, cursor = C} = S) ->
    Len = string:length(V),
    if C >= Len -> S;
    true ->
        Rest = unicode:characters_to_list(string:slice(V, C)),
        %% Skip leading spaces, then skip word chars
        NewC = skip_fwd_spaces(Rest, C),
        NewC2 = skip_fwd_word(unicode:characters_to_list(string:slice(V, NewC)), NewC),
        S#input_state{cursor = NewC2}
    end.

delete_word_backward(#input_state{cursor = 0} = S) -> S;
delete_word_backward(#input_state{value = V, cursor = C} = S) ->
    #input_state{cursor = NewC} = word_left(S),
    Before = string:slice(V, 0, NewC),
    After = string:slice(V, C),
    S#input_state{value = unicode:characters_to_list([Before, After]), cursor = NewC}.

skip_back_spaces([], C) -> C;
skip_back_spaces([$\s | Rest], C) -> skip_back_spaces(Rest, C - 1);
skip_back_spaces(_, C) -> C.

skip_back_word([], C) -> C;
skip_back_word([$\s | _], C) -> C;
skip_back_word([_ | Rest], C) -> skip_back_word(Rest, C - 1).

skip_fwd_spaces([], C) -> C;
skip_fwd_spaces([$\s | Rest], C) -> skip_fwd_spaces(Rest, C + 1);
skip_fwd_spaces(_, C) -> C.

skip_fwd_word([], C) -> C;
skip_fwd_word([$\s | _], C) -> C;
skip_fwd_word([_ | Rest], C) -> skip_fwd_word(Rest, C + 1).
