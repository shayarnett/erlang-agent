-module(etui_panel).
-export([
    start/0, stop/0,
    set/2, set/3, set/4,
    remove/1,
    render/1,
    list/0,
    clear/0
]).

%% A panel manages a set of named status widgets.
%% Widgets with the same group are rendered side-by-side as colored blocks.
%%
%% Usage:
%%   etui_panel:start().
%%   etui_panel:set(build, "compiling...").
%%   etui_panel:set(cat, fun(W) -> Lines end, 20, #{group => pets}).
%%   Lines = etui_panel:render(80).

-record(widget, {
    id       :: atom(),
    content  :: binary() | string() | fun((integer()) -> [string()]),
    priority :: integer(),
    group    :: atom() | undefined
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start() ->
    case whereis(etui_panel) of
        undefined ->
            Pid = spawn_link(fun() -> loop(#{}) end),
            register(etui_panel, Pid),
            ok;
        _ -> ok
    end.

stop() ->
    case whereis(etui_panel) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

set(Id, Content) -> set(Id, Content, 50).
set(Id, Content, Priority) -> set(Id, Content, Priority, #{}).
set(Id, Content, Priority, Opts) ->
    Group = maps:get(group, Opts, undefined),
    call({set, Id, Content, Priority, Group}).

remove(Id) -> call({remove, Id}).
render(Width) -> call({render, Width}).
list() -> call(list).
clear() -> call(clear).

%%--------------------------------------------------------------------
%% Internal process
%%--------------------------------------------------------------------

call(Msg) ->
    case whereis(etui_panel) of
        undefined -> [];
        Pid ->
            Ref = make_ref(),
            Pid ! {call, self(), Ref, Msg},
            receive {reply, Ref, Result} -> Result
            after 1000 -> []
            end
    end.

loop(Widgets) ->
    receive
        {call, From, Ref, Msg} ->
            {Reply, Widgets2} = handle(Msg, Widgets),
            From ! {reply, Ref, Reply},
            loop(Widgets2);
        stop ->
            ok;
        _ ->
            loop(Widgets)
    end.

handle({set, Id, Content, Priority, Group}, Widgets) ->
    W = #widget{id = Id, content = Content, priority = Priority, group = Group},
    {ok, maps:put(Id, W, Widgets)};

handle({remove, Id}, Widgets) ->
    {ok, maps:remove(Id, Widgets)};

handle({render, Width}, Widgets) ->
    Sorted = lists:sort(fun(#widget{priority = A}, #widget{priority = B}) -> A =< B end,
                        maps:values(Widgets)),
    %% Partition into grouped and ungrouped
    {Grouped, Ungrouped} = lists:partition(
        fun(#widget{group = G}) -> G =/= undefined end, Sorted),
    GroupMap = lists:foldl(fun(#widget{group = G} = W, Acc) ->
        maps:update_with(G, fun(Ws) -> Ws ++ [W] end, [W], Acc)
    end, #{}, Grouped),
    %% Build render entries sorted by priority
    GroupEntries = maps:fold(fun(Name, Ws, Acc) ->
        MinPri = lists:min([P || #widget{priority = P} <- Ws]),
        [{MinPri, {group, Name, Ws}} | Acc]
    end, [], GroupMap),
    UngroupedEntries = [{P, {single, W}} || #widget{priority = P} = W <- Ungrouped],
    AllEntries = lists:sort(fun({A,_}, {B,_}) -> A =< B end,
                            GroupEntries ++ UngroupedEntries),
    Lines = lists:flatmap(fun({_Pri, Entry}) ->
        case Entry of
            {single, W} -> render_widget(W#widget.id, W#widget.content, Width);
            {group, _Name, Ws} -> render_box_grid(Ws, Width)
        end
    end, AllEntries),
    {Lines, Widgets};

handle(list, Widgets) ->
    Ids = [Id || #widget{id = Id} <- maps:values(Widgets)],
    {Ids, Widgets};

handle(clear, _Widgets) ->
    {ok, #{}}.

%%--------------------------------------------------------------------
%% Regular widget rendering (ungrouped)
%% Lines include their own ANSI styling.
%%--------------------------------------------------------------------

render_widget(_Id, Content, Width) when is_function(Content, 1) ->
    try Content(Width)
    catch _:_ -> []
    end;
render_widget(Id, Content, Width) when is_binary(Content) ->
    render_widget(Id, binary_to_list(Content), Width);
render_widget(Id, Content, _Width) when is_list(Content) ->
    Label = atom_to_list(Id),
    Line = lists:flatten([
        "  \e[2m", Label, "\e[22m",
        "  ",
        Content
    ]),
    [Line].

%%--------------------------------------------------------------------
%% Box grid rendering (grouped widgets as colored blocks)
%%
%% Each box is a solid colored block with:
%%   - 1-char wide colored left accent bar
%%   - Dark background fill
%%   - Bold title on first line
%%   - Content lines below
%%   - Gaps between boxes (no background)
%%--------------------------------------------------------------------

render_box_grid(Widgets, TotalWidth) ->
    N = length(Widgets),
    Gap = 1,
    MaxBoxW = 36,
    BoxW = min(MaxBoxW, max(14, (TotalWidth - 2 - (N - 1) * Gap) div N)),
    InnerW = BoxW - 2, %% accent bar(1) + leading space(1)
    %% Get content for each widget
    Contents = lists:map(fun(#widget{id = Id, content = Content}) ->
        Raw = get_content_lines(Content, InnerW),
        {atom_to_list(Id), Raw}
    end, Widgets),
    %% Normalize height
    MaxH = case Contents of
        [] -> 0;
        _ -> lists:max([length(Ls) || {_, Ls} <- Contents])
    end,
    %% Build each box with colors
    AccentBgs = accent_bg_colors(),
    AccentFgs = accent_fg_colors(),
    NumColors = length(AccentBgs),
    BoxBg = "\e[48;5;235m",
    ContentFg = "\e[38;5;250m",
    Boxes = lists:map(fun({Idx, {Title, Lines0}}) ->
        Lines = Lines0 ++ lists:duplicate(max(0, MaxH - length(Lines0)), ""),
        CI = ((Idx - 1) rem NumColors) + 1,
        ABg = lists:nth(CI, AccentBgs),
        AFg = lists:nth(CI, AccentFgs),
        build_colored_box(Title, Lines, InnerW, BoxBg, ABg, AFg, ContentFg)
    end, lists:zip(lists:seq(1, length(Contents)), Contents)),
    %% Merge horizontally with gaps
    merge_horizontal(Boxes, Gap, BoxW).

get_content_lines(Content, Width) when is_function(Content, 1) ->
    try Content(Width)
    catch _:_ -> []
    end;
get_content_lines(Content, _Width) when is_binary(Content) ->
    [binary_to_list(Content)];
get_content_lines(Content, _Width) when is_list(Content) ->
    [Content].

build_colored_box(Title, Lines, InnerW, BoxBg, AccentBg, AccentFg, ContentFg) ->
    %% Title line: accent bar + bold title
    TitlePad = max(0, InnerW - length(Title)),
    TitleLine = lists:flatten([
        AccentBg, " ",
        BoxBg, AccentFg, "\e[1m ", Title, "\e[22m",
        lists:duplicate(TitlePad, $\s),
        "\e[39m\e[49m"
    ]),
    %% Content lines: accent bar + content
    Middle = lists:map(fun(Line) ->
        Flat = lists:flatten(Line),
        Visible = length(Flat),
        {Clipped, Vis} = case Visible > InnerW of
            true -> {lists:sublist(Flat, InnerW), InnerW};
            false -> {Flat, Visible}
        end,
        Pad = max(0, InnerW - Vis),
        lists:flatten([
            AccentBg, " ",
            BoxBg, ContentFg, " ", Clipped,
            lists:duplicate(Pad, $\s),
            "\e[39m\e[49m"
        ])
    end, Lines),
    [TitleLine | Middle].

merge_horizontal([], _Gap, _BoxW) -> [];
merge_horizontal([Single], _Gap, _BoxW) -> Single;
merge_horizontal(Boxes, Gap, BoxW) ->
    MaxH = lists:max([length(B) || B <- Boxes]),
    GapStr = lists:duplicate(Gap, $\s),
    EmptyBox = lists:duplicate(BoxW, $\s),
    lists:map(fun(Row) ->
        Parts = lists:map(fun(Box) ->
            case Row =< length(Box) of
                true -> lists:nth(Row, Box);
                false -> EmptyBox
            end
        end, Boxes),
        lists:flatten(lists:join(GapStr, Parts))
    end, lists:seq(1, MaxH)).

%%--------------------------------------------------------------------
%% Box accent colors (256-color palette, works on dark backgrounds)
%%--------------------------------------------------------------------

accent_bg_colors() ->
    ["\e[48;5;51m",   %% cyan
     "\e[48;5;213m",  %% pink
     "\e[48;5;87m",   %% green
     "\e[48;5;141m",  %% lavender
     "\e[48;5;203m",  %% red
     "\e[48;5;117m"]. %% light blue

accent_fg_colors() ->
    ["\e[38;5;51m",   %% cyan
     "\e[38;5;213m",  %% pink
     "\e[38;5;87m",   %% green
     "\e[38;5;141m",  %% lavender
     "\e[38;5;203m",  %% red
     "\e[38;5;117m"]. %% light blue
