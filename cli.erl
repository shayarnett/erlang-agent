-module(cli).
-export([main/0, main/1]).

%% Usage: erl -noshell -pa ebin -pa etui/ebin -run cli main

%% ── Synthwave/Cyberpunk color palette (256-color) ──────────────
-define(C_CYAN,    "51").   %% electric cyan (header, accents)
-define(C_PINK,    "213").  %% hot pink (prompt chevron, load_module)
-define(C_MAGENTA, "53").   %% deep magenta (user message bg)
-define(C_NAVY,    "17").   %% deep navy (exec tool bg)
-define(C_PURPLE,  "54").   %% deep purple (file tool bg)
-define(C_DMAGENTA,"90").   %% dark magenta (load_module bg)
-define(C_GREY,    "236").  %% dark grey (footer bg, fallback)
-define(C_LAVENDER,"141").  %% lavender (stats)
-define(C_GREEN,   "87").   %% neon cyan-green (success)
-define(C_RED,     "203").  %% neon red-pink (errors)
-define(C_CMDOUT,  "117").  %% light blue (command output)
-define(C_FILEOUT, "183").  %% light purple (file output)

main() -> main([]).
main(_Args) ->
    Opts = parse_cli_args(init:get_plain_arguments(), #{}),
    agent:start(Opts#{quiet => true}),
    ok = shell:start_interactive({noshell, raw}),

    Width = tty_width(),
    Model = maps:get(model, Opts, "glm-4.7-flash"),
    put(width, Width),
    put(model, Model),
    render_header(Width, Model),
    chat_loop(Width),
    agent:stop(),
    halt(0).

parse_cli_args([], Acc) -> Acc;
parse_cli_args(["--url", Url | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{llm_url => Url});
parse_cli_args(["--model", Model | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{model => Model});
parse_cli_args(["--system", System | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{system => System});
parse_cli_args([_ | Rest], Acc) ->
    parse_cli_args(Rest, Acc).

tty_width() ->
    case io:columns() of
        {ok, W} -> W;
        _ -> 80
    end.

%%--------------------------------------------------------------------
%% Header
%%--------------------------------------------------------------------

render_header(Width, Model) ->
    io:put_chars([
        "\r\n",
        %% Title: electric cyan bold
        "\e[1m\e[38;5;" ?C_CYAN "m", "chat", "\e[39m\e[22m",
        %% Version: dim
        "\e[2m v0.1 \e[22m",
        %% Model: hot pink
        "\e[38;5;" ?C_PINK "m(", Model, ")\e[39m",
        "\r\n",
        %% Keybinding hints: dim cyan
        "\r\n",
        %% Separator: cyan thin line
        cyan_line(Width),
        "\r\n\r\n"
    ]).

%%--------------------------------------------------------------------
%% Chat loop
%%--------------------------------------------------------------------

chat_loop(Width) ->
    render_footer(Width),
    case read_input(Width) of
        {ok, ""} ->
            chat_loop(Width);
        {ok, "/quit"} ->
            clear_footer(Width),
            io:put_chars(["\r\n\e[38;5;" ?C_CYAN "m", "bye", "\e[39m\r\n"]);
        {ok, "/clear"} ->
            agent ! clear_history,
            %% Clear screen and re-render header
            io:put_chars("\e[2J\e[H"),
            Model = case get(model) of undefined -> "?"; M3 -> M3 end,
            render_header(Width, Model),
            io:put_chars(["\e[38;5;" ?C_GREEN "m  \342\234\223 history cleared\e[39m\r\n\r\n"]),
            chat_loop(Width);
        {ok, "/model"} ->
            Model = case get(model) of undefined -> "?"; M2 -> M2 end,
            io:put_chars(["\e[38;5;" ?C_CYAN "m  model: \e[39m", Model, "\r\n\r\n"]),
            chat_loop(Width);
        {ok, "/help"} ->
            Cmds = slash_commands(),
            io:put_chars("\r\n"),
            lists:foreach(fun({Name, Desc}) ->
                NamePad = lists:duplicate(max(1, 14 - length(Name)), $\s),
                io:put_chars(["  \e[38;5;" ?C_CYAN "m/", Name, "\e[39m",
                              NamePad, "\e[2m", Desc, "\e[22m\r\n"])
            end, Cmds),
            io:put_chars("\r\n"),
            chat_loop(Width);
        {ok, Input} ->
            clear_footer(Width),
            render_user_message(Input, Width),
            %% Spinner + tool callback
            Self = self(),
            SpinRef = make_ref(),
            SpinPid = spawn_link(fun() -> spin_loop("thinking...", 0, Self, SpinRef) end),
            T0 = erlang:monotonic_time(millisecond),
            OnTool = fun(Event, Data) ->
                SpinPid ! pause,
                receive {paused, SpinRef} -> ok after 200 -> ok end,
                io:put_chars("\e[2K\r"),
                case Event of
                    tool_call ->
                        {Name, Args} = Data,
                        render_tool_call(Name, Args, Width);
                    tool_result ->
                        {Name, Result} = Data,
                        render_tool_result(Name, Result, Width)
                end,
                SpinPid ! resume
            end,

            Result = agent:chat(Input, #{keep_history => true, on_tool => OnTool}),
            SpinPid ! stop,
            receive {spin_done, SpinRef} -> ok after 500 -> ok end,
            io:put_chars("\e[2K\r"),
            T1 = erlang:monotonic_time(millisecond),
            Elapsed = (T1 - T0) / 1000,
            case Result of
                {ok, Reply} ->
                    render_assistant_reply(Reply, Width),
                    render_stats(Elapsed, Reply, Width);
                {error, Reason} ->
                    io:put_chars(["\e[38;5;" ?C_RED "m  error: ",
                                  io_lib:format("~p", [Reason]),
                                  "\e[39m\r\n\r\n"])
            end,
            chat_loop(Width);
        eof ->
            clear_footer(Width),
            io:put_chars(["\r\n\e[38;5;" ?C_CYAN "m", "bye", "\e[39m\r\n"])
    end.

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

render_user_message(Input, Width) ->
    %% Deep magenta background — synthwave user bubble
    Padded = pad_to_width(["  ", Input], Width),
    io:put_chars(["\e[48;5;" ?C_MAGENTA "m\e[97m", Padded, "\e[39m\e[49m\r\n\r\n"]).

render_assistant_reply(Reply, Width) ->
    Lines = etui_md:render(binary_to_list(Reply), Width - 4),
    io:put_chars("\r\n"),
    lists:foreach(fun(L) -> io:put_chars(["  ", L, "\r\n"]) end, Lines),
    io:put_chars("\r\n").

%% ── Tool call headers ──

render_tool_call(<<"exec">>, Args, Width) ->
    Cmd = tool_arg(Args, [<<"command">>, <<"cmd">>, <<"raw">>, <<"0">>]),
    %% Deep navy bg, bright cyan $ prefix
    Header = pad_to_width(["  \e[38;5;" ?C_CYAN "m\e[1m$ \e[22m", Cmd], Width),
    io:put_chars(["\e[48;5;" ?C_NAVY "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"read_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"filename">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mread\e[22m ", Path], Width),
    io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"write_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mwrite\e[22m ", Path], Width),
    io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"load_module">>, Args, Width) ->
    Name = tool_arg(Args, [<<"module_name">>, <<"name">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mload\e[22m ", Name], Width),
    io:put_chars(["\e[48;5;" ?C_DMAGENTA "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"http_get">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mGET\e[22m ", truncate_bin(Url, Width - 10)], Width),
    io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"http_post">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mPOST\e[22m ", truncate_bin(Url, Width - 11)], Width),
    io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(Name, _Args, Width) ->
    Header = pad_to_width(["  \e[1m", Name, "\e[22m"], Width),
    io:put_chars(["\e[48;5;" ?C_GREY "m\e[97m", Header, "\e[39m\e[49m\r\n"]).

%% ── Tool results ──

render_tool_result(<<"exec">>, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;" ?C_NAVY "m\e[38;5;" ?C_CMDOUT "m\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 6 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(length(Lines) - 5), " more lines)\e[23m"],
                Width),
            io:put_chars(["\e[48;5;" ?C_NAVY "m\e[38;5;" ?C_CMDOUT "m\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");

render_tool_result(<<"read_file">>, Result, Width) ->
    Sz = byte_size(Result),
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist(Lines, 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[38;5;" ?C_FILEOUT "m\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 5 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(Sz), " bytes, ",
                 integer_to_list(length(Lines)), " lines)\e[23m"], Width),
            io:put_chars(["\e[48;5;" ?C_PURPLE "m\e[38;5;" ?C_FILEOUT "m\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");

render_tool_result(<<"load_module">>, Result, _Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    lists:foreach(fun(L) ->
        case L of
            <<>> -> ok;
            _ -> io:put_chars(["\e[38;5;" ?C_PINK "m  ", L, "\e[39m\r\n"])
        end
    end, Lines),
    io:put_chars("\r\n");

render_tool_result(_Name, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 3),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;" ?C_GREY "m\e[2m", Padded, "\e[22m\e[49m\r\n"])
    end, Visible),
    io:put_chars("\r\n").

render_stats(Elapsed, Reply, _Width) ->
    Bytes = byte_size(Reply),
    io:put_chars([
        "\e[38;5;" ?C_LAVENDER "m  ",
        io_lib:format("~.1fs", [Elapsed]),
        "  ~",
        integer_to_list(Bytes div 4), " tokens",
        "\e[39m\r\n\r\n"
    ]).

render_footer(Width) ->
    Model = case get(model) of undefined -> "?"; M -> M end,
    Cwd = case file:get_cwd() of {ok, D} -> tilde(D); _ -> "?" end,
    Left = [" ", Cwd],
    Right = [Model, " "],
    Gap = Width - erlang:iolist_size(Left) - erlang:iolist_size(Right),
    Padding = lists:duplicate(max(1, Gap), $\s),
    H = tty_height(),
    io:put_chars([
        "\e[s",
        %% Cyan accent line on row H-1
        "\e[", integer_to_list(H - 1), ";1H",
        "\e[38;5;" ?C_CYAN "m", lists:duplicate(Width, $-), "\e[39m",
        %% Footer bar on last row
        "\e[", integer_to_list(H), ";1H",
        "\e[48;5;" ?C_GREY "m\e[38;5;" ?C_CYAN "m",
        Left, Padding, Right,
        "\e[39m\e[49m",
        "\e[u"
    ]).

clear_footer(_Width) ->
    H = tty_height(),
    io:put_chars([
        "\e[s",
        "\e[", integer_to_list(H - 1), ";1H", "\e[2K",
        "\e[", integer_to_list(H), ";1H", "\e[2K",
        "\e[u"
    ]).

%%--------------------------------------------------------------------
%% Slash commands
%%--------------------------------------------------------------------

slash_commands() ->
    [{"clear",  "Reset conversation history"},
     {"quit",   "Exit the chat"},
     {"model",  "Show current model"},
     {"help",   "Show available commands"}].

%%--------------------------------------------------------------------
%% Input
%%--------------------------------------------------------------------

read_input(Width) ->
    %% Hot pink prompt chevron
    State = etui_input:new("\e[38;5;" ?C_PINK "m>\e[39m "),
    render_input(State, Width),
    input_loop(State, Width, 0).

input_loop(State, Width, MenuLines) ->
    Chars = io:get_chars("", 1024),
    Key = etui_keys:parse(Chars),
    case etui_input:handle_key(Key, State) of
        {submit, Value} ->
            clear_menu(MenuLines),
            io:put_chars("\r\n"),
            {ok, string:trim(Value)};
        {updated, NewState} ->
            %% Synchronized output: buffer everything, display atomically
            io:put_chars("\e[?2026h"),
            clear_menu(MenuLines),
            render_input(NewState, Width),
            NewMenuLines = maybe_show_menu(NewState, Width),
            io:put_chars("\e[?2026l"),
            input_loop(NewState, Width, NewMenuLines);
        {escape, _} ->
            clear_menu(MenuLines),
            io:put_chars("\r\n"),
            {ok, ""};
        {ignore, _} ->
            input_loop(State, Width, MenuLines)
    end.

render_input(State, Width) ->
    io:put_chars(["\r", etui_input:render(State, Width)]).

%% Show slash menu if input starts with "/"
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
    N = length(Matches),
    %% Ensure terminal has room below cursor: push N blank lines then come back
    io:put_chars(lists:duplicate(N, $\n)),
    io:put_chars(["\e[", integer_to_list(N), "A"]),
    %% Now render each menu line using down movement (no scrolling)
    lists:foreach(fun({Idx, {Name, Desc}}) ->
        %% Move down one line
        io:put_chars("\e[B\r\e[2K"),
        Indicator = case Idx of
            0 -> "\e[38;5;" ?C_CYAN "m-> \e[39m";
            _ -> "   "
        end,
        NamePad = lists:duplicate(max(1, 14 - length(Name)), $\s),
        Line = [Indicator, "\e[38;5;" ?C_CYAN "m", Name, "\e[39m",
                NamePad, "\e[2m", Desc, "\e[22m"],
        Padded = pad_to_width(Line, Width),
        io:put_chars(Padded)
    end, lists:zip(lists:seq(0, N - 1), Matches)),
    %% Move cursor back up to input line
    io:put_chars(["\e[", integer_to_list(N), "A\r"]),
    %% Re-render input so cursor is in right spot
    N.

%% Clear N lines below the current cursor position
clear_menu(0) -> ok;
clear_menu(N) ->
    %% Move down, clear each line, move back up
    lists:foreach(fun(_) ->
        io:put_chars("\e[B\r\e[2K")
    end, lists:seq(1, N)),
    io:put_chars(["\e[", integer_to_list(N), "A\r"]).

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

%% Pad iolist to fill Width with spaces (ignoring ANSI escapes)
pad_to_width(IOList, Width) ->
    Bin = iolist_to_binary(IOList),
    Visible = visible_len(Bin),
    Pad = max(0, Width - Visible),
    [IOList, lists:duplicate(Pad, $\s)].

%% Count visible characters (strip ANSI escape sequences)
visible_len(Bin) -> visible_len(Bin, 0).
visible_len(<<>>, N) -> N;
visible_len(<<27, $[, Rest/binary>>, N) ->
    skip_csi(Rest, N);
visible_len(<<_C, Rest/binary>>, N) ->
    visible_len(Rest, N + 1).

skip_csi(<<>>, N) -> N;
skip_csi(<<C, Rest/binary>>, N) when C >= $@, C =< $~ ->
    visible_len(Rest, N);
skip_csi(<<_, Rest/binary>>, N) ->
    skip_csi(Rest, N).

%% Cyan separator line
cyan_line(Width) ->
    ["\e[38;5;" ?C_CYAN "m", lists:duplicate(Width, $-), "\e[39m"].

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

tty_height() ->
    case io:rows() of
        {ok, H} -> H;
        _ -> 24
    end.

spin_loop(Msg, Idx, Parent, Ref) ->
    Frames = [<<226,160,139>>,<<226,160,153>>,<<226,160,185>>,<<226,160,184>>,
              <<226,160,188>>,<<226,160,180>>,<<226,160,166>>,<<226,160,167>>,
              <<226,160,135>>,<<226,160,143>>],
    Frame = lists:nth((Idx rem length(Frames)) + 1, Frames),
    %% Cyan spinner
    io:put_chars(["\e[2K\r  \e[38;5;" ?C_CYAN "m", Frame, "\e[39m \e[2m", Msg, "\e[22m"]),
    receive
        stop -> Parent ! {spin_done, Ref};
        pause ->
            Parent ! {paused, Ref},
            receive resume -> ok end,
            spin_loop(Msg, Idx, Parent, Ref)
    after 80 ->
        spin_loop(Msg, Idx + 1, Parent, Ref)
    end.
