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

// RunSceneParams for run_scene method
type RunSceneParams struct {
	ScenePath string `json:"scene_path"`
}

// GetOutputParams for get_output method
type GetOutputParams struct {
	Clear   bool `json:"clear"`
	NewOnly bool `json:"new_only"`
}

// StatusResult from get_status
type StatusResult struct {
	Playing         bool `json:"playing"`
	OutputAvailable bool `json:"output_available"`
	OutputLength    int  `json:"output_length"`
}

// OutputResult from get_output
type OutputResult struct {
	Output      string `json:"output"`
	Length      int    `json:"length"`
	TotalLength int    `json:"total_length"`
}

// GenericResult for simple success responses
type GenericResult struct {
	Success   bool   `json:"success"`
	Action    string `json:"action,omitempty"`
	ScenePath string `json:"scene_path,omitempty"`
}
