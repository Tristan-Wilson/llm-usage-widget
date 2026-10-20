# LLM Usage Widget

A macOS menu bar app that shows how much of your Claude Code and Codex plan limits you have used.

```
Claude 15%·21%  Codex 4%
```

## What it shows

- **Claude:** the current session % and the current week % (all models).
- **Codex:** the used % of each window of your plan's main limit.
- A value turns orange at 75% and red at 90%.

Click the item to open the menu. The menu shows each window with its reset time (for example
"Session: 15% · resets in 4h 38m (16:19)"), other windows such as the weekly limit for one model,
the Codex reset credits, and when the data was last updated.

| Label | Meaning |
|---|---|
| `Claude 15%·21%` | Session 15%, week 21%. |
| `Claude …` | The first update is not complete yet. |
| `Claude login` (orange) | You must log in again. Run `claude /login` or `codex login` in Terminal. |
| `Claude error` (orange) | The CLI output changed and the app cannot read it. Update the app. |
| `Claude ?` | No good result for 6 minutes (for example, no network). The app tries again every 2 minutes. |
| No Claude or Codex part | The CLI is not installed, or the login has no plan limits (an API key, Bedrock or Vertex). |
| `LLM –` | The app found no Claude or Codex plan. |

## Requirements

- macOS 14 or later, on Apple Silicon or Intel.
- At least one of these:
  - [Claude Code](https://claude.com/claude-code) (`claude`), logged in with a Claude plan
    (Pro, Max, Team or Enterprise).
  - The [Codex CLI](https://github.com/openai/codex) (`codex`), logged in with ChatGPT.
- The Xcode Command Line Tools, to build the app: `xcode-select --install`. Full Xcode is not necessary.

## Install

```sh
git clone https://github.com/Tristan-Wilson/llm-usage-widget.git
cd llm-usage-widget
./build.sh install
```

The script builds the app, copies it to `/Applications` (or to `~/Applications` if you cannot write to
`/Applications`), and starts it. The first time the app starts, macOS shows "Login Item Added": the app
will start each time you log in. You can turn this off in the menu.

The app is not signed with an Apple Developer ID. This is not a problem when you build it yourself,
because macOS checks only apps that you download from the internet.

## Update

```sh
cd llm-usage-widget
git pull
./build.sh install
```

## Menu options

- **Refresh Now** (⌘R): update the LLM usage now. It updates by itself every 2 minutes.
- **Show System Stats**: add a second menu bar item with CPU, GPU, memory used, memory pressure (the
  colored dot) and network speed. It updates every 10 seconds. Off by default.
- **Start at Login**: on by default.

## How it works

The app itself makes no network connections, and it does not read or keep your credentials. Every
2 minutes it asks each vendor's own CLI, which uses the login that you already have:

- **Claude:** `claude auth status --json`, then
  `claude -p /usage --safe-mode --strict-mcp-config --no-session-persistence`. The app reads the
  "Current session" and "Current week" lines of the output.
- **Codex:** the app starts
  `codex app-server --disable plugins --disable remote_plugin --disable apps -c mcp_servers={}` for a few
  seconds, and asks for `account/read` and `account/rateLimits/read` over JSON-RPC on stdin/stdout.

The `/usage` text is not a stable API. If a Claude Code update changes it, the label shows
`Claude error` until the app gets an update. The app never shows a number that it could not read
correctly.

The app finds `claude` and `codex` through the PATH of your login shell, so installs with npm, nvm or
Homebrew work.

## Uninstall

1. In the menu, turn off **Start at Login**.
2. Click **Quit**.
3. Move `LLMUsageWidget.app` from `/Applications` (or `~/Applications`) to the Trash.
