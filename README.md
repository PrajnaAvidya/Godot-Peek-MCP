# Godot Peek MCP

MCP (Model Context Protocol) server for peeking into Godot 4.5+ editor runtime. Run scenes, capture output, inspect debugger state - all programmatically.

## Features

- **Scene Control**: Run main/current/specific scenes, stop the game
- **Output Capture**: Read the Output panel (print statements, errors, warnings)
- **Debugger Integration**: Get errors, stack traces, and local variables when paused
- **Runtime Inspection**: Get the instantiated node tree from the running game

## Quick Start

### 1. Build the MCP Server

```bash
go build -o godot-peek-mcp ./cmd/godot-peek-mcp
```

### 2. Install Godot Plugin

Copy `addons/godot_mcp` to your Godot project:

```bash
cp -r addons/godot_mcp /path/to/your/godot/project/addons/
```

Enable in Godot: Project → Project Settings → Plugins → Enable "Godot Peek MCP"

You should see:
```
[GodotPeek] WebSocket server listening on ws://localhost:6970
```

### 3. Register with Claude Code (or other MCP)

```bash
claude mcp add godot-peek /path/to/godot-peek-mcp/godot-peek-mcp
```

Restart Claude Code or run `/mcp` to reload.

## Tools

### Scene Control

| Tool | Description | Parameters |
|------|-------------|------------|
| `run_main_scene` | Run project's main scene (F5) | `timeout_seconds` (optional) - auto-stop after N seconds |
| `run_scene` | Run a specific scene | `scene_path` (required), `timeout_seconds` (optional) |
| `run_current_scene` | Run currently open scene | `timeout_seconds` (optional) |
| `stop_scene` | Stop the running game | none |

### Output & Debugging

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_output` | Get Output panel content | `clear` (optional) - mark position for incremental reads |
| `get_debugger_errors` | Get Debugger Errors tab | none |
| `get_debugger_stack_trace` | Get stack trace when paused on error | none |
| `get_debugger_locals` | Get local variables for a stack frame | `frame_index` (optional) - 0=top frame |
| `get_remote_scene_tree` | Get instantiated node tree from running game | none |

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

## Debugger Details

### Output Capture (`get_output`)
Reads directly from Godot's Output panel. Captures:
- `print()` statements from running game
- `push_error()` / `push_warning()` calls
- Editor messages

### Errors Tab (`get_debugger_errors`)
Returns warnings and errors with source file/line info.

### Stack Trace (`get_debugger_stack_trace`)
Returns error message and call stack.

### Local Variables (`get_debugger_locals`)
Returns all local variables for the selected stack frame. Use `frame_index` to select which frame (0 = where error occurred, higher = caller frames).

### Remote Scene Tree (`get_remote_scene_tree`)
Returns the instantiated node tree from the running game. Shows "root" at top with autoloads and the active scene hierarchy. Only available while game is running.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `GODOT_MCP_URL` | `ws://localhost:6970` | Godot WebSocket URL |

The plugin port is configured in `addons/godot_mcp/mcp_server.gd` (default: 6970).

## Requirements

- Godot 4.5+
- Go 1.21+
- Claude Code (or any MCP client)
