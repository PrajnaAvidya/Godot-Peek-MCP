# Godot Peek MCP

MCP server for peeking into Godot editor runtime. Run scenes, capture output, inspect debugger state.

## Why Another Godot MCP?

Other Godot MCPs wrap editor actions that LLMs can already do. Claude can edit `.tscn`, `.tres`, and `.gd` files directly, it doesn't need a tool to "add a node" when it can just edit the scene file.

This MCP focuses on **runtime visibility**: output panels, debugger state, screenshots. The stuff that normally requires interacting with the editor.

## Setup

Download, copy, connect. Three steps.

### 1. Download

Grab the release for your OS from [Releases](https://github.com/PrajnaAvidya/godot-peek-mcp/releases):

| OS | File |
|----|------|
| Linux x86_64 | `godot-peek-mcp-vX.X.X-linux-x86_64.tar.gz` |
| macOS Apple Silicon | `godot-peek-mcp-vX.X.X-macos-arm64.tar.gz` |

Extract it somewhere convenient (e.g. `~/tools/godot-peek-mcp/`). You'll get:
- `godot-peek-mcp` — the MCP server binary
- `addons/godot_mcp/` — the Godot plugin

### 2. Install the Godot plugin

Copy the `addons/godot_mcp` folder into your Godot project so you end up with `your-project/addons/godot_mcp/`. Then enable it in Godot: **Project > Project Settings > Plugins > Godot Peek MCP > Enable**.

You should see this in the Output panel:
```
[GodotPeek] Socket server listening on /tmp/godot-peek.sock
```

### 3. Register the MCP server

Pick your MCP client:

<details>
<summary><strong>Claude Code</strong></summary>

Run this from your Godot project directory, pointing to the `godot-peek-mcp` binary you extracted in step 1:

```bash
claude mcp add godot-peek ~/tools/godot-peek-mcp/godot-peek-mcp
```

Restart Claude Code or run `/mcp` to verify the connection.
</details>

<details>
<summary><strong>Cursor</strong></summary>

Create or edit `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "godot-peek": {
      "command": "/home/YOUR_USER/tools/godot-peek-mcp/godot-peek-mcp"
    }
  }
}
```
</details>

<details>
<summary><strong>Windsurf</strong></summary>

Edit `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "godot-peek": {
      "command": "/home/YOUR_USER/tools/godot-peek-mcp/godot-peek-mcp"
    }
  }
}
```
</details>

<details>
<summary><strong>Claude Desktop</strong></summary>

Edit your config file (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS, `~/.config/Claude/claude_desktop_config.json` on Linux):

```json
{
  "mcpServers": {
    "godot-peek": {
      "command": "/home/YOUR_USER/tools/godot-peek-mcp/godot-peek-mcp"
    }
  }
}
```
</details>

That's it. You're done.

### macOS: clearing quarantine

macOS may block unsigned binaries downloaded from the internet. If you get a security warning, run:

```bash
xattr -cr ~/tools/godot-peek-mcp/godot-peek-mcp
xattr -cr ~/your-project/addons/godot_mcp/bin/
```

## Features

- **Scene Control**: Run main/current/specific scenes, stop the game
- **Variable Overrides**: Set autoload variables at startup (e.g. enable debug mode)
- **Output Capture**: Read the Output panel
- **Debugger Integration**: Errors, stack traces, local variables, performance monitors
- **Debugger Control**: Set breakpoints, step through code, pause/continue
- **Runtime Inspection**: Node tree and properties from running game
- **Screenshots**: Editor viewports or running game
- **Expression Evaluation**: Evaluate arbitrary GDScript in running game

## Tools

### Scene Control

| Tool | Description | Parameters |
|------|-------------|------------|
| `run_main_scene` | Run main scene (F5) | `timeout_seconds`, `overrides` (optional) |
| `run_scene` | Run a specific scene | `scene_path`, `timeout_seconds`, `overrides` (optional) |
| `run_current_scene` | Run currently open scene | `timeout_seconds`, `overrides` (optional) |
| `stop_scene` | Stop the running game | none |

**overrides**: Set autoload variables at startup. Format: `{"AutoloadName": {"property": value}}`
Example: `{"DebugManager": {"debug_mode": true}}`

### Output & Debugging

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_output` | Get Output panel content | `clear`, `new_only` (optional) |
| `get_debugger_errors` | Get Debugger Errors tab | none |
| `get_debugger_stack_trace` | Get stack trace when paused on error/breakpoint | none |
| `get_debugger_locals` | Get local variables when paused on error/breakpoint | `frame_index` (optional, 0=top) |
| `get_monitors` | Get performance monitors (FPS, memory, etc.) | none |
| `get_remote_scene_tree` | Get node tree from running game | none |
| `get_remote_node_properties` | Get node properties | `node_path` (e.g. /root/game/Player) |

### Screenshots

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_screenshot` | Capture editor or game | `target`: "editor" or "game" |

### Debugger Control

| Tool | Description | Parameters |
|------|-------------|------------|
| `set_breakpoint` | Set or clear a breakpoint | `path`, `line`, `enabled` |
| `clear_breakpoints` | Clear all breakpoints | none |
| `get_debugger_state` | Check if paused/active/debuggable | none |
| `debug_continue` | Continue execution | none |
| `debug_step` | Step into/over/out | `mode`: "into", "over", "out" |
| `debug_break` | Pause execution | none |

**Note:** Breakpoints only work with Godot's built-in script editor. If using an external editor, breakpoints won't trigger.

### Expression Evaluation

| Tool | Description | Parameters |
|------|-------------|------------|
| `evaluate_expression` | Evaluate GDScript in running game | `expression` (e.g. `get_node("/root/Main/Player").health`) |

Use this to query game state, set variables, or call methods without adding debug code.

## Tips for LLM Users

**Iterative debugging**: Run scene → check output → fix code → repeat. The `run_*` tools auto-detect startup crashes and return the stack trace.

**Test with overrides**: Run with `{"DebugManager": {"debug_mode": true}}` to enable debug features without editing code.

**Inspect at runtime**: Use `get_remote_scene_tree` to see what's instantiated, then `get_remote_node_properties` to check values.

**Auto-stop for testing**: Use `timeout_seconds` to run briefly, then check `get_output`. Good for automated test loops.

**Screenshots for visual bugs**: `get_screenshot target=game` shows exactly what the player sees.

**Evaluate expressions**: Query any game state without print statements. `evaluate_expression "get_tree().current_scene.name"` or modify state: `evaluate_expression "get_node('/root/Main/Player').set('health', 100)"` (use `.set()` — assignment operators don't work in Expression class). **Note:** If the expression triggers a runtime error, the tool call will timeout since the game crashes before it can respond.

## Notes

**Output** reads from the Output panel: `print()`, `push_error()`, `push_warning()`, and editor messages.

**Debugger tools** pull from the respective debugger tabs. `frame_index` selects which stack frame for locals (0=top). **Important:** `get_debugger_stack_trace` and `get_debugger_locals` only have data when the game is paused on a runtime error or breakpoint — calling them during normal execution returns empty results.

**Remote inspection** (`get_remote_scene_tree`, `get_remote_node_properties`) only works while the game is running.

**Monitors** (`get_monitors`) shows engine performance data: FPS, memory usage, draw calls, physics stats, etc.

**Screenshots** save to `/tmp/godot_peek_*.png`. Editor screenshots capture active 2D/3D viewports. Game screenshots require the autoload that the plugin adds automatically.

## Architecture

```
┌─────────────────────┐     stdio      ┌─────────────────────┐
│   Claude Code #1    │◄──────────────►│  Go MCP Server #1   │──┐
└─────────────────────┘                └─────────────────────┘  │
┌─────────────────────┐     stdio      ┌─────────────────────┐  │ Unix socket
│   Claude Code #2    │◄──────────────►│  Go MCP Server #2   │──┤ /tmp/godot-peek.sock
└─────────────────────┘                └─────────────────────┘  │
                                            ...                 │
                                       ┌────────────────────────▼┐
                                       │  C++ GDExtension        │
                                       │  (addons/godot_mcp)     │
                                       └────────────┬────────────┘
                                                    │ UDP (game features)
                                                    │ port 6971
                                       ┌────────────▼────────────┐
                                       │  Runtime Helper         │
                                       │  (running game)         │
                                       └─────────────────────────┘
```

Multiple MCP client sessions can connect simultaneously. Each session spawns its own Go MCP server process, and the C++ extension accepts all connections concurrently.

## Requirements

- Godot 4.4, 4.5, or 4.6
- Linux x86_64 or macOS arm64 (Apple Silicon)

## Building from Source

If you want to build from source instead of using a release:

```bash
# go mcp server
go build -ldflags="-s -w" -o godot-peek-mcp ./cmd/godot-peek-mcp

# c++ extension (requires godot-cpp — set GODOT_CPP_PATH or defaults to ~/Code/godot-cpp)
cd extension && scons platform=linux target=editor
```
