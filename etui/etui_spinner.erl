-module(etui_spinner).
-export([
    start/1,
    stop/1,
    set_message/2
]).

-define(FRAMES, [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
]).
-define(INTERVAL, 80).

start(Message) ->
    Pid = spawn_link(fun() -> spinner_loop(Message, 0) end),
    Pid.

stop(Pid) ->
    Pid ! stop,
    %% Clear the spinner line
    etui_term:write("\e[2K\r"),
    ok.

set_message(Pid, Message) ->
    Pid ! {set_message, Message},
    ok.

spinner_loop(Message, FrameIdx) ->
    Frame = lists:nth((FrameIdx rem length(?FRAMES)) + 1, ?FRAMES),
    etui_term:write(["\e[2K\r", Frame, " ", Message]),
    receive
        stop -> ok;
        {set_message, NewMsg} ->
            spinner_loop(NewMsg, FrameIdx + 1)
    after ?INTERVAL ->
        spinner_loop(Message, FrameIdx + 1)
    end.
