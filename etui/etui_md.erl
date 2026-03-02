-module(etui_md).
-export([render/2, render/3]).

%% Default theme
-define(THEME, #{
    heading => fun(T) -> etui_style:bold(etui_style:underline(T)) end,
    heading2 => fun(T) -> etui_style:bold(T) end,
    heading3 => fun(T) -> etui_style:bold(T) end,
    code_border => fun(T) -> etui_style:dim(T) end,
    code_text => fun(T) -> T end,
    quote_border => fun(T) -> etui_style:dim(T) end,
    quote_text => fun(T) -> etui_style:italic(T) end,
    list_bullet => fun(T) -> etui_style:dim(T) end,
    hr => fun(T) -> etui_style:dim(T) end,
    link_url => fun(T) -> etui_style:dim(etui_style:underline(T)) end,
    table_border => fun(T) -> etui_style:dim(T) end
}).

render(Text, Width) -> render(Text, Width, ?THEME).

render(Text, Width, Theme) when is_binary(Text) ->
    render(binary_to_list(Text), Width, Theme);
render(Text, Width, Theme) ->
    Lines = string:split(Text, "\n", all),
    {Rendered, _} = render_lines(Lines, Width, Theme, []),
    [lists:flatten(L) || L <- Rendered].

render_lines([], _Width, _Theme, Acc) ->
    {lists:reverse(Acc), normal};
render_lines(Lines, Width, Theme, Acc) ->
    case Lines of
        [] -> {lists:reverse(Acc), normal};
        [Line | Rest] ->
            case classify_line(Line) of
                {heading, Level, Content} ->
                    Styled = render_heading(Content, Level, Width, Theme),
                    %% Add blank line after heading unless next is blank
                    Styled2 = case Rest of
                        [] -> Styled;
                        ["" | _] -> Styled;
                        _ -> Styled ++ [""]
                    end,
                    render_lines(Rest, Width, Theme, lists:reverse(Styled2) ++ Acc);

                {code_fence, Lang} ->
                    {CodeLines, Rest2} = collect_code_block(Rest, []),
                    Styled = render_code_block(CodeLines, Lang, Width, Theme),
                    Styled2 = case Rest2 of
                        [] -> Styled;
                        ["" | _] -> Styled;
                        _ -> Styled ++ [""]
                    end,
                    render_lines(Rest2, Width, Theme, lists:reverse(Styled2) ++ Acc);

                {blockquote, Content} ->
                    %% Collect consecutive blockquote lines
                    {QLines, Rest2} = collect_blockquotes([Content], Rest),
                    Styled = render_blockquote(QLines, Width, Theme),
                    render_lines(Rest2, Width, Theme, lists:reverse(Styled) ++ Acc);

                {list_item, Bullet, Content} ->
                    {Items, Rest2} = collect_list_items([{Bullet, Content}], Rest),
                    Styled = render_list(Items, Width, Theme),
                    Styled2 = case Rest2 of
                        [] -> Styled;
                        ["" | _] -> Styled;
                        _ -> Styled ++ [""]
                    end,
                    render_lines(Rest2, Width, Theme, lists:reverse(Styled2) ++ Acc);

                hr ->
                    HrW = min(Width, 80),
                    HrLine = apply_theme(Theme, hr, lists:duplicate(HrW, $─)),
                    render_lines(Rest, Width, Theme, [lists:flatten(HrLine) | Acc]);

                blank ->
                    render_lines(Rest, Width, Theme, ["" | Acc]);

                {table_row, _Cells} ->
                    {TableRows, Rest2} = collect_table_rows([Line | Rest]),
                    Styled = render_table(TableRows, Width, Theme),
                    render_lines(Rest2, Width, Theme, lists:reverse(Styled) ++ Acc);

                paragraph ->
                    Inline = render_inline(Line, Theme),
                    Wrapped = etui_text:wrap(lists:flatten(Inline), Width),
                    %% Add blank line after paragraph unless next is blank or list
                    Wrapped2 = case Rest of
                        [] -> Wrapped;
                        ["" | _] -> Wrapped;
                        _ -> Wrapped ++ [""]
                    end,
                    render_lines(Rest, Width, Theme, lists:reverse(Wrapped2) ++ Acc)
            end
    end.

%% Classify a line
classify_line(Line) when is_binary(Line) ->
    classify_line(binary_to_list(Line));
classify_line([]) -> blank;
classify_line("---" ++ _) ->
    case lists:all(fun(C) -> C == $- orelse C == $\s end, "---") of
        true -> hr;
        false -> paragraph
    end;
classify_line("***" ++ _) -> hr;
classify_line("___" ++ _) -> hr;
classify_line("```" ++ Lang) -> {code_fence, string:trim(Lang)};
classify_line("~~~" ++ Lang) -> {code_fence, string:trim(Lang)};
classify_line("> " ++ Content) -> {blockquote, Content};
classify_line(">" ++ Content) -> {blockquote, Content};
classify_line("# " ++ Content) -> {heading, 1, Content};
classify_line("## " ++ Content) -> {heading, 2, Content};
classify_line("### " ++ Content) -> {heading, 3, Content};
classify_line("#### " ++ Content) -> {heading, 4, Content};
classify_line("##### " ++ Content) -> {heading, 5, Content};
classify_line("###### " ++ Content) -> {heading, 6, Content};
classify_line("- " ++ Content) -> {list_item, "- ", Content};
classify_line("* " ++ Content) -> {list_item, "* ", Content};
classify_line("+ " ++ Content) -> {list_item, "+ ", Content};
classify_line("|" ++ _ = Line) ->
    case string:find(Line, "|", trailing) of
        nomatch -> paragraph;
        _ -> {table_row, split_table_cells(Line)}
    end;
classify_line(Line) ->
    %% Check for ordered list: "1. ", "2. ", etc.
    case re:run(Line, "^([0-9]+)\\. (.*)$", [{capture, all_but_first, list}]) of
        {match, [Num, Content]} ->
            {list_item, Num ++ ". ", Content};
        nomatch ->
            %% Check indented list
            case re:run(Line, "^(\\s+)([-*+]) (.*)$", [{capture, all_but_first, list}]) of
                {match, [Indent, Bullet, Content]} ->
                    {list_item, Indent ++ Bullet ++ " ", Content};
                nomatch ->
                    case re:run(Line, "^(\\s+)([0-9]+)\\. (.*)$", [{capture, all_but_first, list}]) of
                        {match, [Indent, Num, Content]} ->
                            {list_item, Indent ++ Num ++ ". ", Content};
                        nomatch ->
                            paragraph
                    end
            end
    end.

%% Heading rendering
render_heading(Content, 1, Width, Theme) ->
    Styled = apply_theme(Theme, heading, render_inline(Content, Theme)),
    etui_text:wrap(lists:flatten(Styled), Width);
render_heading(Content, 2, Width, Theme) ->
    Styled = apply_theme(Theme, heading2, render_inline(Content, Theme)),
    etui_text:wrap(lists:flatten(Styled), Width);
render_heading(Content, Level, Width, Theme) ->
    Prefix = lists:duplicate(Level, $#) ++ " ",
    Styled = apply_theme(Theme, heading3, [Prefix | render_inline(Content, Theme)]),
    etui_text:wrap(lists:flatten(Styled), Width).

%% Code block
collect_code_block([], Acc) -> {lists:reverse(Acc), []};
collect_code_block(["```" ++ _ | Rest], Acc) -> {lists:reverse(Acc), Rest};
collect_code_block(["~~~" ++ _ | Rest], Acc) -> {lists:reverse(Acc), Rest};
collect_code_block([Line | Rest], Acc) ->
    collect_code_block(Rest, [Line | Acc]).

render_code_block(Lines, _Lang, Width, Theme) ->
    ContentW = Width - 4, % 2 char indent each side
    Border = apply_theme(Theme, code_border, lists:duplicate(min(Width, 80), $─)),
    Top = lists:flatten(Border),
    Bot = Top,
    CodeLines = lists:map(fun(L) ->
        Padded = etui_text:pad("  " ++ L, ContentW + 2),
        lists:flatten(apply_theme(Theme, code_text, Padded))
    end, Lines),
    [Top] ++ CodeLines ++ [Bot].

%% Blockquote
collect_blockquotes(Acc, []) -> {lists:reverse(Acc), []};
collect_blockquotes(Acc, ["> " ++ C | Rest]) ->
    collect_blockquotes([C | Acc], Rest);
collect_blockquotes(Acc, [">" ++ C | Rest]) ->
    collect_blockquotes([C | Acc], Rest);
collect_blockquotes(Acc, Rest) ->
    {lists:reverse(Acc), Rest}.

render_blockquote(Lines, Width, Theme) ->
    ContentW = Width - 3, % "│ " prefix + 1
    Border = lists:flatten(apply_theme(Theme, quote_border, "│ ")),
    lists:flatmap(fun(L) ->
        Styled = apply_theme(Theme, quote_text, render_inline(L, Theme)),
        Wrapped = etui_text:wrap(lists:flatten(Styled), ContentW),
        [Border ++ W || W <- Wrapped]
    end, Lines).

%% Lists
collect_list_items(Acc, []) -> {lists:reverse(Acc), []};
collect_list_items(Acc, [Line | Rest]) ->
    case classify_line(Line) of
        {list_item, B, C} ->
            collect_list_items([{B, C} | Acc], Rest);
        blank ->
            %% Check if next line continues the list
            case Rest of
                [Next | _] ->
                    case classify_line(Next) of
                        {list_item, _, _} ->
                            collect_list_items(Acc, Rest);
                        _ -> {lists:reverse(Acc), [Line | Rest]}
                    end;
                [] -> {lists:reverse(Acc), []}
            end;
        _ ->
            {lists:reverse(Acc), [Line | Rest]}
    end.

render_list(Items, Width, Theme) ->
    lists:flatmap(fun({Bullet, Content}) ->
        %% Determine indent from bullet
        Indent = case re:run(Bullet, "^(\\s*)", [{capture, first, list}]) of
            {match, [Spaces]} -> length(Spaces);
            nomatch -> 0
        end,
        BulletStr = case re:run(Bullet, "[0-9]+\\.", [{capture, first, list}]) of
            {match, [NumDot]} ->
                lists:duplicate(Indent, $\s) ++ NumDot ++ " ";
            nomatch ->
                lists:duplicate(Indent, $\s) ++ "- "
        end,
        StyledBullet = lists:flatten(apply_theme(Theme, list_bullet, BulletStr)),
        BulletW = etui_text:visible_width(StyledBullet),
        ContentW = Width - BulletW,
        Inline = render_inline(Content, Theme),
        Wrapped = etui_text:wrap(lists:flatten(Inline), max(10, ContentW)),
        case Wrapped of
            [] -> [StyledBullet];
            [First | Rest2] ->
                [StyledBullet ++ First |
                 [lists:duplicate(BulletW, $\s) ++ R || R <- Rest2]]
        end
    end, Items).

%% Table
split_table_cells(Line) ->
    %% Strip leading/trailing pipes and split
    Trimmed = string:trim(Line),
    NoPipes = case Trimmed of
        [$| | R] ->
            case lists:reverse(R) of
                [$| | R2] -> lists:reverse(R2);
                _ -> R
            end;
        _ -> Trimmed
    end,
    [string:trim(C) || C <- string:split(NoPipes, "|", all)].

collect_table_rows([]) -> {[], []};
collect_table_rows([Line | Rest]) ->
    case classify_line(Line) of
        {table_row, Cells} ->
            {MoreRows, Rest2} = collect_table_rows(Rest),
            {[Cells | MoreRows], Rest2};
        _ ->
            {[], [Line | Rest]}
    end.

is_separator_row(Cells) ->
    lists:all(fun(C) ->
        Trimmed = string:trim(C),
        case re:run(Trimmed, "^:?-+:?$") of
            {match, _} -> true;
            nomatch -> Trimmed == ""
        end
    end, Cells).

render_table([], _Width, _Theme) -> [];
render_table(Rows, Width, Theme) ->
    %% Filter out separator rows
    DataRows = lists:filter(fun(R) -> not is_separator_row(R) end, Rows),
    case DataRows of
        [] -> [];
        _ ->
            %% Calculate column widths
            NumCols = lists:max([length(R) || R <- DataRows]),
            %% Pad rows to same number of columns
            PaddedRows = [R ++ lists:duplicate(max(0, NumCols - length(R)), "") || R <- DataRows],
            %% Get natural widths
            ColWidths = lists:map(fun(ColIdx) ->
                lists:max([etui_text:visible_width(lists:nth(ColIdx, R)) || R <- PaddedRows])
            end, lists:seq(1, NumCols)),
            %% Adjust to fit width (borders: │ between cols + edges = NumCols + 1)
            TotalBorders = NumCols + 1,
            TotalPadding = NumCols * 2, % 1 space padding each side
            Available = Width - TotalBorders - TotalPadding,
            TotalNatural = lists:sum(ColWidths),
            AdjWidths = if
                TotalNatural =< Available -> ColWidths;
                true ->
                    %% Proportional shrink
                    [max(3, round(W * Available / max(1, TotalNatural))) || W <- ColWidths]
            end,
            %% Render
            B = fun(T) -> lists:flatten(apply_theme(Theme, table_border, T)) end,
            TopBorder = B(["┌"] ++ lists:join("┬", [lists:duplicate(W + 2, $─) || W <- AdjWidths]) ++ ["┐"]),
            MidBorder = B(["├"] ++ lists:join("┼", [lists:duplicate(W + 2, $─) || W <- AdjWidths]) ++ ["┤"]),
            BotBorder = B(["└"] ++ lists:join("┴", [lists:duplicate(W + 2, $─) || W <- AdjWidths]) ++ ["┘"]),
            RenderedRows = lists:map(fun(Row) ->
                Cells = lists:zipwith(fun(Cell, MaxW) ->
                    " " ++ etui_text:pad(etui_text:truncate(Cell, MaxW), MaxW) ++ " "
                end, Row, AdjWidths),
                B("│") ++ lists:flatten(lists:join(B("│"), Cells)) ++ B("│")
            end, PaddedRows),
            case RenderedRows of
                [Header | Body] ->
                    [TopBorder, Header, MidBorder] ++ Body ++ [BotBorder];
                _ ->
                    [TopBorder] ++ RenderedRows ++ [BotBorder]
            end
    end.

%% Inline rendering — handles **bold**, *italic*, `code`, ~~strike~~, [links](url)
render_inline(Text, Theme) when is_binary(Text) ->
    render_inline(binary_to_list(Text), Theme);
render_inline(Text, _Theme) ->
    render_inline_scan(Text, []).

render_inline_scan([], Acc) -> lists:reverse(Acc);
%% Bold: **text**
render_inline_scan("**" ++ Rest, Acc) ->
    case string:split(Rest, "**") of
        [Inner, After] ->
            render_inline_scan(After, [etui_style:bold(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, ["**" | Acc])
    end;
%% Bold: __text__
render_inline_scan("__" ++ Rest, Acc) ->
    case string:split(Rest, "__") of
        [Inner, After] ->
            render_inline_scan(After, [etui_style:bold(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, ["__" | Acc])
    end;
%% Strikethrough: ~~text~~
render_inline_scan("~~" ++ Rest, Acc) ->
    case string:split(Rest, "~~") of
        [Inner, After] ->
            render_inline_scan(After, [etui_style:strikethrough(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, ["~~" | Acc])
    end;
%% Inline code: `text`
render_inline_scan([$` | Rest], Acc) ->
    case string:split(Rest, "`") of
        [Inner, After] ->
            render_inline_scan(After, [etui_style:dim(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, [$` | Acc])
    end;
%% Link: [text](url)
render_inline_scan([$[ | Rest], Acc) ->
    case parse_link(Rest) of
        {LinkText, Url, After} ->
            Styled = [etui_style:underline(LinkText), " (", etui_style:dim(Url), ")"],
            render_inline_scan(After, [Styled | Acc]);
        none ->
            render_inline_scan(Rest, [$[ | Acc])
    end;
%% Italic: *text* (single, not **)
render_inline_scan([$* | Rest], Acc) ->
    case string:split(Rest, "*") of
        [Inner, After] when Inner =/= "" ->
            render_inline_scan(After, [etui_style:italic(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, [$* | Acc])
    end;
%% Italic: _text_ (single, not __)
render_inline_scan([$_ | Rest], Acc) ->
    case string:split(Rest, "_") of
        [Inner, After] when Inner =/= "" ->
            render_inline_scan(After, [etui_style:italic(Inner) | Acc]);
        _ ->
            render_inline_scan(Rest, [$_ | Acc])
    end;
%% Regular character
render_inline_scan([C | Rest], Acc) ->
    %% Accumulate consecutive plain chars
    {Plain, Rest2} = collect_plain([C | Rest]),
    render_inline_scan(Rest2, [Plain | Acc]).

collect_plain([]) -> {[], []};
collect_plain([$* | _] = S) -> {[], S};
collect_plain([$_ | _] = S) -> {[], S};
collect_plain([$` | _] = S) -> {[], S};
collect_plain([$~ | _] = S) -> {[], S};
collect_plain([$[ | _] = S) -> {[], S};
collect_plain([C | Rest]) ->
    {More, Rest2} = collect_plain(Rest),
    {[C | More], Rest2}.

parse_link(Str) ->
    case string:split(Str, "](") of
        [LinkText, Rest] ->
            case string:split(Rest, ")") of
                [Url, After] -> {LinkText, Url, After};
                _ -> none
            end;
        _ -> none
    end.

%% Apply a theme function
apply_theme(Theme, Key, Text) ->
    case maps:get(Key, Theme, none) of
        none -> Text;
        Fun when is_function(Fun, 1) -> Fun(Text)
    end.
