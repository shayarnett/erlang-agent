-module(cli).
-export([main/0, main/1]).

%% Usage: erl -noshell -pa ebin -pa etui/ebin -run cli main
%%
%% Rendering approach (pi-tui style):
%%   - No scroll regions. Write linearly to terminal scrollback.
%%   - Chrome (widgets + prompt + footer) always rendered at the bottom.
%%   - Before new output: erase chrome, write output, re-render chrome.
%%   - Spinner appears in chat area above chrome, prompt stays active.

main() -> main([]).
main(_Args) ->
    Opts = parse_cli_args(init:get_plain_arguments(), #{}),
    agent:start(Opts#{quiet => true}),
    ok = shell:start_interactive({noshell, raw}),
    ThemeInit = maps:get(theme, Opts, synthwave),
    theme:set(ThemeInit),
    put(theme_name, ThemeInit),
    etui_panel:start(),
    start_extensions(),
    timer:sleep(100),

    Width = tty_width(),
    Model = maps:get(model, Opts, "glm-4.7-flash"),
    put(width, Width),
    put(model, Model),
    put(widget_lines, 0),

    render_header(Width, Model),
    render_chrome(Width),

    %% Spawn input reader — sends {input, Chars} to us
    Self = self(),
    spawn_link(fun() -> input_reader(Self) end),

    InputState = etui_input:new(theme:prompt()),
    event_loop(InputState, Width, idle, 0).

parse_cli_args([], Acc) -> Acc;
parse_cli_args(["--url", Url | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{llm_url => Url});
parse_cli_args(["--model", Model | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{model => Model});
parse_cli_args(["--system", System | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{system => System});
parse_cli_args(["--theme", Theme | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{theme => list_to_atom(Theme)});
parse_cli_args(["--api", "anthropic" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api => anthropic});
parse_cli_args(["--api", "openai" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api => openai});
parse_cli_args(["--api-key", Key | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api_key => Key});
parse_cli_args(["--max-steps", N | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{max_steps => list_to_integer(N)});
parse_cli_args([_ | Rest], Acc) ->
    parse_cli_args(Rest, Acc).

tty_width() ->
    case io:columns() of {ok, W} -> W; _ -> 80 end.

%%--------------------------------------------------------------------
%% Extensions
%%--------------------------------------------------------------------

start_extensions() ->
    pets:cat(),
    pets:blob(),
    widgets:uptime(),
    ok.

%%--------------------------------------------------------------------
%% Input reader process
%%--------------------------------------------------------------------

input_reader(Parent) ->
    case io:get_chars("", 1) of
        eof -> ok;
        {error, _} -> ok;
        Chars ->
            Parent ! {input, Chars},
            input_reader(Parent)
    end.

%%--------------------------------------------------------------------
%% Chrome: widgets + prompt + footer (the persistent bottom zone)
%%--------------------------------------------------------------------

render_chrome(Width) ->
    render_chrome(Width, undefined).

render_chrome(Width, InputState) ->
    PanelLines = etui_panel:render(Width),
    W = length(PanelLines),
    put(widget_lines, W),
    OldMax = case get(max_widget_lines) of undefined -> 0; MV -> MV end,
    put(max_widget_lines, max(W, OldMax)),
    Model = case get(model) of undefined -> "?"; M -> M end,
    Cwd = case file:get_cwd() of {ok, D} -> tilde(D); _ -> "?" end,
    Left = [" ", Cwd],
    Right = [Model, " "],
    Gap = Width - erlang:iolist_size(Left) - erlang:iolist_size(Right),
    Padding = lists:duplicate(max(1, Gap), $\s),
    %% Widgets (lines include their own ANSI styling)
    lists:foreach(fun(Line) ->
        io:put_chars(["\r\e[2K ", Line, "\e[39m\e[49m\e[K\r\n"])
    end, PanelLines),
    %% Prompt
    case InputState of
        undefined ->
            io:put_chars(etui_input:render(etui_input:new(theme:prompt()), Width));
        _ ->
            io:put_chars(etui_input:render(InputState, Width))
    end,
    %% Footer below prompt, cursor back to prompt
    io:put_chars([
        "\r\n",
        theme:bg(footer_bg), theme:fg(footer_fg),
        Left, Padding, Right,
        "\e[39m\e[49m",
        "\e[1A"
    ]).

erase_chrome() ->
    W = case get(widget_lines) of undefined -> 0; V -> V end,
    Max = case get(max_widget_lines) of undefined -> W; MV -> max(W, MV) end,
    case Max > 0 of
        true -> io:put_chars(["\e[", integer_to_list(Max), "A"]);
        false -> ok
    end,
    io:put_chars("\r\e[J").

with_output(Width, InputState, OutputFun) ->
    io:put_chars("\e[?2026h"),
    erase_chrome(),
    OutputFun(),
    render_chrome(Width, InputState),
    io:put_chars("\e[?2026l").

%%--------------------------------------------------------------------
%% Header
%%--------------------------------------------------------------------

render_header(Width, Model) ->
    io:put_chars([
        "\e[2J\e[H",
        "\r\n",
        "\e[1m", theme:fg(accent), "chat", "\e[39m\e[22m",
        "\e[2m v0.1 \e[22m",
        theme:fg(prompt_icon), "(", Model, ")\e[39m",
        "\r\n\r\n",
        theme:line(Width),
        "\r\n\r\n"
    ]).

%%--------------------------------------------------------------------
%% Event loop — handles input + agent replies + spinner ticks
%%
%% Mode:
%%   idle                         — waiting for user input
%%   {thinking, SpinIdx, T0, Ref} — agent is working, spinner active
%%--------------------------------------------------------------------

event_loop(InputState, Width, Mode, MenuLines) ->
    Timeout = case Mode of
        idle -> 500;
        {thinking, _, _, _} -> 80
    end,
    receive
        {input, Chars} ->
            handle_input(Chars, InputState, Width, Mode, MenuLines);

        {chat_reply, Result} ->
            {thinking, _Idx, T0, _Ref} = Mode,
            T1 = erlang:monotonic_time(millisecond),
            Elapsed = (T1 - T0) / 1000,
            %% Erase chrome + spinner line, render response, re-render chrome
            NewInput = etui_input:new(theme:prompt()),
            W = case get(widget_lines) of undefined -> 0; V -> V end,
            Max = case get(max_widget_lines) of undefined -> W; MV -> max(W, MV) end,
            Up = Max + 1, %% +1 for spinner line above widgets
            io:put_chars(["\e[?2026h",
                          "\e[", integer_to_list(Up), "A",
                          "\r\e[J"]),
            case Result of
                {ok, Reply} ->
                    render_assistant_reply(Reply, Width),
                    render_stats(Elapsed, Reply, Width);
                {error, max_steps} ->
                    io:put_chars([theme:fg(error),
                                  "  hit max steps limit (increase with --max-steps N)",
                                  "\e[39m\r\n\r\n"]);
                {error, Reason} ->
                    io:put_chars([theme:fg(error), "  error: ",
                                  io_lib:format("~p", [Reason]),
                                  "\e[39m\r\n\r\n"])
            end,
            render_chrome(Width, NewInput),
            io:put_chars("\e[?2026l"),
            event_loop(NewInput, Width, idle, 0);

        {tool_call, Name, Args} ->
            with_output(Width, InputState, fun() ->
                %% Spinner line stays, tool output goes above it
                render_tool_call(Name, Args, Width)
            end),
            event_loop(InputState, Width, Mode, MenuLines);

        {tool_result, Name, Result} ->
            with_output(Width, InputState, fun() ->
                render_tool_result(Name, Result, Width)
            end),
            event_loop(InputState, Width, Mode, MenuLines)

    after Timeout ->
        case Mode of
            idle ->
                refresh_widgets(Width),
                event_loop(InputState, Width, Mode, MenuLines);
            {thinking, _, _, _} ->
                tick_spinner(InputState, Width, Mode, MenuLines)
        end
    end.

%%--------------------------------------------------------------------
%% Input handling
%%--------------------------------------------------------------------

handle_input(Chars, InputState, Width, Mode, MenuLines) ->
    Key = etui_keys:parse(Chars),
    case etui_input:handle_key(Key, InputState) of
        {submit, Value} ->
            Trimmed = string:trim(Value),
            clear_menu(MenuLines, Width),
            handle_submit(Trimmed, InputState, Width, Mode);
        {updated, NewState} ->
            io:put_chars("\e[?2026h"),
            erase_chrome(),
            render_chrome(Width, NewState),
            NewMenu = maybe_show_menu(NewState, Width),
            io:put_chars("\e[?2026l"),
            event_loop(NewState, Width, Mode, NewMenu);
        {escape, _} ->
            clear_menu(MenuLines, Width),
            event_loop(InputState, Width, Mode, 0);
        {ignore, _} ->
            event_loop(InputState, Width, Mode, MenuLines)
    end.

handle_submit("", InputState, Width, Mode) ->
    event_loop(InputState, Width, Mode, 0);
handle_submit("/quit", _InputState, _Width, _Mode) ->
    erase_chrome(),
    io:put_chars([theme:fg(accent), "bye", "\e[39m\r\n"]),
    agent:stop(),
    halt(0);
handle_submit("/clear", _InputState, Width, Mode) ->
    agent ! clear_history,
    Model = case get(model) of undefined -> "?"; M -> M end,
    erase_chrome(),
    render_header(Width, Model),
    io:put_chars([theme:fg(success), "  \342\234\223 history cleared\e[39m\r\n\r\n"]),
    NewInput = etui_input:new(theme:prompt()),
    render_chrome(Width, NewInput),
    event_loop(NewInput, Width, Mode, 0);
handle_submit("/model", InputState, Width, Mode) ->
    with_output(Width, InputState, fun() ->
        Model = case get(model) of undefined -> "?"; M -> M end,
        io:put_chars([theme:fg(accent), "  model: \e[39m", Model, "\r\n\r\n"])
    end),
    event_loop(InputState, Width, Mode, 0);
handle_submit("/theme", _InputState, Width, Mode) ->
    erase_chrome(),
    show_theme_picker(Width),
    NewInput = etui_input:new(theme:prompt()),
    render_chrome(Width, NewInput),
    event_loop(NewInput, Width, Mode, 0);
handle_submit("/help", InputState, Width, Mode) ->
    with_output(Width, InputState, fun() ->
        Cmds = slash_commands(),
        io:put_chars("\r\n"),
        lists:foreach(fun({Name, Desc}) ->
            NamePad = lists:duplicate(max(1, 14 - length(Name)), $\s),
            io:put_chars(["  ", theme:fg(accent), "/", Name, "\e[39m",
                          NamePad, "\e[2m", Desc, "\e[22m\r\n"])
        end, Cmds),
        io:put_chars("\r\n")
    end),
    event_loop(InputState, Width, Mode, 0);
handle_submit(Input, _InputState, Width, idle) ->
    %% Submit a chat message — render it, start thinking
    Self = self(),
    Ref = make_ref(),
    NewInput = etui_input:new(theme:prompt()),
    io:put_chars("\e[?2026h"),
    erase_chrome(),
    render_user_message(Input, Width),
    %% Render spinner line in chat area, then chrome below
    render_spinner_line(0, "thinking..."),
    io:put_chars("\r\n"),
    render_chrome(Width, NewInput),
    io:put_chars("\e[?2026l"),

    %% Fire off agent chat (non-blocking)
    OnTool = fun(Event, Data) ->
        case Event of
            tool_call ->
                {Name, Args} = Data,
                Self ! {tool_call, Name, Args};
            tool_result ->
                {Name, Result} = Data,
                Self ! {tool_result, Name, Result}
        end
    end,
    spawn_link(fun() ->
        Result = agent:chat(Input, #{keep_history => true, on_tool => OnTool}),
        Self ! {chat_reply, Result}
    end),

    T0 = erlang:monotonic_time(millisecond),
    event_loop(NewInput, Width, {thinking, 0, T0, Ref}, 0);
handle_submit(_Input, InputState, Width, {thinking, _, _, _} = Mode) ->
    %% Already thinking — ignore new submissions for now
    event_loop(InputState, Width, Mode, 0).

%%--------------------------------------------------------------------
%% Spinner — updates the spinner line in the chat area above chrome
%%--------------------------------------------------------------------

tick_spinner(InputState, Width, {thinking, Idx, T0, Ref}, MenuLines) ->
    NewIdx = Idx + 1,
    W = case get(widget_lines) of undefined -> 0; V -> V end,
    %% Move cursor up from prompt past widgets to the spinner line,
    %% update it, then come back down.
    Up = W + 1,  %% widgets + spinner line
    io:put_chars([
        "\e[?2026h",
        "\e[", integer_to_list(Up), "A"  %% up to spinner line
    ]),
    render_spinner_line(NewIdx, "thinking..."),
    io:put_chars([
        "\e[", integer_to_list(Up), "B",  %% back down to prompt
        "\e[?2026l"
    ]),
    %% Refresh widgets every ~500ms (every 6th tick)
    case NewIdx rem 6 of
        0 -> refresh_widgets(Width);
        _ -> ok
    end,
    event_loop(InputState, Width, {thinking, NewIdx, T0, Ref}, MenuLines).

render_spinner_line(Idx, Msg) ->
    Frames = [<<226,160,139>>,<<226,160,153>>,<<226,160,185>>,<<226,160,184>>,
              <<226,160,188>>,<<226,160,180>>,<<226,160,166>>,<<226,160,167>>,
              <<226,160,135>>,<<226,160,143>>],
    Frame = lists:nth((Idx rem length(Frames)) + 1, Frames),
    io:put_chars(["\e[2K\r  ", theme:fg(accent), Frame, "\e[39m \e[2m", Msg, "\e[22m"]).

%% Re-render widget lines in place (above prompt).
%% Uses cursor save/restore so the input cursor isn't disturbed.
refresh_widgets(Width) ->
    PanelLines = etui_panel:render(Width),
    W = length(PanelLines),
    OldW = case get(widget_lines) of undefined -> 0; V -> V end,
    put(widget_lines, W),
    OldMax = case get(max_widget_lines) of undefined -> 0; MV -> MV end,
    put(max_widget_lines, max(W, OldMax)),
    Up = OldW, %% widgets are above prompt; cursor is on prompt line
    case OldW > 0 of
        true ->
            io:put_chars([
                "\e[?2026h",
                "\e[s",  %% save cursor
                "\e[", integer_to_list(Up), "A",
                lists:map(fun(Line) ->
                    ["\r\e[2K ", Line, "\e[39m\e[49m\e[K\r\n"]
                end, PanelLines),
                "\e[u",  %% restore cursor
                "\e[?2026l"
            ]);
        false -> ok
    end.

%%--------------------------------------------------------------------
%% Theme picker
%%--------------------------------------------------------------------

show_theme_picker(Width) ->
    Themes = theme:list(),
    io:put_chars("\r\n"),
    lists:foreach(fun({Idx, {Name, Desc}}) ->
        OldTheme = theme:get(),
        theme:set(Name),
        Num = integer_to_list(Idx),
        Label = atom_to_list(Name),
        Preview = [
            theme:bg(exec_bg), theme:fg(exec_fg), " $ ", "\e[39m\e[49m",
            theme:bg(file_bg), theme:fg(file_fg), " read ", "\e[39m\e[49m",
            theme:bg(user_bg), "\e[97m", " user ", "\e[39m\e[49m",
            theme:fg(accent), " accent", "\e[39m ",
            theme:fg(success), "ok", "\e[39m ",
            theme:fg(error), "err", "\e[39m"
        ],
        Padded = pad_to_width(["  ", Num, ") ",
            theme:fg(accent), Label, "\e[39m",
            lists:duplicate(max(1, 14 - length(Label)), $\s),
            "\e[2m", Desc, "\e[22m"], Width),
        io:put_chars([Padded, "\r\n"]),
        PreviewPad = pad_to_width(["     ", Preview], Width),
        io:put_chars([PreviewPad, "\r\n"]),
        theme:set(OldTheme)
    end, lists:zip(lists:seq(1, length(Themes)), Themes)),
    io:put_chars("\r\n"),
    io:put_chars(["  ", theme:fg(accent), "pick (1-",
                  integer_to_list(length(Themes)), "): \e[39m"]),
    %% Wait for input via the reader process
    receive {input, Chars} -> ok end,
    Choice = try list_to_integer(string:trim(Chars)) catch _:_ -> 0 end,
    case Choice >= 1 andalso Choice =< length(Themes) of
        true ->
            {ThemeName, _} = lists:nth(Choice, Themes),
            theme:set(ThemeName),
            put(theme_name, ThemeName),
            Model = case get(model) of undefined -> "?"; M -> M end,
            render_header(tty_width(), Model),
            io:put_chars([theme:fg(success), "  \342\234\223 theme: ",
                          atom_to_list(ThemeName), "\e[39m\r\n\r\n"]);
        false ->
            io:put_chars("  (cancelled)\r\n\r\n")
    end.

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

render_user_message(Input, Width) ->
    Padded = pad_to_width(["  ", Input], Width),
    io:put_chars([theme:bg(user_bg), "\e[97m", Padded, "\e[39m\e[49m\r\n"]).

render_assistant_reply(Reply, Width) ->
    Lines = etui_md:render(binary_to_list(Reply), Width - 4),
    io:put_chars("\r\n"),
    lists:foreach(fun(L) -> io:put_chars(["  ", L, "\r\n"]) end, Lines),
    io:put_chars("\r\n").

render_tool_call(<<"exec">>, Args, Width) ->
    Cmd = tool_arg(Args, [<<"command">>, <<"cmd">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  ", theme:fg(accent), "\e[1m$ \e[22m", Cmd], Width),
    io:put_chars([theme:bg(exec_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(<<"read_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"filename">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mread\e[22m ", Path], Width),
    io:put_chars([theme:bg(file_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(<<"write_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mwrite\e[22m ", Path], Width),
    io:put_chars([theme:bg(file_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(<<"load_module">>, Args, Width) ->
    Name = tool_arg(Args, [<<"module_name">>, <<"name">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mload\e[22m ", Name], Width),
    io:put_chars([theme:bg(module_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(<<"http_get">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mGET\e[22m ", truncate_bin(Url, Width - 10)], Width),
    io:put_chars([theme:bg(file_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(<<"http_post">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mPOST\e[22m ", truncate_bin(Url, Width - 11)], Width),
    io:put_chars([theme:bg(file_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]);
render_tool_call(Name, _Args, Width) ->
    Header = pad_to_width(["  \e[1m", Name, "\e[22m"], Width),
    io:put_chars([theme:bg(tool_bg), "\e[97m", Header, "\e[39m\e[49m\r\n"]).

render_tool_result(<<"exec">>, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars([theme:bg(exec_bg), theme:fg(exec_fg), "\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 6 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(length(Lines) - 5), " more lines)\e[23m"],
                Width),
            io:put_chars([theme:bg(exec_bg), theme:fg(exec_fg), "\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");
render_tool_result(<<"read_file">>, Result, Width) ->
    Sz = byte_size(Result),
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist(Lines, 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars([theme:bg(file_bg), theme:fg(file_fg), "\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 5 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(Sz), " bytes, ",
                 integer_to_list(length(Lines)), " lines)\e[23m"], Width),
            io:put_chars([theme:bg(file_bg), theme:fg(file_fg), "\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");
render_tool_result(<<"load_module">>, Result, _Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    lists:foreach(fun(L) ->
        case L of
            <<>> -> ok;
            _ -> io:put_chars([theme:fg(module_fg), "  ", L, "\e[39m\r\n"])
        end
    end, Lines),
    io:put_chars("\r\n");
render_tool_result(_Name, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 3),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars([theme:bg(tool_bg), "\e[2m", Padded, "\e[22m\e[49m\r\n"])
    end, Visible),
    io:put_chars("\r\n").

render_stats(Elapsed, Reply, _Width) ->
    Bytes = byte_size(Reply),
    io:put_chars([
        theme:fg(stats), "  ",
        io_lib:format("~.1fs", [Elapsed]),
        "  ~",
        integer_to_list(Bytes div 4), " tokens",
        "\e[39m\r\n\r\n"
    ]).

%%--------------------------------------------------------------------
%% Slash commands
%%--------------------------------------------------------------------

slash_commands() ->
    [{"clear",  "Reset conversation history"},
     {"quit",   "Exit the chat"},
     {"model",  "Show current model"},
     {"theme",  "Switch color theme"},
     {"help",   "Show available commands"}].

maybe_show_menu(State, Width) ->
    Value = etui_input:get_value(State),
    case Value of
        "/" ++ Rest ->
            Prefix = string:lowercase(Rest),
            All = slash_commands(),
            Matches = [Cmd || {Name, _} = Cmd <- All,
                        Prefix =:= "" orelse
                        lists:prefix(Prefix, Name)],
            render_menu(Matches, Width);
        _ ->
            0
    end.

render_menu([], _Width) -> 0;
render_menu(Matches, Width) ->
    M = length(Matches),
    W = case get(widget_lines) of undefined -> 0; V -> V end,
    UpBy = min(M, W),
    case UpBy > 0 of
        true -> io:put_chars(["\e[", integer_to_list(UpBy), "A"]);
        false -> ok
    end,
    lists:foreach(fun({_Idx, {Name, Desc}}) ->
        Indicator = case _Idx of
            0 -> [theme:fg(accent), "-> \e[39m"];
            _ -> "   "
        end,
        NamePad = lists:duplicate(max(1, 14 - length(Name)), $\s),
        Line = [Indicator, theme:fg(accent), Name, "\e[39m",
                NamePad, "\e[2m", Desc, "\e[22m"],
        Padded = pad_to_width(Line, Width),
        io:put_chars(["\r\e[2K", Padded, "\n"])
    end, lists:zip(lists:seq(0, M - 1), Matches)),
    M.

clear_menu(0, _Width) -> ok;
clear_menu(_N, Width) ->
    erase_chrome(),
    render_chrome(Width).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

tool_arg(_Map, []) -> <<"?">>;
tool_arg(Map, [Key | Rest]) ->
    case maps:get(Key, Map, undefined) of
        undefined -> tool_arg(Map, Rest);
        Val when is_binary(Val) -> Val;
        Val -> iolist_to_binary(io_lib:format("~p", [Val]))
    end.

truncate_bin(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_bin(Bin, Max) when Max < 4 -> Bin;
truncate_bin(Bin, Max) ->
    <<Head:(Max-3)/binary, _/binary>> = Bin,
    <<Head/binary, "...">>.

pad_to_width(IOList, Width) ->
    Bin = iolist_to_binary(IOList),
    Visible = visible_len(Bin),
    Pad = max(0, Width - Visible),
    [IOList, lists:duplicate(Pad, $\s)].

visible_len(Bin) -> visible_len(Bin, 0).
visible_len(<<>>, N) -> N;
visible_len(<<27, $[, Rest/binary>>, N) ->
    skip_csi(Rest, N);
visible_len(<<C, Rest/binary>>, N) when C >= 16#F0 -> skip_utf8(Rest, 3, N);
visible_len(<<C, Rest/binary>>, N) when C >= 16#E0 -> skip_utf8(Rest, 2, N);
visible_len(<<C, Rest/binary>>, N) when C >= 16#C0 -> skip_utf8(Rest, 1, N);
visible_len(<<_C, Rest/binary>>, N) ->
    visible_len(Rest, N + 1).

skip_utf8(Bin, 0, N) -> visible_len(Bin, N + 1);
skip_utf8(<<_, Rest/binary>>, Count, N) -> skip_utf8(Rest, Count - 1, N);
skip_utf8(<<>>, _, N) -> N + 1.

skip_csi(<<>>, N) -> N;
skip_csi(<<C, Rest/binary>>, N) when C >= $@, C =< $~ ->
    visible_len(Rest, N);
skip_csi(<<_, Rest/binary>>, N) ->
    skip_csi(Rest, N).

tilde(Path) ->
    Home = os:getenv("HOME"),
    case Home of
        false -> Path;
        _ ->
            case lists:prefix(Home, Path) of
                true -> "~" ++ lists:nthtail(length(Home), Path);
                false -> Path
            end
    end.
