-module(pets).
-export([fish/0, fish/1, cat/0, cat/1, blob/0, blob/1, snake/0, snake/1]).
-export([stop/1, poke/1]).

%% Animated ASCII pet widgets for the etui_panel system.
%% Pets use fun(Width) -> [Lines] for multi-line rendering.
%%
%% Usage:
%%   pets:fish().            %% fish swims back and forth
%%   pets:cat().             %% cat sleeps, wakes, stretches
%%   pets:blob().            %% tamagotchi blob with moods
%%   pets:snake().           %% snake slithers across
%%   pets:poke(cat).         %% poke a pet (triggers reaction)
%%   pets:stop(fish).        %% remove a pet

%%--------------------------------------------------------------------
%% Fish — swims back and forth (2 lines: water + fish)
%%--------------------------------------------------------------------

fish() -> fish(#{}).
fish(Opts) ->
    Width = maps:get(width, Opts, 16),
    start_pet(fish, #{width => Width, tick => 0, pos => 0, dir => right}).

fish_render(#{width := W, pos := Pos, dir := Dir, tick := T} = St) ->
    FishR = "><(((o>",
    FishL = "<o)))><",
    Bubbles = case T rem 3 of 0 -> "o"; 1 -> " o"; 2 -> "  o" end,
    {Fish, NewPos, NewDir} = case Dir of
        right when Pos >= W - 7 -> {FishL, Pos - 1, left};
        right -> {FishR, Pos + 1, right};
        left when Pos =< 0 -> {FishR, Pos + 1, right};
        left -> {FishL, Pos - 1, left}
    end,
    Pad = lists:duplicate(max(0, NewPos), $\s),
    BubPad = lists:duplicate(max(0, NewPos + 3), $\s),
    Lines = [
        lists:flatten([BubPad, Bubbles]),
        lists:flatten([Pad, Fish])
    ],
    {Lines, St#{pos := NewPos, dir := NewDir, tick := T + 1}}.

%%--------------------------------------------------------------------
%% Cat — sleeps, wakes, stretches, plays (3 lines)
%%--------------------------------------------------------------------

cat() -> cat(#{}).
cat(Opts) ->
    start_pet(cat, Opts#{tick => 0, mood => sleeping, react => none, react_ttl => 0}).

cat_render(#{tick := T, mood := Mood, react := React, react_ttl := TTL} = St) ->
    {Frame, NextMood} = case React of
        poked when TTL > 0 -> {cat_poked(T), Mood};
        _ -> cat_frame(Mood, T)
    end,
    NewTTL = max(0, TTL - 1),
    NewReact = case NewTTL of 0 -> none; _ -> React end,
    {Frame, St#{tick := T + 1, mood := NextMood, react := NewReact, react_ttl := NewTTL}}.

cat_poked(_T) ->
    [" /\\_/\\ ",
     "( >.<)  !!",
     " /    \\ "].

cat_frame(sleeping, T) ->
    Zs = lists:duplicate((T rem 3) + 1, $z),
    {[" /\\_/\\ " ++ Zs,
      "( -.- )",
      " /    \\ "],
     case T rem 20 of 19 -> awake; _ -> sleeping end};
cat_frame(awake, T) ->
    Eyes = case T rem 4 of
        2 -> "( -.- )";  %% blink
        _ -> "( o.o )"
    end,
    Tail = case T rem 4 of 0 -> "~"; _ -> "" end,
    {[" /\\_/\\ ",
      Eyes,
      " /    \\ " ++ Tail],
     case T rem 16 of 15 -> stretching; _ -> awake end};
cat_frame(stretching, T) ->
    Tail = case T rem 2 of 0 -> "~"; 1 -> "~~" end,
    {[" /\\_/\\   " ++ Tail,
      "( ^.^ )>",
      "  \"  \""],
     case T rem 8 of 7 -> playing; _ -> stretching end};
cat_frame(playing, T) ->
    MousePos = 10 + (T rem 4) * 2,
    Mouse = lists:duplicate(MousePos, $\s) ++ "=:3",
    {[" /\\_/\\",
      "( >.> )" ++ Mouse,
      " /    \\"],
     case T rem 12 of 11 -> sleeping; _ -> playing end}.

%%--------------------------------------------------------------------
%% Blob — tamagotchi with moods (3 lines)
%%--------------------------------------------------------------------

blob() -> blob(#{}).
blob(Opts) ->
    start_pet(blob, Opts#{tick => 0, mood => idle, react => none, react_ttl => 0}).

blob_render(#{tick := T, mood := Mood, react := React, react_ttl := TTL} = St) ->
    {Frame, NextMood} = case React of
        poked when TTL > 0 -> {blob_poked(), Mood};
        _ -> blob_frame(Mood, T)
    end,
    NewTTL = max(0, TTL - 1),
    NewReact = case NewTTL of 0 -> none; _ -> React end,
    {Frame, St#{tick := T + 1, mood := NextMood, react := NewReact, react_ttl := NewTTL}}.

blob_poked() ->
    [" .--.  !",
     "( O_O)",
     " `--'"].

blob_frame(idle, T) ->
    Eyes = case T rem 6 of 3 -> "( -_o)"; _ -> "( o_o)" end,
    Bounce = case T rem 4 of 0 -> " "; _ -> "" end,
    {[Bounce ++ " .--.",
      Bounce ++ Eyes,
      Bounce ++ " `--'"],
     case T rem 24 of 23 -> happy; _ -> idle end};
blob_frame(happy, T) ->
    Sparkle = case T rem 3 of 0 -> " *"; 1 -> " +"; 2 -> " ~" end,
    Face = case T rem 2 of 0 -> "( ^_^ )"; 1 -> "( ^-^ )" end,
    {[" .--." ++ Sparkle,
      Face,
      " `--'"],
     case T rem 16 of 15 -> thinking; _ -> happy end};
blob_frame(thinking, T) ->
    Dots = lists:duplicate((T rem 3) + 1, $.),
    {[" .--.",
      "( o_o) ?" ++ Dots,
      " `--'"],
     case T rem 12 of 11 -> sleepy; _ -> thinking end};
blob_frame(sleepy, T) ->
    Zs = lists:duplicate((T rem 3) + 1, $z),
    {[" .--. " ++ Zs,
      "( -_-)",
      " `--'"],
     case T rem 18 of 17 -> idle; _ -> sleepy end}.

%%--------------------------------------------------------------------
%% Snake — slithers across the panel (2 lines: tongue + body)
%%--------------------------------------------------------------------

snake() -> snake(#{}).
snake(Opts) ->
    Width = maps:get(width, Opts, 16),
    start_pet(snake, Opts#{width => Width, tick => 0, pos => 0, dir => right}).

snake_render(#{width := W, pos := Pos, dir := Dir, tick := T} = St) ->
    Body = case T rem 4 of
        0 -> "~~~~@";
        1 -> "~~~~ @";
        2 -> " ~~~~@";
        3 -> "~~~~~@"
    end,
    Tongue = case T rem 2 of 0 -> "~"; 1 -> "~~" end,
    {SnakeLines, NewPos, NewDir} = case Dir of
        right when Pos >= W - 8 ->
            {[lists:duplicate(max(0, Pos-1), $\s) ++ Tongue,
              lists:duplicate(max(0, Pos), $\s) ++ "@~~~~~"],
             Pos - 1, left};
        right ->
            {[lists:duplicate(max(0, Pos + 6), $\s) ++ Tongue,
              lists:duplicate(max(0, Pos), $\s) ++ Body ++ ":>"],
             Pos + 1, right};
        left when Pos =< 0 ->
            {[lists:duplicate(max(0, 1), $\s) ++ Tongue,
              "<:" ++ Body],
             Pos + 1, right};
        left ->
            {[lists:duplicate(max(0, Pos), $\s) ++ Tongue,
              lists:duplicate(max(0, Pos), $\s) ++ "<:" ++ Body],
             Pos - 1, left}
    end,
    {SnakeLines, St#{pos := NewPos, dir := NewDir, tick := T + 1}}.

%%--------------------------------------------------------------------
%% Control
%%--------------------------------------------------------------------

stop(Name) ->
    PetName = pet_proc_name(Name),
    case whereis(PetName) of
        undefined -> ok;
        Pid -> Pid ! stop
    end,
    etui_panel:remove(Name),
    ok.

poke(Name) ->
    PetName = pet_proc_name(Name),
    case whereis(PetName) of
        undefined -> ok;
        Pid -> Pid ! poke
    end,
    ok.

%%--------------------------------------------------------------------
%% Internal: pet loop (faster tick than widgets — 500ms)
%%--------------------------------------------------------------------

start_pet(Name, InitState) ->
    stop(Name),
    Pid = spawn(fun() -> pet_loop(Name, InitState) end),
    register(pet_proc_name(Name), Pid),
    ok.

pet_proc_name(Name) ->
    list_to_atom("pet_" ++ atom_to_list(Name)).

pet_loop(Name, State) ->
    RenderFn = case Name of
        fish  -> fun fish_render/1;
        cat   -> fun cat_render/1;
        blob  -> fun blob_render/1;
        snake -> fun snake_render/1
    end,
    {Lines, NewState} = try RenderFn(State)
                         catch _:_ -> {["?"], State}
                         end,
    etui_panel:set(Name, fun(_Width) -> Lines end, 20, #{group => pets}),
    receive
        stop ->
            etui_panel:remove(Name);
        poke ->
            pet_loop(Name, NewState#{react => poked, react_ttl => 4})
    after 500 ->
        pet_loop(Name, NewState)
    end.
