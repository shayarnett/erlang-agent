-module(etui_term).
-export([
    start/2,
    stop/0,
    write/1,
    columns/0,
    rows/0,
    hide_cursor/0,
    show_cursor/0,
    clear_screen/0,
    clear_line/0,
    move_up/1,
    move_down/1,
    move_to_col/1,
    set_title/1,
    sync_start/0,
    sync_end/0
]).

%% Start terminal in raw mode. OnInput(Data) called for each input chunk,
%% OnResize({Cols, Rows}) called on dimension changes.
start(OnInput, OnResize) ->
    %% Save current tty settings
    OldStty = os:cmd("stty -g < /dev/tty"),
    %% Set raw mode
    os:cmd("stty raw -echo < /dev/tty"),
    %% Enable bracketed paste
    write("\e[?2004h"),
    %% Hide cursor initially
    hide_cursor(),

    %% Store state in process dictionary of a registered process
    ReaderPid = spawn_link(fun() -> reader_loop(OnInput) end),
    DimPid = spawn_link(fun() ->
        {C, R} = get_dimensions(),
        dim_poll_loop(OnResize, C, R)
    end),

    register(etui_term_state, spawn_link(fun() ->
        term_state_loop(#{
            reader => ReaderPid,
            dim_poller => DimPid,
            old_stty => string:trim(OldStty)
        })
    end)),
    ok.

stop() ->
    case whereis(etui_term_state) of
        undefined -> ok;
        Pid ->
            Pid ! {get_state, self()},
            receive
                {state, State} ->
                    %% Kill reader and poller
                    catch exit(maps:get(reader, State), kill),
                    catch exit(maps:get(dim_poller, State), kill),
                    %% Disable bracketed paste
                    write("\e[?2004l"),
                    %% Show cursor
                    show_cursor(),
                    %% Restore terminal
                    OldStty = maps:get(old_stty, State),
                    os:cmd("stty " ++ OldStty ++ " < /dev/tty"),
                    Pid ! stop,
                    ok
            after 1000 -> ok
            end
    end.

term_state_loop(State) ->
    receive
        {get_state, From} ->
            From ! {state, State},
            term_state_loop(State);
        stop -> ok
    end.

%% Read from /dev/tty in a loop
reader_loop(OnInput) ->
    case file:open("/dev/tty", [read, raw, binary]) of
        {ok, Fd} ->
            reader_read_loop(Fd, OnInput);
        {error, _} ->
            %% Fallback: use standard_io
            reader_stdin_loop(OnInput)
    end.

reader_read_loop(Fd, OnInput) ->
    case file:read(Fd, 256) of
        {ok, Data} ->
            OnInput(Data),
            reader_read_loop(Fd, OnInput);
        {error, _} ->
            timer:sleep(50),
            reader_read_loop(Fd, OnInput)
    end.

reader_stdin_loop(OnInput) ->
    case io:get_chars(standard_io, "", 1) of
        eof -> ok;
        {error, _} ->
            timer:sleep(50),
            reader_stdin_loop(OnInput);
        Data ->
            %% Try to read more if available (batch)
            OnInput(Data),
            reader_stdin_loop(OnInput)
    end.

%% Poll for dimension changes every 500ms
dim_poll_loop(OnResize, LastC, LastR) ->
    timer:sleep(500),
    {C, R} = get_dimensions(),
    case {C, R} of
        {LastC, LastR} -> dim_poll_loop(OnResize, LastC, LastR);
        _ ->
            OnResize({C, R}),
            dim_poll_loop(OnResize, C, R)
    end.

get_dimensions() ->
    C = case io:columns() of
        {ok, Cols} -> Cols;
        _ -> 80
    end,
    R = case io:rows() of
        {ok, Rows} -> Rows;
        _ -> 24
    end,
    {C, R}.

write(Data) ->
    io:put_chars(standard_io, Data).

columns() ->
    case io:columns() of
        {ok, C} -> C;
        _ -> 80
    end.

rows() ->
    case io:rows() of
        {ok, R} -> R;
        _ -> 24
    end.

hide_cursor() -> write("\e[?25l").
show_cursor() -> write("\e[?25h").
clear_screen() -> write("\e[2J\e[H").
clear_line() -> write("\e[2K\r").
move_up(0) -> ok;
move_up(N) -> write(["\e[", integer_to_list(N), $A]).
move_down(0) -> ok;
move_down(N) -> write(["\e[", integer_to_list(N), $B]).
move_to_col(N) -> write(["\e[", integer_to_list(N), $G]).

set_title(Title) ->
    write(["\e]0;", Title, "\007"]).

%% Synchronized output (DEC private mode 2026)
sync_start() -> write("\e[?2026h").
sync_end() -> write("\e[?2026l").
