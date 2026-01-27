# Godot Peek MCP

MCP server for peeking into Godot 4.5+ editor runtime. Run scenes, capture output, inspect debugger state.

## Why Another Godot MCP?

Other Godot MCPs wrap editor actions that LLMs can already do. Claude can edit `.tscn`, `.tres`, and `.gd` files directly; it doesn't need a tool to "add a node" when it can just edit the scene file.

This MCP focuses on **runtime visibility**: output panel, debugger state, screenshots. The stuff that requires looking at the screen.

## Features

- **Scene Control**: Run main/current/specific scenes, stop the game
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
| `run_main_scene` | Run main scene (F5) | `timeout_seconds` (optional) |
| `run_scene` | Run a specific scene | `scene_path`, `timeout_seconds` (optional) |
| `run_current_scene` | Run currently open scene | `timeout_seconds` (optional) |
| `stop_scene` | Stop the running game | none |

### Output & Debugging

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_output` | Get Output panel content | `clear` (optional) |
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

**Debugger tools** (`get_debugger_errors`, `get_debugger_stack_trace`, `get_debugger_locals`) pull from the respective debugger tabs. `frame_index` selects which stack frame for locals (0=top).

**Remote inspection** (`get_remote_scene_tree`, `get_remote_node_properties`) only works while the game is running.

**Screenshots** save to `/tmp/godot_peek_*.png`. Editor screenshots capture active 2D/3D viewports. Game screenshots require the autoload that the plugin adds automatically.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `GODOT_MCP_URL` | `ws://localhost:6970` | WebSocket URL |

Plugin port is in `addons/godot_mcp/mcp_server.gd`.

## Requirements

- Godot 4.5+
- Any MCP client
- Go 1.21+ (only if building from source)
