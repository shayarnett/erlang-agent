-module(widgets).
-export([
    uptime/0, uptime/1,
    sysinfo/0, sysinfo/1,
    tokens/0, tokens/1,
    ticker/1, ticker/2,
    stop/1, stop_all/0
]).

%% Example widgets for the etui_panel system.
%% Each widget runs as a background process that updates the panel.
%%
%% Usage:
%%   widgets:uptime().         %% show session uptime
%%   widgets:sysinfo().        %% show memory/process count
%%   widgets:tokens().         %% track tokens across chats
%%   widgets:ticker(agent1, "researching docs").  %% custom status
%%   widgets:stop(uptime).     %% stop a widget
%%   widgets:stop_all().       %% stop all

%%--------------------------------------------------------------------
%% Uptime — session elapsed time
%%--------------------------------------------------------------------

uptime() -> uptime(#{}).
uptime(Opts) ->
    start_widget(uptime, 90, Opts, fun uptime_loop/2, erlang:monotonic_time(second)).

uptime_loop(T0, _Opts) ->
    Elapsed = erlang:monotonic_time(second) - T0,
    H = Elapsed div 3600,
    M = (Elapsed rem 3600) div 60,
    S = Elapsed rem 60,
    Text = if
        H > 0 -> io_lib:format("~ph ~pm ~ps", [H, M, S]);
        M > 0 -> io_lib:format("~pm ~ps", [M, S]);
        true  -> io_lib:format("~ps", [S])
    end,
    lists:flatten(Text).

%%--------------------------------------------------------------------
%% Sysinfo — memory + process count
%%--------------------------------------------------------------------

sysinfo() -> sysinfo(#{}).
sysinfo(Opts) ->
    start_widget(sysinfo, 80, Opts, fun sysinfo_loop/2, undefined).

sysinfo_loop(_, _Opts) ->
    Mem = erlang:memory(total) div (1024 * 1024),
    Procs = erlang:system_info(process_count),
    lists:flatten(io_lib:format("~pMB  ~p procs", [Mem, Procs])).

%%--------------------------------------------------------------------
%% Tokens — track approximate token usage across chats
%%--------------------------------------------------------------------

tokens() -> tokens(#{}).
tokens(Opts) ->
    start_widget(tokens, 85, Opts, fun tokens_loop/2, {0, 0}).

tokens_loop({Chats, Tokens}, _Opts) ->
    %% Check for new token data from the agent
    {Chats2, Tokens2} = receive
        {chat_done, ReplyBytes} ->
            {Chats + 1, Tokens + (ReplyBytes div 4)}
    after 0 ->
        {Chats, Tokens}
    end,
    put(token_state, {Chats2, Tokens2}),
    lists:flatten(io_lib:format("~p chats  ~~~p tokens", [Chats2, Tokens2])).

%%--------------------------------------------------------------------
%% Ticker — custom named status with animated dots
%%--------------------------------------------------------------------

ticker(Name) -> ticker(Name, #{}).
ticker(Name, Msg) when is_list(Msg); is_binary(Msg) ->
    ticker(Name, #{msg => Msg});
ticker(Name, Opts) ->
    Msg = maps:get(msg, Opts, "working"),
    start_widget(Name, maps:get(priority, Opts, 50), Opts,
                 fun(Tick, O) -> ticker_loop(Tick, O) end, {0, Msg}).

ticker_loop({Tick, Msg}, _Opts) ->
    Dots = lists:duplicate((Tick rem 3) + 1, $.),
    Pad = lists:duplicate(3 - length(Dots), $\s),
    put(ticker_tick, {Tick + 1, Msg}),
    lists:flatten([Msg, Dots, Pad]).

%%--------------------------------------------------------------------
%% Control
%%--------------------------------------------------------------------

stop(Name) ->
    case erlang:get({widget_pid, Name}) of
        undefined ->
            etui_panel:remove(Name);
        Pid ->
            Pid ! stop,
            erlang:erase({widget_pid, Name}),
            etui_panel:remove(Name)
    end,
    ok.

stop_all() ->
    lists:foreach(fun(Id) -> stop(Id) end, etui_panel:list()),
    ok.

%%--------------------------------------------------------------------
%% Internal: generic widget loop
%%--------------------------------------------------------------------

start_widget(Name, Priority, _Opts, RenderFn, InitState) ->
    %% Stop existing widget with this name
    stop(Name),
    Pid = spawn_link(fun() ->
        widget_loop(Name, Priority, RenderFn, InitState, _Opts)
    end),
    erlang:put({widget_pid, Name}, Pid),
    %% Store pid so the widget process can be found
    register(widget_name(Name), Pid),
    ok.

widget_name(Name) ->
    list_to_atom("widget_" ++ atom_to_list(Name)).

widget_loop(Name, Priority, RenderFn, State, Opts) ->
    Text = try RenderFn(State, Opts)
           catch _:_ -> "error"
           end,
    etui_panel:set(Name, Text, Priority),
    receive
        stop -> etui_panel:remove(Name);
        {update_msg, NewMsg} ->
            widget_loop(Name, Priority, RenderFn, {0, NewMsg}, Opts)
    after 1000 ->
        %% Update state for next tick
        NextState = case erlang:get(token_state) of
            undefined ->
                case erlang:get(ticker_tick) of
                    undefined -> State;
                    TS -> TS
                end;
            TS -> TS
        end,
        widget_loop(Name, Priority, RenderFn, NextState, Opts)
    end.
