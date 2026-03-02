# erlang-agent

A self-extending LLM agent written in pure Erlang. Zero external dependencies. Synthwave TUI. Sandboxed execution.

The agent runs a tool loop where the LLM autonomously decides when to call tools — execute shell commands, read/write files, make HTTP requests, or compile and hot-load new Erlang modules into the running system. Inspired by the [200-line coding agent](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/) pattern.

![synthwave TUI](https://img.shields.io/badge/theme-synthwave-ff69b4)

## Quick Start

```bash
./run                          # build + launch sandboxed TUI
./run --no-sandbox             # skip macOS sandbox
./run --model qwen3-8b         # override model
./run --url http://host:8000/v1/chat/completions
```

The TUI gives you a chat interface. The LLM will call tools on its own when it decides they're needed — no special syntax required. Just talk to it.

### Commands

| Input | Action |
|-------|--------|
| `/clear` | Reset conversation history |
| `/quit` or `ctrl+c` | Exit |

## Architecture

```
┌─────────────────────────────────────────┐
│  cli.erl  (TUI — input, rendering)     │
│  ┌───────────────────────────────────┐  │
│  │  agent.erl  (core agent process)  │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  tool_loop: LLM → parse →  │  │  │
│  │  │  execute → feed result →   │  │  │
│  │  │  repeat until no tool call │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
│  sandbox.sb  (macOS sandbox profile)    │
└─────────────────────────────────────────┘
```

### Tool Loop

Every LLM response is scanned for `tool: name(args)` markers. When found:

1. Parse the tool name and arguments (JSON or positional CSV)
2. Execute the tool
3. Feed `tool_result(...)` back as a user message
4. Call the LLM again
5. Repeat until the response contains no tool call (max 10 steps)

This is the same pattern used by coding agents like [Claude Code](https://www.anthropic.com/engineering/advanced-tool-use) and [Aider](https://aider.chat/) — the LLM decides autonomously when tools would help.

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

```
You: "Create a fibonacci module and test it"

LLM thinks... then calls:
  tool: load_module("fib", "-module(fib).\n-export([fib/1, test/0]).\n\nfib(0) -> 0;\nfib(1) -> 1;\nfib(N) -> fib(N-1) + fib(N-2).\n\ntest() -> 55 = fib(10), ok.\n")

Result: ok: fib loaded
  exports: fib/1, test/0
  test/0 passed: ok
```

## Modules

### `agent.erl` — Core Agent Process

Registered process (`agent`) with conversation history, tool execution, and LLM communication. Speaks the [OpenAI chat completions](https://platform.openai.com/docs/api-reference/chat) protocol.

```erlang
agent:start(#{llm_url => "http://host:8000/v1/chat/completions", model => "model-name"}).
agent:chat("prompt").                          %% one-shot
agent:chat("prompt", #{keep_history => true}). %% multi-turn
agent:chat("prompt", #{on_tool => fun(Event, Data) -> ... end}). %% tool callbacks
agent:exec("ls -la").                          %% direct shell command
agent ! clear_history.
agent ! {set_model, "other-model"}.
agent:reload().                                %% hot code reload
```

### `cli.erl` — Synthwave TUI

Terminal UI with:
- Hot pink prompt, deep magenta user message bubbles
- Per-tool colored backgrounds (navy for exec, purple for file ops, magenta for module loading)
- ANSI-aware width padding for full-width bars
- Braille spinner during LLM calls
- Stats line (elapsed time, approximate token count)
- Cyan footer with cwd and model name

### `etui/` — Terminal UI Library

Minimal TUI primitives, built from scratch:

| Module | Purpose |
|--------|---------|
| `etui_input` | Line editor with cursor movement, history |
| `etui_keys` | Raw terminal key parsing (arrows, ctrl, alt, function keys) |
| `etui_md` | Markdown-to-ANSI renderer (headings, bold, italic, code, lists) |
| `etui_ansi` | ANSI escape code helpers |
| `etui_text` | Word wrapping, text measurement |
| `etui_style` | Style composition |
| `etui_term` | Terminal size queries |
| `etui_spinner` | Animated spinners |

### `ssh_agent.erl` — SSH Daemon

Wraps the agent in an Erlang SSH server. Any SSH client becomes an inference endpoint.

```bash
make ssh                                 # start on port 2222
ssh localhost -p 2222 "What is PCI enumeration?"
```

### `tool_agent.erl` — Standalone Agentic Loop

Standalone version of the tool loop (before it was merged into `agent.erl`). Useful for scripted/headless use:

```erlang
tool_agent:run("Find network interfaces and configure DHCP").
tool_agent:run("POST hello to http://ctf.local/submit", #{max_steps => 20}).
```

### `json.erl` — JSON Codec

Minimal encode/decode. Maps, lists, binaries, atoms, numbers. No dependencies.

## Sandbox

The `./run` script wraps the agent in macOS [`sandbox-exec`](https://keith.github.io/xcode-man-pages/sandbox-exec.1.html) by default. The profile (`sandbox.sb`) allows:

| Permission | Scope |
|------------|-------|
| **Read** | Anywhere (agent needs filesystem context) |
| **Write** | Project directory, `/tmp`, `/var/folders` only |
| **Network** | Outbound allowed (LLM API, HTTP tools) |
| **Denied** | `~/.ssh`, `~/.gnupg`, `~/.aws`, `/etc`, `/usr`, `/System` |

Shell commands from `exec` inherit the sandbox — the LLM can't write to your home directory, SSH keys, or system paths even through shell commands.

Bypass with `./run --no-sandbox` when needed.

## Hot Reload

Edit any `.erl` file and reload without restarting:

```bash
make reload                              # push to running node
```

Or from the Erlang shell:

```erlang
agent:reload().
```

The agent process picks up new code on the next message. No dropped connections, no lost history.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Compile all modules to `ebin/` |
| `make shell` | Compile + interactive shell |
| `make agent` | Compile + start agent process |
| `make ssh` | Compile + start agent + SSH daemon |
| `make tool GOAL="..."` | Run standalone tool agent |
| `make reload` | Hot reload into running node |
| `make clean` | Remove `ebin/` and generated keys |

## Configuration

Defaults target [GLM-4.7-Flash](https://huggingface.co/THUDM/glm-4-9b-chat) via [vLLM](https://docs.vllm.ai/) on `spark.local:8000`. Any [OpenAI-compatible](https://platform.openai.com/docs/api-reference/chat) endpoint works.

```erlang
agent:start(#{
    llm_url   => "http://192.168.1.100:8000/v1/chat/completions",
    model     => "glm-4.7-flash",
    system    => <<"Custom system prompt">>,
    max_steps => 15
}).
```

Compatible backends: [vLLM](https://docs.vllm.ai/), [llama.cpp server](https://github.com/ggerganov/llama.cpp/tree/master/examples/server), [Ollama](https://ollama.com/), [LM Studio](https://lmstudio.ai/), any OpenAI API-compatible server.

## Requirements

- [Erlang/OTP](https://www.erlang.org/downloads) 26+ (tested on 28)
- Network access to an OpenAI-compatible LLM endpoint
- macOS for sandbox (agent works without it on Linux, just use `--no-sandbox`)
- No external dependencies

## Resources

- [Erlang/OTP documentation](https://www.erlang.org/doc/)
- [The Emperor Has No Clothes — 200 line coding agent](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/) — the pattern this agent follows
- [Building Effective Agents (Anthropic)](https://www.anthropic.com/engineering/building-effective-agents) — agentic loop design
- [Advanced Tool Use (Anthropic)](https://www.anthropic.com/engineering/advanced-tool-use) — self-extending tool patterns
- [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat) — the protocol agent.erl speaks
- [vLLM](https://docs.vllm.ai/) — recommended inference server
- [GLM-4 on HuggingFace](https://huggingface.co/THUDM/glm-4-9b-chat) — default model
- [macOS sandbox-exec](https://keith.github.io/xcode-man-pages/sandbox-exec.1.html) — sandbox profile format
- [Erlang hot code loading](https://www.erlang.org/doc/system/code_loading.html) — how `load_module` and `reload` work
