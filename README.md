# Godot Peek MCP

MCP server for peeking into Godot 4.5+ editor runtime. Run scenes, capture output, inspect debugger state.

## Why Another Godot MCP?

Other Godot MCPs wrap editor actions that LLMs can already do. Claude can edit `.tscn`, `.tres`, and `.gd` files directly; it doesn't need a tool to "add a node" when it can just edit the scene file.

This MCP focuses on **runtime visibility**: output panel, debugger state, screenshots. The stuff that requires looking at the screen.

## Features

- **Scene Control**: Run main/current/specific scenes, stop the game
- **Variable Overrides**: Set autoload variables at startup (e.g. enable debug mode)
- **Output Capture**: Read the Output panel
- **Debugger Integration**: Errors, stack traces, local variables
- **Runtime Inspection**: Node tree and properties from running game
- **Screenshots**: Editor viewports or running game

## Quick Start

### 1. Get the MCP Server

Download a binary from [Releases](https://github.com/PrajnaAvidya/godot-peek-mcp/releases), or build from source:

```bash
go build -o godot-peek-mcp ./cmd/godot-peek-mcp
```

### 2. Install Godot Plugin

Copy `addons/godot_mcp` to your Godot project's addons folder, then enable in Project Settings → Plugins.

You should see in Output:
```
[GodotPeek] WebSocket server listening on ws://localhost:6970
```

### 3. Register with MCP Client

```bash
claude mcp add godot-peek /path/to/godot-peek-mcp/godot-peek-mcp
```

Restart Claude Code or run `/mcp` to reload.

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
| `get_debugger_stack_trace` | Get stack trace when paused | none |
| `get_debugger_locals` | Get local variables | `frame_index` (optional, 0=top) |
| `get_remote_scene_tree` | Get node tree from running game | none |
| `get_remote_node_properties` | Get node properties | `node_path` (e.g. /root/game/Player) |

### Screenshots

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_screenshot` | Capture editor or game | `target`: "editor" or "game" |

## Architecture

```
┌─────────────────────┐     stdio      ┌─────────────────────┐
│   Claude Code       │◄──────────────►│    Go MCP Server    │
│   (MCP Client)      │                │   (godot-peek-mcp)  │
└─────────────────────┘                └──────────┬──────────┘
                                                  │ WebSocket
                                                  │ ws://localhost:6970
                                       ┌──────────▼──────────┐
                                       │  Godot EditorPlugin │
                                       │  (addons/godot_mcp) │
                                       └─────────────────────┘
```

## Notes

**Output** reads from the Output panel: `print()`, `push_error()`, `push_warning()`, and editor messages.

**Debugger tools** pull from the respective debugger tabs. `frame_index` selects which stack frame for locals (0=top).

**Remote inspection** (`get_remote_scene_tree`, `get_remote_node_properties`) only works while the game is running.

**Screenshots** save to `/tmp/godot_peek_*.png`. Editor screenshots capture active 2D/3D viewports. Game screenshots require the autoload that the plugin adds automatically.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `GODOT_MCP_URL` | `ws://localhost:6970` | WebSocket URL |

Plugin port is in `addons/godot_mcp/mcp_server.gd`.

## Tips for LLM Users

**Iterative debugging**: Run scene → check output → fix code → repeat. The `run_*` tools auto-detect startup crashes and return the stack trace.

**Test with overrides**: Run with `{"DebugManager": {"debug_mode": true}}` to enable debug features without editing code.

**Inspect at runtime**: Use `get_remote_scene_tree` to see what's instantiated, then `get_remote_node_properties` to check values.

**Auto-stop for testing**: Use `timeout_seconds` to run briefly, then check `get_output`. Good for automated test loops.

**Screenshots for visual bugs**: `get_screenshot target=game` shows exactly what the player sees.

## Requirements

- Godot 4.5+
- Any MCP client
- Go 1.21+ (only if building from source)
