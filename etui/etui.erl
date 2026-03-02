-module(etui).
-export([
    start/0,
    stop/1,
    render/2,
    write_lines/1,
    clear_and_write/2
]).

%% Start the TUI — returns state map.
%% Caller should set up etui_term:start/2 first.
start() ->
    etui_term:hide_cursor(),
    #{last_line_count => 0}.

stop(#{}) ->
    etui_term:show_cursor(),
    etui_term:write("\n"),
    ok.

%% Render a list of lines, clearing previous output first.
%% Returns updated state with new line count.
render(Lines, #{last_line_count := LastCount} = State) ->
    etui_term:sync_start(),
    %% Move up to clear previous output
    if LastCount > 0 ->
        etui_term:move_up(LastCount),
        etui_term:write("\r");
    true -> ok
    end,
    %% Write each line, clearing to end of line
    lists:foreach(fun(Line) ->
        etui_term:write(["\e[2K", Line, "\n"])
    end, Lines),
    %% Clear any leftover lines from previous render
    NewCount = length(Lines),
    if NewCount < LastCount ->
        lists:foreach(fun(_) ->
            etui_term:write("\e[2K\n")
        end, lists:seq(1, LastCount - NewCount)),
        etui_term:move_up(LastCount - NewCount);
    true -> ok
    end,
    etui_term:sync_end(),
    State#{last_line_count => NewCount}.

%% Simple line writing (append mode, no clear)
write_lines(Lines) ->
    lists:foreach(fun(Line) ->
        etui_term:write([Line, "\n"])
    end, Lines).

%% Clear screen and write lines from top
clear_and_write(Lines, State) ->
    etui_term:clear_screen(),
    write_lines(Lines),
    State#{last_line_count => length(Lines)}.
