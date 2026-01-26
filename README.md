# Godot MCP Server

A minimal MCP (Model Context Protocol) server that enables Claude Code to control the Godot 4.5+ editor. Run scenes, stop the game, and capture output - all from your AI assistant.

## Quick Start

### 1. Build the MCP Server

```bash
cd /path/to/godot-mcp-minimal
go build -o godot-mcp ./cmd/godot-mcp
```

### 2. Install Godot Plugin

Copy or symlink `addons/godot_mcp` to your Godot project:

```bash
# copy
cp -r addons/godot_mcp /path/to/your/godot/project/addons/

# or symlink (recommended for development)
ln -s /path/to/godot-mcp-minimal/addons/godot_mcp /path/to/your/godot/project/addons/godot_mcp
```

Then enable the plugin in Godot:
1. Project → Project Settings → Plugins
2. Enable "Godot MCP"

You should see in the Godot output panel:
```
[GodotMCP] Plugin enabled, WebSocket server starting on port 6970
```

### 3. Register with Claude Code

```bash
claude mcp add godot /path/to/godot-mcp-minimal/godot-mcp
```

Then restart Claude Code (or run `/mcp` to reload MCP servers).

### 4. Use It

With Godot open and the plugin enabled, ask Claude Code to:
- "Run the main scene in Godot"
- "Stop the game"
- "Run the scene at res://levels/level1.tscn"
- "Show me the game output"

Claude Code automatically spawns the MCP server when needed - no manual server management required.

## Available Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `run_main_scene` | Run the project's main scene (F5) | none |
| `run_scene` | Run a specific scene | `scene_path` (required) |
| `run_current_scene` | Run the currently open scene | none |
| `stop_scene` | Stop the running game | none |
| `get_status` | Check if a scene is running | none |
| `get_output` | Get captured print/error output | `clear` (optional) |

## How It Works

1. **Godot Plugin** runs a WebSocket server inside the editor (port 6970)
2. **Go MCP Server** connects to Godot via WebSocket and exposes tools via MCP protocol
3. **Claude Code** sends tool calls over stdio to the MCP server

```
┌─────────────────────┐     stdio      ┌─────────────────────┐
│   Claude Code       │◄──────────────►│    Go MCP Server    │
│   (MCP Client)      │                │   (stdio transport) │
└─────────────────────┘                └──────────┬──────────┘
                                                  │ WebSocket
                                                  │ ws://localhost:6970
                                       ┌──────────▼──────────┐
                                       │  Godot EditorPlugin │
                                       │  (WebSocket Server) │
                                       └─────────────────────┘
```

## Output Capture

The plugin captures runtime output from your game:
- `print()` statements
- `push_error()` and `push_warning()` calls
- Stack traces on errors

Output is buffered and can be retrieved with the `get_output` tool.

**Note**: Only captures output from the running game, not editor-side output (tool scripts, plugin code, etc.)

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GODOT_MCP_URL` | `ws://localhost:6970` | Godot WebSocket URL |

### Godot Plugin

The plugin uses port 6970 by default (configurable in `mcp_server.gd`).

## Requirements

- Godot 4.5+
- Go 1.21+
- Claude Code with MCP support

## Troubleshooting

**"not connected to Godot editor"**
- Make sure the Godot editor is running with the plugin enabled
- Check that port 6970 is not blocked/in use

**No output captured**
- Output capture only works when a scene is running
- Make sure your game code uses `print()`, not editor-side logging

**Connection refused**
- Verify the plugin is enabled in Project Settings → Plugins
- Check Godot's output panel for plugin startup messages

