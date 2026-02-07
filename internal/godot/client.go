package godot

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"time"
)

const (
	DefaultSocketPath   = "/tmp/godot-peek.sock"
	OverridesPath       = "/tmp/godot_peek_overrides.json"
	MaxReconnectBackoff = 30 * time.Second
	MaxOutputBuffer     = 1000
)

// Client manages Unix socket connection to Godot editor plugin
type Client struct {
	socketPath string

	mu           sync.RWMutex
	conn         net.Conn
	reader       *bufio.Scanner
	connected    bool
	outputBuffer []OutputNotification

	// pending requests waiting for response
	pending   map[int64]chan *Response
	pendingMu sync.Mutex

	// channel for output notifications
	outputCh chan OutputNotification

	ctx    context.Context
	cancel context.CancelFunc
}

// NewClient creates a new Godot client
func NewClient(socketPath string) *Client {
	if socketPath == "" {
		socketPath = os.Getenv("GODOT_PEEK_SOCKET")
		if socketPath == "" {
			socketPath = DefaultSocketPath
		}
	}

	ctx, cancel := context.WithCancel(context.Background())

	c := &Client{
		socketPath: socketPath,
		pending:    make(map[int64]chan *Response),
		outputCh:   make(chan OutputNotification, 100),
		ctx:        ctx,
		cancel:     cancel,
	}

	return c
}

// Connect establishes connection to Godot
func (c *Client) Connect(ctx context.Context) error {
	conn, err := net.Dial("unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("dial unix socket: %w", err)
	}

	c.mu.Lock()
	c.conn = conn
	c.reader = bufio.NewScanner(conn)
	c.connected = true
	c.mu.Unlock()

	// start reading messages
	go c.readLoop()

	log.Printf("[godot] Connected to %s", c.socketPath)
	return nil
}

// IsConnected returns current connection state
func (c *Client) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

// Close shuts down the client
func (c *Client) Close() error {
	c.cancel()

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// readLoop handles incoming messages from Unix socket
func (c *Client) readLoop() {
	defer func() {
		c.mu.Lock()
		c.connected = false
		c.mu.Unlock()
	}()

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		c.mu.RLock()
		reader := c.reader
		c.mu.RUnlock()

		if reader == nil {
			return
		}

		// read one line (newline-delimited JSON)
		if !reader.Scan() {
			if err := reader.Err(); err != nil {
				if c.ctx.Err() == nil {
					log.Printf("[godot] Read error: %v", err)
				}
			}
			return
		}

		data := reader.Bytes()
		if len(data) == 0 {
			continue
		}

		c.handleMessage(data)
	}
}

// handleMessage processes a raw message
func (c *Client) handleMessage(data []byte) {
	log.Printf("[godot] Received message: %s", string(data)[:min(len(data), 200)])

	// try to parse as response (has id)
	var msg struct {
		ID     *float64        `json:"id"`
		Method string          `json:"method"`
		Result json.RawMessage `json:"result"`
		Error  *ResponseError  `json:"error"`
		Params json.RawMessage `json:"params"`
	}

	if err := json.Unmarshal(data, &msg); err != nil {
		log.Printf("[godot] Failed to parse message: %v", err)
		return
	}

	// if has ID, it's a response
	if msg.ID != nil {
		id := int64(*msg.ID)
		log.Printf("[godot] Response for request id=%d", id)

		resp := &Response{
			ID:    id,
			Error: msg.Error,
		}
		if msg.Result != nil {
			resp.Result = &msg.Result
		}

		c.pendingMu.Lock()
		ch, ok := c.pending[id]
		if ok {
			delete(c.pending, id)
		}
		c.pendingMu.Unlock()

		if ok {
			log.Printf("[godot] Dispatching response to waiting handler")
			ch <- resp
		} else {
			log.Printf("[godot] No pending request for id=%d", id)
		}
		return
	}

	// else it's a notification
	if msg.Method == "output" {
		var out OutputNotification
		if err := json.Unmarshal(msg.Params, &out); err == nil {
			c.addOutput(out)
		}
	}
}

// addOutput adds to output buffer
func (c *Client) addOutput(out OutputNotification) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.outputBuffer = append(c.outputBuffer, out)

	// trim buffer
	if len(c.outputBuffer) > MaxOutputBuffer {
		c.outputBuffer = c.outputBuffer[len(c.outputBuffer)-MaxOutputBuffer:]
	}

	// non-blocking send to channel
	select {
	case c.outputCh <- out:
	default:
	}
}

// GetOutput returns buffered output
func (c *Client) GetOutput(clear bool) []OutputNotification {
	c.mu.Lock()
	defer c.mu.Unlock()

	result := make([]OutputNotification, len(c.outputBuffer))
	copy(result, c.outputBuffer)

	if clear {
		c.outputBuffer = nil
	}

	return result
}

// writeOverrides writes the overrides file for the runtime helper to read
func writeOverrides(overrides Overrides) error {
	if len(overrides) == 0 {
		// delete file if exists
		os.Remove(OverridesPath)
		return nil
	}

	data, err := json.Marshal(overrides)
	if err != nil {
		return fmt.Errorf("marshal overrides: %w", err)
	}

	if err := os.WriteFile(OverridesPath, data, 0644); err != nil {
		return fmt.Errorf("write overrides file: %w", err)
	}

	log.Printf("[godot] Wrote overrides to %s", OverridesPath)
	return nil
}

// sendRequest sends a request and waits for response
func (c *Client) sendRequest(ctx context.Context, method string, params interface{}) (*Response, error) {
	c.mu.RLock()
	conn := c.conn
	connected := c.connected
	c.mu.RUnlock()

	if !connected || conn == nil {
		return nil, fmt.Errorf("not connected to Godot")
	}

	id := nextID()
	req := Request{
		ID:     id,
		Method: method,
		Params: params,
	}

	data, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	// add newline delimiter for line-based protocol
	data = append(data, '\n')

	// register pending request
	respCh := make(chan *Response, 1)
	c.pendingMu.Lock()
	c.pending[id] = respCh
	c.pendingMu.Unlock()

	defer func() {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
	}()

	// send message
	if _, err := conn.Write(data); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}

	// wait for response
	select {
	case resp := <-respCh:
		return resp, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("request timed out")
	}
}

// checkStartupErrors waits for the game to initialize, then checks if it
// crashed on startup (runtime error or parser error). populates result fields
// if an error is detected and auto-stops the crashed game.
func (c *Client) checkStartupErrors(ctx context.Context, result *GenericResult, timeout float64) {
	// skip check if timeout is shorter than our delay (game will auto-stop first)
	if timeout > 0 && timeout < 1.5 {
		return
	}

	time.Sleep(1500 * time.Millisecond)

	state, err := c.GetDebuggerState(ctx)
	if err != nil {
		return // can't check, assume ok
	}

	// runtime error: debugger paused on error in _ready() or similar
	if state.Paused {
		trace, err := c.GetStackTrace(ctx)
		if err == nil && trace.Length > 0 {
			result.ErrorDetected = true
			result.StackTrace = trace.StackTrace
		} else {
			result.ErrorDetected = true
			result.StackTrace = "Game paused on error (no stack trace available)"
		}
		// stop the crashed game
		c.StopScene(ctx)
		return
	}

	// game didn't start: parser error or immediate crash
	if !state.IsPlaying {
		errors, err := c.GetDebugErrors(ctx)
		if err == nil && errors.Length > 0 {
			result.ErrorDetected = true
			result.StackTrace = errors.Errors
		} else {
			result.ErrorDetected = true
			result.StackTrace = "Game failed to start. Use get_output for details."
		}
		return
	}

	// game running normally
}

// RunMainScene starts the project's main scene
func (c *Client) RunMainScene(ctx context.Context, overrides Overrides, timeout float64) (*GenericResult, error) {
	// write overrides file before sending command
	if err := writeOverrides(overrides); err != nil {
		return nil, fmt.Errorf("write overrides: %w", err)
	}

	// only send timeout_seconds in params (overrides handled via file)
	params := struct {
		TimeoutSeconds float64 `json:"timeout_seconds,omitempty"`
	}{TimeoutSeconds: timeout}

	resp, err := c.sendRequest(ctx, "run_main_scene", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}

	c.checkStartupErrors(ctx, &result, timeout)
	return &result, nil
}

// RunScene starts a specific scene
func (c *Client) RunScene(ctx context.Context, scenePath string, overrides Overrides, timeout float64) (*GenericResult, error) {
	// write overrides file before sending command
	if err := writeOverrides(overrides); err != nil {
		return nil, fmt.Errorf("write overrides: %w", err)
	}

	// only send scene_path and timeout_seconds in params
	params := struct {
		ScenePath      string  `json:"scene_path"`
		TimeoutSeconds float64 `json:"timeout_seconds,omitempty"`
	}{ScenePath: scenePath, TimeoutSeconds: timeout}

	resp, err := c.sendRequest(ctx, "run_scene", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}

	c.checkStartupErrors(ctx, &result, timeout)
	return &result, nil
}

// RunCurrentScene starts the currently open scene
func (c *Client) RunCurrentScene(ctx context.Context, overrides Overrides, timeout float64) (*GenericResult, error) {
	// write overrides file before sending command
	if err := writeOverrides(overrides); err != nil {
		return nil, fmt.Errorf("write overrides: %w", err)
	}

	// only send timeout_seconds in params
	params := struct {
		TimeoutSeconds float64 `json:"timeout_seconds,omitempty"`
	}{TimeoutSeconds: timeout}

	resp, err := c.sendRequest(ctx, "run_current_scene", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}

	c.checkStartupErrors(ctx, &result, timeout)
	return &result, nil
}

// StopScene stops the running game
func (c *Client) StopScene(ctx context.Context) error {
	resp, err := c.sendRequest(ctx, "stop_scene", nil)
	if err != nil {
		return err
	}
	if resp.Error != nil {
		return fmt.Errorf("godot error: %s", resp.Error.Message)
	}
	return nil
}

// GetOutputFromGodot fetches output buffer from Godot directly
func (c *Client) GetOutputFromGodot(ctx context.Context, clear bool, newOnly bool) (*OutputResult, error) {
	resp, err := c.sendRequest(ctx, "get_output", GetOutputParams{Clear: clear, NewOnly: newOnly})
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result OutputResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetDebugErrors fetches errors/warnings from debugger
func (c *Client) GetDebugErrors(ctx context.Context) (*DebugErrorsResult, error) {
	resp, err := c.sendRequest(ctx, "get_debugger_errors", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result DebugErrorsResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetStackTrace fetches stack trace from debugger (populated on runtime errors)
func (c *Client) GetStackTrace(ctx context.Context) (*StackTraceResult, error) {
	resp, err := c.sendRequest(ctx, "get_debugger_stack_trace", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result StackTraceResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetLocals fetches local variables from debugger for a specific stack frame
func (c *Client) GetLocals(ctx context.Context, frameIndex int) (*LocalsResult, error) {
	params := GetLocalsParams{FrameIndex: frameIndex}
	resp, err := c.sendRequest(ctx, "get_debugger_locals", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result LocalsResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetRemoteSceneTree fetches instantiated node tree from running game
// automatically retries once if the C++ extension indicates pending (Remote button was just clicked)
func (c *Client) GetRemoteSceneTree(ctx context.Context) (*SceneTreeResult, error) {
	resp, err := c.sendRequest(ctx, "get_remote_scene_tree", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result SceneTreeResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}

	// if pending, wait and retry once (Remote button was clicked, tree needs time to populate)
	if result.Pending {
		time.Sleep(150 * time.Millisecond)

		resp, err = c.sendRequest(ctx, "get_remote_scene_tree", nil)
		if err != nil {
			return nil, err
		}
		if resp.Error != nil {
			return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
		}

		if resp.Result != nil {
			if err := json.Unmarshal(*resp.Result, &result); err != nil {
				return nil, fmt.Errorf("unmarshal result: %w", err)
			}
		}
	}

	return &result, nil
}

// GetRemoteNodeProperties fetches properties of a specific node from running game
func (c *Client) GetRemoteNodeProperties(ctx context.Context, nodePath string) (*NodePropertiesResult, error) {
	params := GetNodePropertiesParams{NodePath: nodePath}
	resp, err := c.sendRequest(ctx, "get_remote_node_properties", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result NodePropertiesResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}

	// auto-retry if pending (inspector needs time to populate after node selection)
	if result.Pending {
		time.Sleep(350 * time.Millisecond)
		resp, err = c.sendRequest(ctx, "get_remote_node_properties", params)
		if err != nil {
			return nil, err
		}
		if resp.Error != nil {
			return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
		}
		if resp.Result != nil {
			if err := json.Unmarshal(*resp.Result, &result); err != nil {
				return nil, fmt.Errorf("unmarshal result: %w", err)
			}
		}
	}

	return &result, nil
}

// GetScreenshot captures a screenshot from game or editor viewports
// game target uses direct UDP to autoload, editor target goes through C++
func (c *Client) GetScreenshot(ctx context.Context, target string) (*ScreenshotResult, error) {
	// game screenshots go directly via UDP (no C++ passthrough needed)
	if target == "game" {
		return c.GetGameScreenshot(ctx)
	}

	// editor screenshots require C++ (needs editor viewport access)
	params := GetScreenshotParams{Target: target}
	resp, err := c.sendRequest(ctx, "get_screenshot", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result ScreenshotResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetMonitors fetches engine performance monitors from debugger
func (c *Client) GetMonitors(ctx context.Context) (*MonitorsResult, error) {
	resp, err := c.sendRequest(ctx, "get_monitors", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result MonitorsResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// SetBreakpoint sets or clears a breakpoint at a specific file:line
func (c *Client) SetBreakpoint(ctx context.Context, path string, line int, enabled bool) (*GenericResult, error) {
	params := SetBreakpointParams{
		Path:    path,
		Line:    line,
		Enabled: enabled,
	}
	resp, err := c.sendRequest(ctx, "set_breakpoint", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// ClearBreakpoints removes all breakpoints
func (c *Client) ClearBreakpoints(ctx context.Context) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "clear_breakpoints", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// GetDebuggerState returns the current debugger state (paused, active, debuggable)
func (c *Client) GetDebuggerState(ctx context.Context) (*DebuggerStateResult, error) {
	resp, err := c.sendRequest(ctx, "get_debugger_state", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result DebuggerStateResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// DebugContinue resumes execution after hitting a breakpoint
func (c *Client) DebugContinue(ctx context.Context) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "debug_continue", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// DebugStep performs a step operation (into, over, or out)
func (c *Client) DebugStep(ctx context.Context, mode string) (*GenericResult, error) {
	params := DebugStepParams{Mode: mode}
	resp, err := c.sendRequest(ctx, "debug_step", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// DebugBreak pauses execution of the running game
func (c *Client) DebugBreak(ctx context.Context) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "debug_break", nil)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("godot error: %s", resp.Error.Message)
	}

	var result GenericResult
	if resp.Result != nil {
		if err := json.Unmarshal(*resp.Result, &result); err != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
	}
	return &result, nil
}

// UDP port for game autoload (peek_runtime_helper.gd)
const GameUDPPort = 6971

// sendGameUDP sends a request directly to the game autoload via UDP
// bypasses C++ extension for game-side operations
func sendGameUDP(ctx context.Context, request interface{}) ([]byte, error) {
	data, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	// resolve UDP address
	addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", GameUDPPort))
	if err != nil {
		return nil, fmt.Errorf("resolve udp addr: %w", err)
	}

	// create UDP connection
	conn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		return nil, fmt.Errorf("dial udp: %w", err)
	}
	defer conn.Close()

	// set deadline based on context or default timeout
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(5 * time.Second)
	}
	conn.SetDeadline(deadline)

	// send request
	if _, err := conn.Write(data); err != nil {
		return nil, fmt.Errorf("write udp: %w", err)
	}

	// read response
	buf := make([]byte, 65535)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, fmt.Errorf("read udp: %w", err)
	}

	return buf[:n], nil
}

// EvaluateExpression evaluates a GDScript expression in the running game
// communicates directly with game autoload via UDP (no C++ passthrough)
func (c *Client) EvaluateExpression(ctx context.Context, expression string) (*EvaluateResult, error) {
	request := map[string]string{
		"cmd":        "evaluate",
		"expression": expression,
	}

	respData, err := sendGameUDP(ctx, request)
	if err != nil {
		return nil, fmt.Errorf("udp request failed: %w", err)
	}

	var result EvaluateResult
	if err := json.Unmarshal(respData, &result); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	if result.Error != "" {
		return nil, fmt.Errorf("evaluate error: %s", result.Error)
	}

	return &result, nil
}

// GetGameScreenshot captures the game viewport directly via UDP
// bypasses C++ extension (only editor screenshots need C++)
func (c *Client) GetGameScreenshot(ctx context.Context) (*ScreenshotResult, error) {
	request := map[string]string{
		"cmd": "screenshot",
	}

	respData, err := sendGameUDP(ctx, request)
	if err != nil {
		return nil, fmt.Errorf("udp request failed: %w", err)
	}

	var result ScreenshotResult
	if err := json.Unmarshal(respData, &result); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	// check for error in response
	var errResp struct {
		Error string `json:"error"`
	}
	json.Unmarshal(respData, &errResp)
	if errResp.Error != "" {
		return nil, fmt.Errorf("screenshot error: %s", errResp.Error)
	}

	result.Target = "game"
	return &result, nil
}

// SendInput injects input events into the running game (direct UDP)
func (c *Client) SendInput(ctx context.Context, inputType string, params map[string]interface{}) (*InputResult, error) {
	request := map[string]interface{}{
		"cmd":  "input",
		"type": inputType,
	}
	// merge additional params
	for k, v := range params {
		request[k] = v
	}

	respData, err := sendGameUDP(ctx, request)
	if err != nil {
		return nil, fmt.Errorf("udp request failed: %w", err)
	}

	var result InputResult
	if err := json.Unmarshal(respData, &result); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	if result.Error != "" {
		return nil, fmt.Errorf("input error: %s", result.Error)
	}

	return &result, nil
}
