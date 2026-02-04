package tools

import (
	"context"
	"fmt"

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
				mcp.Description("What to capture: 'editor' (2D+3D editor viewports) or 'game' (requires screenshot_listener autoload in game project)"),
			),
		),
		makeGetScreenshot(client),
	)

	// get_monitors - get engine performance monitors
	s.AddTool(
		mcp.NewTool("get_monitors",
			mcp.WithDescription("Get engine performance monitors (FPS, memory, object count, etc.) from the Debugger Monitors tab"),
		),
		makeGetMonitors(client),
	)

	// set_breakpoint - set or remove a breakpoint
	s.AddTool(
		mcp.NewTool("set_breakpoint",
			mcp.WithDescription("Set or remove a breakpoint at a specific file and line"),
			mcp.WithString("path",
				mcp.Required(),
				mcp.Description("Script file path, e.g. res://scripts/player.gd"),
			),
			mcp.WithNumber("line",
				mcp.Required(),
				mcp.Description("Line number (1-based)"),
			),
			mcp.WithBoolean("enabled",
				mcp.Description("True to set breakpoint, false to remove (default: true)"),
			),
		),
		makeSetBreakpoint(client),
	)

	// clear_breakpoints - remove all breakpoints
	s.AddTool(
		mcp.NewTool("clear_breakpoints",
			mcp.WithDescription("Remove all breakpoints"),
		),
		makeClearBreakpoints(client),
	)

	// get_debugger_state - check debugger state
	s.AddTool(
		mcp.NewTool("get_debugger_state",
			mcp.WithDescription("Get current debugger state: whether paused at breakpoint, session active, debuggable"),
		),
		makeGetDebuggerState(client),
	)

	// debug_continue - resume execution
	s.AddTool(
		mcp.NewTool("debug_continue",
			mcp.WithDescription("Resume execution after hitting a breakpoint"),
		),
		makeDebugContinue(client),
	)

	// debug_step - step through code
	s.AddTool(
		mcp.NewTool("debug_step",
			mcp.WithDescription("Step through code when paused at breakpoint"),
			mcp.WithString("mode",
				mcp.Description("Step mode: 'into' (step into function), 'over' (step over/next line), 'out' (step out of function). Default: 'over'"),
			),
		),
		makeDebugStep(client),
	)

	// debug_break - pause execution
	s.AddTool(
		mcp.NewTool("debug_break",
			mcp.WithDescription("Pause execution of the running game"),
		),
		makeDebugBreak(client),
	)

	// evaluate_expression - evaluate GDScript in running game
	s.AddTool(
		mcp.NewTool("evaluate_expression",
			mcp.WithDescription("Evaluate a GDScript expression in the running game. Can access scene tree, call methods, get/set properties. Requires game to be running with peek_runtime_helper autoload. Note: use .set('prop', value) to modify properties - assignment operators don't work in Expression class."),
			mcp.WithString("expression",
				mcp.Required(),
				mcp.Description("GDScript expression to evaluate, e.g. 'get_node(\"/root/Main/Player\").health' or 'get_node(\"/root/Main\").set(\"speed\", 10)'"),
			),
		),
		makeEvaluateExpression(client),
	)

	// send_input - inject input events into running game
	s.AddTool(
		mcp.NewTool("send_input",
			mcp.WithDescription("Send fake input events to the running game. Useful for automated testing. Requires game to be running with peek_runtime_helper autoload."),
			mcp.WithString("type",
				mcp.Required(),
				mcp.Description("Input type: 'action', 'key', 'mouse_button', or 'mouse_motion'"),
			),
			mcp.WithString("action",
				mcp.Description("Action name for type='action' (e.g., 'jump', 'fire', 'ui_accept')"),
			),
			mcp.WithString("keycode",
				mcp.Description("Key code for type='key' (e.g., 'W', 'SPACE', 'ESCAPE')"),
			),
			mcp.WithString("button",
				mcp.Description("Mouse button for type='mouse_button': 'left', 'right', 'middle', 'wheel_up', 'wheel_down'"),
			),
			mcp.WithBoolean("pressed",
				mcp.Description("Whether key/button is pressed (default: true)"),
			),
			mcp.WithNumber("strength",
				mcp.Description("Analog strength 0.0-1.0 for actions (default: 1.0)"),
			),
			mcp.WithArray("position",
				mcp.Description("Mouse position [x, y] for mouse events"),
			),
			mcp.WithArray("relative",
				mcp.Description("Relative motion [x, y] for mouse_motion"),
			),
		),
		makeSendInput(client),
	)
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

		timeout := getTimeoutArg(req)
		overrides := getOverridesArg(req)
		result, err := client.RunMainScene(ctx, overrides, timeout)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run main scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		msg := "Main scene started successfully"
		if timeout > 0 {
			msg = fmt.Sprintf("Main scene started (will auto-stop in %.1fs)", timeout)
		}
		if result.Warnings != "" {
			msg += fmt.Sprintf("\n\nWarnings:\n%s", result.Warnings)
		}

		return mcp.NewToolResultText(msg), nil
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

		timeout := getTimeoutArg(req)
		overrides := getOverridesArg(req)
		result, err := client.RunScene(ctx, scenePath, overrides, timeout)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		msg := fmt.Sprintf("Scene started: %s", scenePath)
		if timeout > 0 {
			msg = fmt.Sprintf("Scene started: %s (will auto-stop in %.1fs)", scenePath, timeout)
		}
		if result.Warnings != "" {
			msg += fmt.Sprintf("\n\nWarnings:\n%s", result.Warnings)
		}

		return mcp.NewToolResultText(msg), nil
	}
}

func makeRunCurrentScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		timeout := getTimeoutArg(req)
		overrides := getOverridesArg(req)
		result, err := client.RunCurrentScene(ctx, overrides, timeout)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run current scene: %v", err)), nil
		}

		if result.ErrorDetected {
			return mcp.NewToolResultError(fmt.Sprintf("Scene crashed on startup:\n\n%s", result.StackTrace)), nil
		}

		msg := "Current scene started successfully"
		if timeout > 0 {
			msg = fmt.Sprintf("Current scene started (will auto-stop in %.1fs)", timeout)
		}
		if result.Warnings != "" {
			msg += fmt.Sprintf("\n\nWarnings:\n%s", result.Warnings)
		}

		return mcp.NewToolResultText(msg), nil
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

		if target != "editor" && target != "game" {
			return mcp.NewToolResultError("target must be 'editor' or 'game'"), nil
		}

		result, err := client.GetScreenshot(ctx, target)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get screenshot: %v", err)), nil
		}

		return mcp.NewToolResultText(fmt.Sprintf("Screenshot saved: %s (%.0fx%.0f)", result.Path, result.Width, result.Height)), nil
	}
}

func makeGetMonitors(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		result, err := client.GetMonitors(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get monitors: %v", err)), nil
		}

		if result.Count == 0 {
			return mcp.NewToolResultText("No monitors data"), nil
		}

		// format as readable grouped text
		var output string
		for _, group := range result.Monitors {
			output += fmt.Sprintf("%s:\n", group.Group)
			for _, metric := range group.Metrics {
				output += fmt.Sprintf("  %s: %s\n", metric.Name, metric.Value)
			}
		}

		return mcp.NewToolResultText(output), nil
	}
}

func makeSetBreakpoint(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		path, err := req.RequireString("path")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: path"), nil
		}

		lineFloat, err := req.RequireFloat("line")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: line"), nil
		}
		line := int(lineFloat)

		enabled := true
		args := req.GetArguments()
		if args != nil {
			if v, ok := args["enabled"].(bool); ok {
				enabled = v
			}
		}

		_, err = client.SetBreakpoint(ctx, path, line, enabled)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to set breakpoint: %v", err)), nil
		}

		if enabled {
			return mcp.NewToolResultText(fmt.Sprintf("Breakpoint set at %s:%d", path, line)), nil
		}
		return mcp.NewToolResultText(fmt.Sprintf("Breakpoint removed at %s:%d", path, line)), nil
	}
}

func makeClearBreakpoints(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		_, err := client.ClearBreakpoints(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to clear breakpoints: %v", err)), nil
		}

		return mcp.NewToolResultText("All breakpoints cleared"), nil
	}
}

func makeGetDebuggerState(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		result, err := client.GetDebuggerState(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get debugger state: %v", err)), nil
		}

		var output string
		if result.Paused {
			output = "Debugger: PAUSED at breakpoint\n"
		} else {
			output = "Debugger: running\n"
		}
		output += fmt.Sprintf("Active: %v\n", result.Active)
		output += fmt.Sprintf("Debuggable: %v", result.Debuggable)

		return mcp.NewToolResultText(output), nil
	}
}

func makeDebugContinue(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		_, err := client.DebugContinue(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to continue: %v", err)), nil
		}

		return mcp.NewToolResultText("Execution resumed"), nil
	}
}

func makeDebugStep(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		mode := "over"
		args := req.GetArguments()
		if args != nil {
			if v, ok := args["mode"].(string); ok && v != "" {
				mode = v
			}
		}

		if mode != "into" && mode != "over" && mode != "out" {
			return mcp.NewToolResultError("mode must be 'into', 'over', or 'out'"), nil
		}

		_, err := client.DebugStep(ctx, mode)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to step: %v", err)), nil
		}

		modeDesc := map[string]string{
			"into": "Stepped into function",
			"over": "Stepped to next line",
			"out":  "Stepped out of function",
		}
		return mcp.NewToolResultText(modeDesc[mode]), nil
	}
}

func makeDebugBreak(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		_, err := client.DebugBreak(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to break: %v", err)), nil
		}

		return mcp.NewToolResultText("Break requested"), nil
	}
}

func makeEvaluateExpression(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		// note: doesn't require C++ connection, talks directly to game via UDP
		expression, err := req.RequireString("expression")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: expression"), nil
		}

		result, err := client.EvaluateExpression(ctx, expression)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to evaluate: %v", err)), nil
		}

		return mcp.NewToolResultText(fmt.Sprintf("%s (%s)", result.Value, result.Type)), nil
	}
}

func makeSendInput(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		// note: doesn't require C++ connection, talks directly to game via UDP
		inputType, err := req.RequireString("type")
		if err != nil {
			return mcp.NewToolResultError("missing required parameter: type"), nil
		}

		// validate input type
		validTypes := map[string]bool{"action": true, "key": true, "mouse_button": true, "mouse_motion": true}
		if !validTypes[inputType] {
			return mcp.NewToolResultError("type must be 'action', 'key', 'mouse_button', or 'mouse_motion'"), nil
		}

		// build params map from request arguments
		params := make(map[string]interface{})
		args := req.GetArguments()
		if args != nil {
			if v, ok := args["action"].(string); ok {
				params["action"] = v
			}
			if v, ok := args["keycode"].(string); ok {
				params["keycode"] = v
			}
			if v, ok := args["button"].(string); ok {
				params["button"] = v
			}
			if v, ok := args["pressed"].(bool); ok {
				params["pressed"] = v
			} else {
				params["pressed"] = true // default
			}
			if v, ok := args["strength"].(float64); ok {
				params["strength"] = v
			}
			if v, ok := args["position"].([]interface{}); ok {
				params["position"] = v
			}
			if v, ok := args["relative"].([]interface{}); ok {
				params["relative"] = v
			}
		}

		result, err := client.SendInput(ctx, inputType, params)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to send input: %v", err)), nil
		}

		return mcp.NewToolResultText(fmt.Sprintf("Input sent: %s", result.Type)), nil
	}
}
