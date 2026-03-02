# erlang-agent

A self-extending LLM agent written in pure Erlang. Zero external dependencies. Themeable TUI with animated pet widgets. Sandboxed execution.

The agent runs a tool loop where the LLM autonomously decides when to call tools — execute shell commands, read/write files, make HTTP requests, or compile and hot-load new Erlang modules into the running system. Inspired by the [200-line coding agent](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/) pattern and [pi-coding-agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/).

## Quick Start

```bash
./run                          # build + launch sandboxed TUI
./run --no-sandbox             # skip macOS sandbox
./run --model qwen3-8b         # override model
./run --theme dracula          # use a different theme
./run --url http://host:8000/v1/chat/completions
./run --api anthropic --api-key sk-ant-...   # use Anthropic API
```

The TUI gives you a chat interface. The LLM will call tools on its own when it decides they're needed — no special syntax required. Just talk to it.

### Commands

| Input | Action |
|-------|--------|
| `/clear` | Clear screen and reset conversation history |
| `/theme` | Open theme picker with live previews |
| `/model` | Show current model |
| `/help` | Show available commands |
| `/quit` | Exit |

## LLM Backend Support

The agent supports both OpenAI-compatible and Anthropic API formats. Auto-detected from URL:

| URL pattern | API format |
|-------------|-----------|
| `*/v1/chat/completions` | OpenAI (vLLM, llama.cpp, Ollama, LM Studio) |
| `*/v1/messages` | Anthropic (Claude) |

Both formats support structured tool calling. Falls back to text-based `tool: name(args)` parsing for models without native tool support.

## Themes

Four built-in themes, switchable at runtime via `/theme`:

| Theme | Description |
|-------|-------------|
| `synthwave` | Neon cyberpunk — cyan, hot pink, deep magenta (default) |
| `mono` | Monochrome — clean black and white |
| `dracula` | Dracula dark — purple, pink, green |
| `solarized` | Solarized dark — muted, warm tones |

Each theme defines 17 semantic color roles (accent, prompt, user message, tool backgrounds, stats, errors, etc.). Add your own in `theme.erl`.

## Pets

Animated ASCII pets live in colored boxes in the widget panel. Each pet has its own personality and mood cycles.

```erlang
pets:cat().            %% cat sleeps, wakes, stretches, plays
pets:blob().           %% tamagotchi blob with moods
pets:fish().           %% fish swims back and forth
pets:snake().          %% snake slithers across
pets:poke(cat).        %% poke a pet (triggers reaction)
pets:stop(fish).       %% remove a pet
```

Pets in the same group render side-by-side in a pi-style grid, each with a colored accent bar and dark background block.

## Widget Panels

Status widgets render in a panel above the prompt. Extensions can register, update, and remove widgets at runtime.

```erlang
%% Built-in widgets
widgets:uptime().                          %% session elapsed time
widgets:sysinfo().                         %% memory + process count
widgets:tokens().                          %% token usage tracker
widgets:ticker(agent1, "researching").     %% custom animated status
widgets:stop(agent1).                      %% remove a widget
widgets:stop_all().                        %% clear all widgets
```

### Widget API (`etui_panel`)

Any process can add widgets to the panel:

```erlang
etui_panel:set(my_task, "downloading...").         %% static text
etui_panel:set(my_task, "50% done", 10).           %% with priority (lower = higher)
etui_panel:set(my_task, fun(Width) ->              %% dynamic render function
    ["progress: " ++ integer_to_list(get_pct()) ++ "%"]
end).
etui_panel:set(my_task, Content, 20, #{group => mygroup}).  %% grouped in box grid
etui_panel:remove(my_task).                        %% remove widget
etui_panel:list().                                 %% list active widget ids
etui_panel:clear().                                %% remove all
```

Widgets with the same `group` option render side-by-side in colored block boxes (pi-style grid layout). Ungrouped widgets render as plain text lines.

## Architecture

```
cli.erl (event-driven TUI — input reader, rendering, chrome management)
  ├── agent.erl (core agent process — history, tool loop)
  │     └── llm.erl (unified OpenAI/Anthropic LLM client)
  ├── tools.erl (tool execution, parsing, helpers)
  ├── theme.erl (color themes — 4 built-in, runtime switchable)
  ├── etui_panel (widget panel — grouped box grids + plain widgets)
  ├── pets.erl (animated ASCII pets)
  └── widgets.erl (status widgets — uptime, sysinfo, tokens, ticker)
```

The TUI uses a pi-tui style rendering approach: no scroll regions, linear scrollback, persistent chrome (widgets + prompt + footer) rendered at the bottom. Before new output, chrome is erased, content is written, chrome is re-rendered. Widget animations run on a 500ms timer with cursor save/restore to avoid disrupting input.

### Tool Loop

Every LLM response is checked for tool calls. The agent supports both structured API tool calls (OpenAI/Anthropic format) and text-based fallback parsing (`tool: name(args)`). When a tool call is found:

1. Execute the tool
2. Feed the result back to the LLM
3. Call the LLM again
4. Repeat until no tool call (max 10 steps)

## Tools

| Tool | Description |
|------|-------------|
| `exec(command)` | Run a shell command, return stdout |
| `read_file(path)` | Read a file's contents |
| `write_file(path, content)` | Write content to a file |
| `http_get(url)` | HTTP GET, return body |
| `http_post(url, body)` | HTTP POST, return status + body |
| `load_module(name, source)` | Compile Erlang source, hot-load into the running VM. Auto-runs `test/0` if exported |

### Self-Extension via `load_module`

The `load_module` tool is what makes this agent self-extending. The LLM can write new Erlang modules, compile them, and load them into the running system — then call those modules from subsequent tool invocations. If the module exports `test/0`, it runs automatically with a 5-second timeout.

## Modules

| Module | Purpose |
|--------|---------|
| `agent.erl` | Core agent process — conversation history, tool loop, LLM calls |
| `llm.erl` | Unified LLM client — OpenAI and Anthropic API support, tool call extraction |
| `tool_agent.erl` | Standalone agentic loop for scripted/headless use |
| `tools.erl` | Shared tool execution, parsing, and helpers |
| `cli.erl` | Event-driven TUI — input, rendering, theme integration, widget display |
| `theme.erl` | Color themes — 4 built-in, runtime switchable |
| `pets.erl` | Animated ASCII pets — cat, blob, fish, snake with mood cycles |
| `widgets.erl` | Status widgets (uptime, sysinfo, tokens, ticker) |
| `json.erl` | Minimal JSON encode/decode, zero dependencies |
| `ssh_agent.erl` | SSH daemon wrapper |

### `etui/` — Terminal UI Library

| Module | Purpose |
|--------|---------|
| `etui_input` | Line editor with cursor movement, history |
| `etui_keys` | Raw terminal key parsing (arrows, ctrl, alt, function keys) |
| `etui_md` | Markdown-to-ANSI renderer (headings, bold, italic, code, lists, tables) |
| `etui_panel` | Widget panel — named widgets with priority ordering and grouped box grids |
| `etui_ansi` | ANSI escape code state tracking |
| `etui_text` | Word wrapping, visible width measurement, ANSI stripping |
| `etui_style` | Style composition (bold, dim, italic, fg/bg colors) |
| `etui_term` | Terminal control (raw mode, cursor, dimensions, sync output) |
| `etui_spinner` | Animated spinners |

## Sandbox

The `./run` script wraps the agent in macOS [`sandbox-exec`](https://keith.github.io/xcode-man-pages/sandbox-exec.1.html) by default. The profile (`sandbox.sb`) allows:

| Permission | Scope |
|------------|-------|
| **Read** | Anywhere (agent needs filesystem context) |
| **Write** | Project directory, `/tmp`, `/var/folders` only |
| **Network** | Outbound allowed (LLM API, HTTP tools) |
| **Denied** | `~/.ssh`, `~/.gnupg`, `~/.aws`, `/etc`, `/usr`, `/System` |

Shell commands from `exec` inherit the sandbox. Bypass with `./run --no-sandbox`.

## Hot Reload

Edit any `.erl` file and reload without restarting:

```bash
make reload                              # push to running node
```

Or from the Erlang shell:

```erlang
agent:reload().
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Compile all modules to `ebin/` |
| `make test` | Run all tests (json, tools, etui_text) |
| `make shell` | Compile + interactive shell |
| `make agent` | Compile + start agent process |
| `make ssh` | Compile + start agent + SSH daemon |
| `make tool GOAL="..."` | Run standalone tool agent |
| `make reload` | Hot reload into running node |
| `make clean` | Remove `ebin/` and generated keys |

## Configuration

Defaults target [GLM-4.7-Flash](https://huggingface.co/THUDM/glm-4-9b-chat) via [vLLM](https://docs.vllm.ai/) on `spark.local:8000`. Any OpenAI-compatible or Anthropic endpoint works.

```erlang
agent:start(#{
    llm_url   => "http://192.168.1.100:8000/v1/chat/completions",
    model     => "glm-4.7-flash",
    api       => openai,           %% openai | anthropic (auto-detected from URL)
    api_key   => "sk-...",         %% optional API key
    system    => <<"Custom system prompt">>,
    max_steps => 15
}).
```

Compatible backends: [vLLM](https://docs.vllm.ai/), [llama.cpp server](https://github.com/ggerganov/llama.cpp/tree/master/examples/server), [Ollama](https://ollama.com/), [LM Studio](https://lmstudio.ai/), [Anthropic API](https://docs.anthropic.com/), any OpenAI API-compatible server.

## Requirements

- [Erlang/OTP](https://www.erlang.org/downloads) 26+ (tested on 28)
- Network access to an OpenAI-compatible or Anthropic LLM endpoint
- macOS for sandbox (agent works without it on Linux, just use `--no-sandbox`)
- No external dependencies

## Resources

### Inspiration

- [pi-coding-agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/) — Mario Zechner's coding agent that inspired the TUI design, widget panels, and pet system
- [pi-mono](https://github.com/nicholasgasior/pi-mono) — pi source code, reference for box grid rendering and event-driven TUI architecture
- [Mario Zechner's blog](https://mariozechner.at/) — ongoing posts about building pi and coding agents
- [The Emperor Has No Clothes — 200 line coding agent](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/) — the minimal agent pattern this project started from
- [Building Effective Agents (Anthropic)](https://www.anthropic.com/engineering/building-effective-agents)
- [Advanced Tool Use (Anthropic)](https://www.anthropic.com/engineering/advanced-tool-use)

### Technical References

- [Erlang/OTP documentation](https://www.erlang.org/doc/)
- [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat) — the protocol agent.erl speaks
- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages) — alternative API format
- [vLLM](https://docs.vllm.ai/) — recommended inference server
- [GLM-4 on HuggingFace](https://huggingface.co/THUDM/glm-4-9b-chat) — default model
- [macOS sandbox-exec](https://keith.github.io/xcode-man-pages/sandbox-exec.1.html) — sandbox profile format
- [Erlang hot code loading](https://www.erlang.org/doc/system/code_loading.html) — how `load_module` and `reload` work
