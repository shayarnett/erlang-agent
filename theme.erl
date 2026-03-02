-module(theme).
-export([get/0, set/1, list/0, apply/0]).
-export([fg/1, bg/1, fg_bg/2, line/1, prompt/0]).

%% Theme is a map of semantic roles -> 256-color codes.
%% Stored in process dict so each TUI process has its own theme.

-spec get() -> map().
get() ->
    case erlang:get(theme) of
        undefined -> synthwave();
        T -> T
    end.

-spec set(atom() | map()) -> ok.
set(Name) when is_atom(Name) ->
    set(theme_by_name(Name));
set(Theme) when is_map(Theme) ->
    erlang:put(theme, Theme),
    ok.

-spec list() -> [{atom(), string()}].
list() ->
    [{synthwave, "Neon cyberpunk"},
     {mono,      "Monochrome"},
     {dracula,   "Dracula dark"},
     {solarized, "Solarized dark"}].

%% Re-render with current theme (for theme switching)
apply() ->
    ok.

%%--------------------------------------------------------------------
%% Color helpers — read from current theme
%%--------------------------------------------------------------------

%% Foreground color escape for a semantic role
fg(Role) ->
    C = maps:get(Role, ?MODULE:get()),
    "\e[38;5;" ++ integer_to_list(C) ++ "m".

%% Background color escape for a semantic role
bg(Role) ->
    C = maps:get(Role, ?MODULE:get()),
    "\e[48;5;" ++ integer_to_list(C) ++ "m".

%% Both fg and bg
fg_bg(FgRole, BgRole) ->
    [bg(BgRole), fg(FgRole)].

%% Full-width separator line in accent color
line(Width) ->
    [fg(accent), lists:duplicate(Width, $-), "\e[39m"].

%% Prompt chevron
prompt() ->
    [fg(prompt_icon), ">", "\e[39m "].

%%--------------------------------------------------------------------
%% Built-in themes
%%--------------------------------------------------------------------

theme_by_name(synthwave) -> synthwave();
theme_by_name(mono) -> mono();
theme_by_name(dracula) -> dracula();
theme_by_name(solarized) -> solarized();
theme_by_name(_) -> synthwave().

synthwave() -> #{
    %% Accent / chrome
    accent      => 51,   %% electric cyan
    prompt_icon => 213,  %% hot pink
    dim_text    => 245,  %% grey for dim/secondary
    success     => 87,   %% neon green
    error       => 203,  %% neon red
    stats       => 141,  %% lavender

    %% User message
    user_bg     => 53,   %% deep magenta

    %% Tool: exec
    exec_bg     => 17,   %% deep navy
    exec_fg     => 117,  %% light blue

    %% Tool: file ops
    file_bg     => 54,   %% deep purple
    file_fg     => 183,  %% light purple

    %% Tool: load_module
    module_bg   => 90,   %% dark magenta
    module_fg   => 213,  %% hot pink

    %% Tool: fallback / generic
    tool_bg     => 236,  %% dark grey
    tool_fg     => 250,  %% light grey

    %% Footer
    footer_bg   => 236,  %% dark grey
    footer_fg   => 51    %% cyan
}.

mono() -> #{
    accent      => 255,
    prompt_icon => 255,
    dim_text    => 245,
    success     => 255,
    error       => 196,
    stats       => 245,

    user_bg     => 236,
    exec_bg     => 233,
    exec_fg     => 250,
    file_bg     => 233,
    file_fg     => 250,
    module_bg   => 233,
    module_fg   => 255,
    tool_bg     => 233,
    tool_fg     => 250,
    footer_bg   => 235,
    footer_fg   => 255
}.

dracula() -> #{
    accent      => 141,  %% purple
    prompt_icon => 212,  %% pink
    dim_text    => 103,  %% comment grey
    success     => 84,   %% green
    error       => 210,  %% red/orange
    stats       => 117,  %% cyan

    user_bg     => 60,   %% muted purple
    exec_bg     => 236,  %% dark bg
    exec_fg     => 84,   %% green
    file_bg     => 236,
    file_fg     => 228,  %% yellow
    module_bg   => 236,
    module_fg   => 212,  %% pink
    tool_bg     => 236,
    tool_fg     => 253,
    footer_bg   => 235,
    footer_fg   => 141   %% purple
}.

solarized() -> #{
    accent      => 37,   %% cyan
    prompt_icon => 136,  %% yellow
    dim_text    => 246,  %% base1
    success     => 64,   %% green
    error       => 160,  %% red
    stats       => 33,   %% blue

    user_bg     => 236,  %% base02
    exec_bg     => 234,  %% base03
    exec_fg     => 37,   %% cyan
    file_bg     => 234,
    file_fg     => 136,  %% yellow
    module_bg   => 234,
    module_fg   => 125,  %% magenta
    tool_bg     => 234,
    tool_fg     => 246,
    footer_bg   => 235,
    footer_fg   => 37    %% cyan
}.
