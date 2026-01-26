package tools

import (
	"context"
	"fmt"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
	"github.com/rafiq/godot-mcp/internal/godot"
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

	// get_status - check if game is running
	s.AddTool(
		mcp.NewTool("get_status",
			mcp.WithDescription("Get current Godot editor status (whether a scene is playing, output buffer size)"),
		),
		makeGetStatus(client),
	)

	// get_output - get buffered output/logs
	s.AddTool(
		mcp.NewTool("get_output",
			mcp.WithDescription("Get buffered output from the running game (print statements, errors, warnings)"),
			mcp.WithBoolean("clear",
				mcp.Description("If true, clear the output buffer after retrieving"),
			),
		),
		makeGetOutput(client),
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

func makeRunMainScene(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		if err := client.RunMainScene(ctx); err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run main scene: %v", err)), nil
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

		if err := client.RunScene(ctx, scenePath); err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run scene: %v", err)), nil
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

		if err := client.RunCurrentScene(ctx); err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to run current scene: %v", err)), nil
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

func makeGetStatus(client *godot.Client) server.ToolHandlerFunc {
	return func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		if !client.IsConnected() {
			return mcp.NewToolResultError("not connected to Godot editor"), nil
		}

		status, err := client.GetStatus(ctx)
		if err != nil {
			return mcp.NewToolResultError(fmt.Sprintf("failed to get status: %v", err)), nil
		}

		playingStr := "not running"
		if status.Playing {
			playingStr = "running"
		}

		outputStr := "not available"
		if status.OutputAvailable {
			outputStr = fmt.Sprintf("%d chars", status.OutputLength)
		}

		return mcp.NewToolResultText(fmt.Sprintf("Scene: %s\nOutput: %s", playingStr, outputStr)), nil
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
