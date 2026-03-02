-module(cli).
-export([main/0, main/1]).

%% Usage: erl -noshell -pa ebin -pa etui/ebin -run cli main

%% ── Synthwave/Cyberpunk color palette ──────────────────────────
%% 256-color codes (48;5;X for bg, 38;5;X for fg):
%%   53  = deep magenta      (user message bg)
%%   17  = deep navy         (exec tool bg)
%%   54  = deep purple       (file tool bg)
%%   90  = dark magenta      (load_module bg)
%%   236 = dark grey         (footer bg, fallback tool bg)
%%   51  = electric cyan     (header accent fg)
%%   213 = hot pink          (user prompt chevron)
%%   141 = lavender          (stats text)
%%   87  = neon cyan-green   (success, /clear checkmark)
%%   203 = neon red-pink     (errors)

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
        "\e[1m\e[38;5;51m", "chat", "\e[39m\e[22m",
        %% Version: dim
        "\e[2m v0.1 \e[22m",
        %% Model: hot pink
        "\e[38;5;213m(", Model, ")\e[39m",
        "\r\n",
        %% Keybinding hints: dim cyan
        "\e[2m\e[38;5;51m",
        "  ctrl+c quit  |  /clear reset\r\n",
        "\e[39m\e[22m",
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
            io:put_chars(["\r\n\e[38;5;51m", "bye", "\e[39m\r\n"]);
        {ok, "/clear"} ->
            agent ! clear_history,
            io:put_chars(["\e[38;5;87m  \342\234\223 history cleared\e[39m\r\n\r\n"]),
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
                    io:put_chars(["\e[38;5;203m  error: ",
                                  io_lib:format("~p", [Reason]),
                                  "\e[39m\r\n\r\n"])
            end,
            chat_loop(Width);
        eof ->
            clear_footer(Width),
            io:put_chars("\r\n")
    end.

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

render_user_message(Input, Width) ->
    %% Deep magenta background — synthwave user bubble
    Padded = pad_to_width(["  ", Input], Width),
    io:put_chars(["\e[48;5;53m\e[97m", Padded, "\e[39m\e[49m\r\n\r\n"]).

render_assistant_reply(Reply, Width) ->
    Lines = etui_md:render(binary_to_list(Reply), Width - 4),
    io:put_chars("\r\n"),
    lists:foreach(fun(L) -> io:put_chars(["  ", L, "\r\n"]) end, Lines),
    io:put_chars("\r\n").

%% ── Tool call headers ──

render_tool_call(<<"exec">>, Args, Width) ->
    Cmd = tool_arg(Args, [<<"command">>, <<"cmd">>, <<"raw">>, <<"0">>]),
    %% Deep navy bg, bright cyan $ prefix
    Header = pad_to_width(["  \e[38;5;51m\e[1m$ \e[22m", Cmd], Width),
    io:put_chars(["\e[48;5;17m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"read_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"filename">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mread\e[22m ", Path], Width),
    io:put_chars(["\e[48;5;54m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"write_file">>, Args, Width) ->
    Path = tool_arg(Args, [<<"path">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mwrite\e[22m ", Path], Width),
    io:put_chars(["\e[48;5;54m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"load_module">>, Args, Width) ->
    Name = tool_arg(Args, [<<"module_name">>, <<"name">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mload\e[22m ", Name], Width),
    io:put_chars(["\e[48;5;90m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"http_get">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mGET\e[22m ", truncate_bin(Url, Width - 10)], Width),
    io:put_chars(["\e[48;5;54m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(<<"http_post">>, Args, Width) ->
    Url = tool_arg(Args, [<<"url">>, <<"raw">>, <<"0">>]),
    Header = pad_to_width(["  \e[1mPOST\e[22m ", truncate_bin(Url, Width - 11)], Width),
    io:put_chars(["\e[48;5;54m\e[97m", Header, "\e[39m\e[49m\r\n"]);

render_tool_call(Name, _Args, Width) ->
    Header = pad_to_width(["  \e[1m", Name, "\e[22m"], Width),
    io:put_chars(["\e[48;5;236m\e[97m", Header, "\e[39m\e[49m\r\n"]).

%% ── Tool results ──

render_tool_result(<<"exec">>, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;17m\e[38;5;117m\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 6 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(length(Lines) - 5), " more lines)\e[23m"],
                Width),
            io:put_chars(["\e[48;5;17m\e[38;5;117m\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");

render_tool_result(<<"read_file">>, Result, Width) ->
    Sz = byte_size(Result),
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist(Lines, 5),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;54m\e[38;5;183m\e[2m", Padded, "\e[22m\e[39m\e[49m\r\n"])
    end, Visible),
    case length(Lines) > 5 of
        true ->
            Hint = pad_to_width(
                ["  \e[3m... (", integer_to_list(Sz), " bytes, ",
                 integer_to_list(length(Lines)), " lines)\e[23m"], Width),
            io:put_chars(["\e[48;5;54m\e[38;5;183m\e[2m", Hint, "\e[22m\e[39m\e[49m\r\n"]);
        false -> ok
    end,
    io:put_chars("\r\n");

render_tool_result(<<"load_module">>, Result, _Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    lists:foreach(fun(L) ->
        case L of
            <<>> -> ok;
            _ -> io:put_chars(["\e[38;5;213m  ", L, "\e[39m\r\n"])
        end
    end, Lines),
    io:put_chars("\r\n");

render_tool_result(_Name, Result, Width) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    Visible = lists:sublist([L || L <- Lines, L =/= <<>>], 3),
    lists:foreach(fun(L) ->
        Padded = pad_to_width(["  ", truncate_bin(L, Width - 4)], Width),
        io:put_chars(["\e[48;5;236m\e[2m", Padded, "\e[22m\e[49m\r\n"])
    end, Visible),
    io:put_chars("\r\n").

render_stats(Elapsed, Reply, _Width) ->
    Bytes = byte_size(Reply),
    io:put_chars([
        "\e[38;5;141m  ",
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
        "\e[38;5;51m", lists:duplicate(Width, $-), "\e[39m",
        %% Footer bar on last row
        "\e[", integer_to_list(H), ";1H",
        "\e[48;5;236m\e[38;5;51m",
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
%% Input
%%--------------------------------------------------------------------

read_input(Width) ->
    %% Hot pink prompt chevron
    State = etui_input:new("\e[38;5;213m>\e[39m "),
    render_input(State, Width),
    input_loop(State, Width).

input_loop(State, Width) ->
    Chars = io:get_chars("", 1024),
    Key = etui_keys:parse(Chars),
    case etui_input:handle_key(Key, State) of
        {submit, Value} ->
            io:put_chars("\r\n"),
            {ok, string:trim(Value)};
        {updated, NewState} ->
            render_input(NewState, Width),
            input_loop(NewState, Width);
        {escape, _} ->
            io:put_chars("\r\n"),
            {ok, ""};
        {ignore, _} ->
            case Key of
                {key, c, [ctrl]} -> eof;
                {key, d, [ctrl]} -> eof;
                _ -> input_loop(State, Width)
            end
    end.

render_input(State, Width) ->
    io:put_chars(["\r", etui_input:render(State, Width)]).

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
    ["\e[38;5;51m", lists:duplicate(Width, $-), "\e[39m"].

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
    io:put_chars(["\e[2K\r  \e[38;5;51m", Frame, "\e[39m \e[2m", Msg, "\e[22m"]),
    receive
        stop -> Parent ! {spin_done, Ref};
        pause ->
            Parent ! {paused, Ref},
            receive resume -> ok end,
            spin_loop(Msg, Idx, Parent, Ref)
    after 80 ->
        spin_loop(Msg, Idx + 1, Parent, Ref)
    end.
