package godot

import (
	"encoding/json"
	"sync/atomic"
)

// request ID counter
var requestID atomic.Int64

func nextID() int64 {
	return requestID.Add(1)
}

// Request represents a JSON-RPC style request to Godot
type Request struct {
	ID     int64       `json:"id"`
	Method string      `json:"method"`
	Params interface{} `json:"params,omitempty"`
}

// Response represents a JSON-RPC style response from Godot
type Response struct {
	ID     int64            `json:"id"`
	Result *json.RawMessage `json:"result,omitempty"`
	Error  *ResponseError   `json:"error,omitempty"`
}

// ResponseError represents an error in the response
type ResponseError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Notification represents an async message from Godot (no ID)
type Notification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// OutputNotification is the params for "output" notifications
type OutputNotification struct {
	Type      string  `json:"type"`
	Message   string  `json:"message"`
	Timestamp float64 `json:"timestamp"`
}

// Overrides is a map of autoload names to property overrides
type Overrides map[string]map[string]interface{}

// RunMainSceneParams for run_main_scene method
type RunMainSceneParams struct {
	Overrides Overrides `json:"overrides,omitempty"`
}

// RunSceneParams for run_scene method
type RunSceneParams struct {
	ScenePath string    `json:"scene_path"`
	Overrides Overrides `json:"overrides,omitempty"`
}

// RunCurrentSceneParams for run_current_scene method
type RunCurrentSceneParams struct {
	Overrides Overrides `json:"overrides,omitempty"`
}

// GetOutputParams for get_output method
type GetOutputParams struct {
	Clear   bool `json:"clear"`
	NewOnly bool `json:"new_only"`
}

// GetLocalsParams for get_debugger_locals method
type GetLocalsParams struct {
	FrameIndex int `json:"frame_index"`
}

// OutputResult from get_output
type OutputResult struct {
	Output      string `json:"output"`
	Length      int    `json:"length"`
	TotalLength int    `json:"total_length"`
}

// DebugErrorsResult from get_debugger_errors
type DebugErrorsResult struct {
	Errors string `json:"errors"`
	Length int    `json:"length"`
}

// StackTraceResult from get_debugger_stack_trace
type StackTraceResult struct {
	StackTrace string `json:"stack_trace"`
	Length     int    `json:"length"`
}

// LocalVariable represents a single local variable
type LocalVariable struct {
	Name  string `json:"name"`
	Value string `json:"value"`
	Type  string `json:"type"`
}

// LocalsResult from get_debugger_locals
type LocalsResult struct {
	Locals []LocalVariable `json:"locals"`
	Count  int             `json:"count"`
}

// GenericResult for simple success responses
type GenericResult struct {
	Success       bool   `json:"success"`
	Action        string `json:"action,omitempty"`
	ScenePath     string `json:"scene_path,omitempty"`
	ErrorDetected bool   `json:"error_detected,omitempty"`
	StackTrace    string `json:"stack_trace,omitempty"`
	Warnings      string `json:"warnings,omitempty"` // warnings from debugger errors tree (doesn't affect success)
}

// SceneTreeResult from get_remote_scene_tree
type SceneTreeResult struct {
	Tree   string `json:"tree"`
	Length int    `json:"length"`
}

// GetNodePropertiesParams for get_remote_node_properties method
type GetNodePropertiesParams struct {
	NodePath string `json:"node_path"`
}

// NodePropertiesResult from get_remote_node_properties
type NodePropertiesResult struct {
	NodePath   string          `json:"node_path"`
	Properties []LocalVariable `json:"properties"`
	Count      int             `json:"count"`
}

// GetScreenshotParams for get_screenshot method
type GetScreenshotParams struct {
	Target string `json:"target"` // "game" or "editor"
}

// ScreenshotResult from get_screenshot
type ScreenshotResult struct {
	Path   string  `json:"path"`
	Target string  `json:"target"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// MonitorMetric represents a single monitor metric (name/value pair)
type MonitorMetric struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// MonitorGroup represents a group of metrics (e.g., Time, Memory, Object)
type MonitorGroup struct {
	Group   string          `json:"group"`
	Metrics []MonitorMetric `json:"metrics"`
}

// MonitorsResult from get_monitors
type MonitorsResult struct {
	Monitors []MonitorGroup `json:"monitors"`
	Count    int            `json:"count"`
}
