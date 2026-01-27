package godot

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	DefaultURL          = "ws://localhost:6970"
	MaxReconnectBackoff = 30 * time.Second
	MaxOutputBuffer     = 1000
)

// Client manages WebSocket connection to Godot editor plugin
type Client struct {
	url string

	mu           sync.RWMutex
	conn         *websocket.Conn
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
func NewClient(url string) *Client {
	if url == "" {
		url = DefaultURL
	}

	ctx, cancel := context.WithCancel(context.Background())

	c := &Client{
		url:      url,
		pending:  make(map[int64]chan *Response),
		outputCh: make(chan OutputNotification, 100),
		ctx:      ctx,
		cancel:   cancel,
	}

	return c
}

// Connect establishes connection to Godot
func (c *Client) Connect(ctx context.Context) error {
	conn, _, err := websocket.Dial(ctx, c.url, nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}

	c.mu.Lock()
	c.conn = conn
	c.connected = true
	c.mu.Unlock()

	// start reading messages
	go c.readLoop()

	log.Printf("[godot] Connected to %s", c.url)
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
		return c.conn.Close(websocket.StatusNormalClosure, "closing")
	}
	return nil
}

// readLoop handles incoming WebSocket messages
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
		conn := c.conn
		c.mu.RUnlock()

		if conn == nil {
			return
		}

		_, data, err := conn.Read(c.ctx)
		if err != nil {
			if c.ctx.Err() == nil {
				log.Printf("[godot] Read error: %v", err)
			}
			return
		}

		c.handleMessage(data)
	}
}

// handleMessage processes a raw message
func (c *Client) handleMessage(data []byte) {
	log.Printf("[godot] Received message: %s", string(data)[:min(len(data), 200)])

	// try to parse as response (has id)
	// note: Godot sends id as float (1.0), so use float64
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
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
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

// RunMainScene starts the project's main scene
func (c *Client) RunMainScene(ctx context.Context) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "run_main_scene", nil)
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

// RunScene starts a specific scene
func (c *Client) RunScene(ctx context.Context, scenePath string) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "run_scene", RunSceneParams{ScenePath: scenePath})
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

// RunCurrentScene starts the currently open scene
func (c *Client) RunCurrentScene(ctx context.Context) (*GenericResult, error) {
	resp, err := c.sendRequest(ctx, "run_current_scene", nil)
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
	return &result, nil
}

// GetScreenshot captures a screenshot from game or editor viewports
func (c *Client) GetScreenshot(ctx context.Context, target string) (*ScreenshotResult, error) {
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
