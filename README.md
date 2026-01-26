# Godot Peek MCP

MCP (Model Context Protocol) server for peeking into Godot 4.5+ editor runtime. Run scenes, capture output, inspect debugger state - all programmatically.

## Features

- **Scene Control**: Run main/current/specific scenes, stop the game
- **Output Capture**: Read the Output panel (print statements, errors, warnings)
- **Debugger Integration**: Get errors, stack traces, and local variables when paused

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

### 3. Register with Claude Code

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

## Example Usage

With Claude Code:
- "Run the main scene for 5 seconds and show me the output"
- "What errors are in the debugger?"
- "Show me the local variables in the current stack frame"

Direct WebSocket testing:
```bash
wscat -c ws://localhost:6970

# run main scene
{"id":1,"method":"run_main_scene"}

# run with timeout
{"id":2,"method":"run_main_scene","params":{"timeout_seconds":5}}

# get output
{"id":3,"method":"get_output"}

# get stack trace (when paused on error)
{"id":4,"method":"get_debugger_stack_trace"}

# get locals for frame 0
{"id":5,"method":"get_debugger_locals","params":{"frame_index":0}}
```

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
Returns warnings and errors with source file/line info. Available while game is running or paused.

### Stack Trace (`get_debugger_stack_trace`)
Returns error message and call stack. Only populated when game is paused on an error.

### Local Variables (`get_debugger_locals`)
Returns all local variables for the selected stack frame. Use `frame_index` to select which frame (0 = where error occurred, higher = caller frames).

**Note**: Debugger locals require clicking a stack frame in Godot's UI first, or using `frame_index` to select programmatically.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `GODOT_MCP_URL` | `ws://localhost:6970` | Godot WebSocket URL |

The plugin port is configured in `addons/godot_mcp/mcp_server.gd` (default: 6970).

## Requirements

- Godot 4.5+
- Go 1.21+
- Claude Code with MCP support (or any MCP client)

## Troubleshooting

**"not connected to Godot editor"**
- Ensure Godot is running with the plugin enabled
- Check port 6970 is available

**Empty output**
- Output capture requires a scene to be running
- Use `get_output` after `run_main_scene`

**Empty stack trace / locals**
- These only populate when the game is paused on an error
- Trigger an error (e.g., null reference) to test

**Connection refused**
- Verify plugin is enabled in Project Settings → Plugins
- Look for `[GodotPeek]` messages in Godot's Output panel
