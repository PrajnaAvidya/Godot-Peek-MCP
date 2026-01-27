package tools

import (
	"context"
	"fmt"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
	"github.com/PrajnaAvidya/godot-peek-mcp/internal/godot"
)

// Register adds all Godot tools to the MCP server
func Register(s *server.MCPServer, client *godot.Client) {
	// run_main_scene - F5 equivalent
	s.AddTool(
		mcp.NewTool("run_main_scene",
			mcp.WithDescription("Run the project's main scene (equivalent to F5 in Godot editor)"),
			mcp.WithNumber("timeout_seconds",
				mcp.Description("Auto-stop the scene after this many seconds"),
			),
			mcp.WithObject("overrides",
				mcp.Description("Override autoload variables on startup. Map of autoload names to property overrides, e.g. {\"DebugManager\": {\"debug_mode\": true}}"),
			),
		),
		makeRunMainScene(client),
	)

	// run_scene - run specific scene
	s.AddTool(
		mcp.NewTool("run_scene",
			mcp.WithDescription("Run a specific scene file"),
			mcp.WithString("scene_path",
				mcp.Required(),
				mcp.Description("Path to scene file, e.g. res://scenes/game.tscn"),
			),
			mcp.WithNumber("timeout_seconds",
				mcp.Description("Auto-stop the scene after this many seconds"),
			),
			mcp.WithObject("overrides",
				mcp.Description("Override autoload variables on startup. Map of autoload names to property overrides, e.g. {\"DebugManager\": {\"debug_mode\": true}}"),
			),
		),
		makeRunScene(client),
	)

	// run_current_scene - run currently open scene
	s.AddTool(
		mcp.NewTool("run_current_scene",
			mcp.WithDescription("Run the currently open scene in the editor"),
			mcp.WithNumber("timeout_seconds",
				mcp.Description("Auto-stop the scene after this many seconds"),
			),
			mcp.WithObject("overrides",
				mcp.Description("Override autoload variables on startup. Map of autoload names to property overrides, e.g. {\"DebugManager\": {\"debug_mode\": true}}"),
			),
		),
		makeRunCurrentScene(client),
	)

	// stop_scene - stop running game
	s.AddTool(
		mcp.NewTool("stop_scene",
			mcp.WithDescription("Stop the currently running game/scene"),
		),
		makeStopScene(client),
	)

	// get_output - get buffered output/logs
	s.AddTool(
		mcp.NewTool("get_output",
			mcp.WithDescription("Get output from the Godot Output panel (print statements, errors, warnings)"),
			mcp.WithBoolean("new_only",
				mcp.Description("If true, return only output since last call with clear=true"),
			),
			mcp.WithBoolean("clear",
				mcp.Description("If true, mark current position for future new_only calls"),
			),
		),
		makeGetOutput(client),
	)

	// get_debugger_errors - get debugger errors/warnings
	s.AddTool(
		mcp.NewTool("get_debugger_errors",
			mcp.WithDescription("Get errors and warnings from the Godot Debugger Errors tab"),
		),
		makeGetDebugErrors(client),
	)

	// get_debugger_stack_trace - get stack trace on runtime error
	s.AddTool(
		mcp.NewTool("get_debugger_stack_trace",
			mcp.WithDescription("Get stack trace from Godot Debugger (populated when game crashes/pauses on error)"),
		),
		makeGetStackTrace(client),
	)

	// get_debugger_locals - get local variables for selected stack frame
	s.AddTool(
		mcp.NewTool("get_debugger_locals",
			mcp.WithDescription("Get local variables from Godot Debugger for a specific stack frame"),
			mcp.WithNumber("frame_index",
				mcp.Description("Stack frame index (0=top/current, higher=callers). Defaults to currently selected frame."),
			),
		),
		makeGetLocals(client),
	)

	// get_remote_scene_tree - get instantiated node tree from running game
	s.AddTool(
		mcp.NewTool("get_remote_scene_tree",
			mcp.WithDescription("Get instantiated node tree from running game (requires game to be running)"),
		),
		makeGetRemoteSceneTree(client),
	)

	// get_remote_node_properties - get properties of a specific node from running game
	s.AddTool(
		mcp.NewTool("get_remote_node_properties",
			mcp.WithDescription("Get properties of a specific node from the running game (requires game to be running)"),
			mcp.WithString("node_path",
				mcp.Required(),
				mcp.Description("Path to node in remote scene tree, e.g. /root/game/Player"),
			),
		),
		makeGetRemoteNodeProperties(client),
	)

	// get_screenshot - capture game or editor viewport
	s.AddTool(
		mcp.NewTool("get_screenshot",
			mcp.WithDescription("Capture a screenshot from the running game or editor viewports. Returns file path to PNG image."),
			mcp.WithString("target",
				mcp.Required(),
				mcp.Description("What to capture: 'game' (running game viewport, requires screenshot_listener autoload) or 'editor' (combined 2D+3D editor viewports)"),
			),
		),
		makeGetScreenshot(client),
	)
}

// scheduleAutoStop spawns a goroutine to stop the scene after timeout seconds
func scheduleAutoStop(client *godot.Client, timeout float64) {
	go func() {
		time.Sleep(time.Duration(timeout * float64(time.Second)))
		client.StopScene(context.Background())
	}()
}

// getTimeoutArg extracts the optional timeout_seconds arg from request
func getTimeoutArg(req mcp.CallToolRequest) float64 {
	args := req.GetArguments()
	if args == nil {
		return 0
	}
	if v, ok := args["timeout_seconds"].(float64); ok && v > 0 {
		return v
	}
	return 0
}

// getOverridesArg extracts the optional overrides arg from request
func getOverridesArg(req mcp.CallToolRequest) godot.Overrides {
	args := req.GetArguments()
	if args == nil {
		return nil
	}
	raw, ok := args["overrides"].(map[string]interface{})
	if !ok {
		return nil
	}
	// convert to Overrides type
	result := make(godot.Overrides)
	for autoloadName, props := range raw {
		if propsMap, ok := props.(map[string]interface{}); ok {
			result[autoloadName] = propsMap
		}
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

func makeRunMainScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		overrides := getOverridesArg(req)
		result, err := client.RunMainScene(ctx, overrides)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run main scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		timeout := getTimeoutArg(req)
		if timeout > 0 {
			scheduleAutoStop(client, timeout)
			return mcp.NewToolResultText(fmt.Sprintf("Main scene started (will auto-stop in %.1fs)", timeout)), nil
		}

		return mcp.NewToolResultText("Main scene started successfully"), nil
	}
}

func makeRunScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		scenePath, err := req.RequireString("scene_path")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: scene_path"), nil
		}

		overrides := getOverridesArg(req)
		result, err := client.RunScene(ctx, scenePath, overrides)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		timeout := getTimeoutArg(req)
		if timeout > 0 {
			scheduleAutoStop(client, timeout)
			return mcp.NewToolResultText(fmt.Sprintf("Scene started: %s (will auto-stop in %.1fs)", scenePath, timeout)), nil
		}

		return mcp.NewToolResultText(fmt.Sprintf("Scene started: %s", scenePath)), nil
	}
}

func makeRunCurrentScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		overrides := getOverridesArg(req)
		result, err := client.RunCurrentScene(ctx, overrides)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run current scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		timeout := getTimeoutArg(req)
		if timeout > 0 {
			scheduleAutoStop(client, timeout)
			return mcp.NewToolResultText(fmt.Sprintf("Current scene started (will auto-stop in %.1fs)", timeout)), nil
		}

		return mcp.NewToolResultText("Current scene started successfully"), nil
	}
}

func makeStopScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		if err := client.StopScene(ctx); err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to stop scene: %v", err)), nil
		}

		return mcp.NewToolResultText("Scene stopped"), nil
	}
}

func makeGetOutput(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		clear := false
		newOnly := false
		args := req.GetArguments()
		if args != nil {
			if v, ok := args["clear"].(bool); ok {
				clear = v
			}
			if v, ok := args["new_only"].(bool); ok {
				newOnly = v
			}
		}

		output, err := client.GetOutputFromGodot(ctx, clear, newOnly)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get output: %v", err)), nil
		}

		if output.Length == 0 {
			return mcp.NewToolResultText("No output"), nil
		}

		return mcp.NewToolResultText(output.Output), nil
	}
}

func makeGetDebugErrors(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		result, err := client.GetDebugErrors(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get debug errors: %v", err)), nil
		}

		if result.Length == 0 {
			return mcp.NewToolResultText("No errors"), nil
		}

		return mcp.NewToolResultText(result.Errors), nil
	}
}

func makeGetStackTrace(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		result, err := client.GetStackTrace(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get stack trace: %v", err)), nil
		}

		if result.Length == 0 {
			return mcp.NewToolResultText("No stack trace (game not paused on error)"), nil
		}

		return mcp.NewToolResultText(result.StackTrace), nil
	}
}

func makeGetLocals(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		frameIndex := -1 // default: use currently selected frame
		args := req.GetArguments()
		if args != nil {
			if v, ok := args["frame_index"].(float64); ok {
				frameIndex = int(v)
			}
		}

		result, err := client.GetLocals(ctx, frameIndex)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get locals: %v", err)), nil
		}

		if result.Count == 0 {
			return mcp.NewToolResultText("No locals (game not paused on error, or no frame selected)"), nil
		}

		// format as readable text
		var output string
		for _, local := range result.Locals {
			output += fmt.Sprintf("%s = %s\n", local.Name, local.Value)
		}

		return mcp.NewToolResultText(output), nil
	}
}

func makeGetRemoteSceneTree(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		result, err := client.GetRemoteSceneTree(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get remote scene tree: %v", err)), nil
		}

		if result.Length == 0 {
			return mcp.NewToolResultText("No scene tree (game not running)"), nil
		}

		return mcp.NewToolResultText(result.Tree), nil
	}
}

func makeGetRemoteNodeProperties(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		nodePath, err := req.RequireString("node_path")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: node_path"), nil
		}

		result, err := client.GetRemoteNodeProperties(ctx, nodePath)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get node properties: %v", err)), nil
		}

		if result.Count == 0 {
			return mcp.NewToolResultText("No properties (node not found or game not running)"), nil
		}

		// format as readable text
		var output string
		for _, prop := range result.Properties {
			output += fmt.Sprintf("%s = %s\n", prop.Name, prop.Value)
		}

		return mcp.NewToolResultText(output), nil
	}
}

func makeGetScreenshot(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		target, err := req.RequireString("target")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: target"), nil
		}

		if target != "game" && target != "editor" {
			return mcp.NewToolResultError("target must be 'game' or 'editor'"), nil
		}

		result, err := client.GetScreenshot(ctx, target)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get screenshot: %v", err)), nil
		}

		return mcp.NewToolResultText(fmt.Sprintf("Screenshot saved: %s (%.0fx%.0f)", result.Path, result.Width, result.Height)), nil
	}
}
