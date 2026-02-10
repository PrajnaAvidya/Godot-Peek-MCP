package godot

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"testing"
	"time"
)

// newTestClient creates a client wired to a net.Pipe with readLoop running.
// returns the client and the "server" end of the pipe for writing mock responses.
// caller must close serverConn and call client.Close() when done.
func newTestClient(t *testing.T) (*Client, net.Conn) {
	t.Helper()
	client := NewClient("test")
	serverConn, clientConn := net.Pipe()
	client.conn = clientConn
	client.reader = bufio.NewScanner(clientConn)
	client.connected = true
	go client.readLoop()
	return client, serverConn
}

// --- NewClient construction ---

func TestNewClient_DefaultPath(t *testing.T) {
	os.Unsetenv("GODOT_PEEK_SOCKET")
	c := NewClient("")
	if c.socketPath != DefaultSocketPath {
		t.Errorf("expected %s, got %s", DefaultSocketPath, c.socketPath)
	}
}

func TestNewClient_ExplicitPath(t *testing.T) {
	c := NewClient("/custom/path.sock")
	if c.socketPath != "/custom/path.sock" {
		t.Errorf("expected /custom/path.sock, got %s", c.socketPath)
	}
}

func TestNewClient_EnvOverride(t *testing.T) {
	t.Setenv("GODOT_PEEK_SOCKET", "/env/path.sock")
	c := NewClient("")
	if c.socketPath != "/env/path.sock" {
		t.Errorf("expected /env/path.sock, got %s", c.socketPath)
	}
}

// --- output buffer ---

func TestOutputBuffer_AddAndGet(t *testing.T) {
	client := NewClient("test")

	client.addOutput(OutputNotification{Type: "log", Message: "hello"})
	client.addOutput(OutputNotification{Type: "log", Message: "world"})

	out := client.GetOutput(false)
	if len(out) != 2 {
		t.Fatalf("expected 2 items, got %d", len(out))
	}
	if out[0].Message != "hello" || out[1].Message != "world" {
		t.Errorf("unexpected messages: %v", out)
	}

	// get without clear should return same data
	out2 := client.GetOutput(false)
	if len(out2) != 2 {
		t.Errorf("expected buffer to persist, got %d items", len(out2))
	}
}

func TestOutputBuffer_Clear(t *testing.T) {
	client := NewClient("test")

	client.addOutput(OutputNotification{Message: "a"})
	client.addOutput(OutputNotification{Message: "b"})

	out := client.GetOutput(true)
	if len(out) != 2 {
		t.Fatalf("expected 2 items, got %d", len(out))
	}

	// buffer should be empty after clear
	out2 := client.GetOutput(false)
	if len(out2) != 0 {
		t.Errorf("expected empty buffer after clear, got %d items", len(out2))
	}
}

func TestOutputBuffer_Trim(t *testing.T) {
	client := NewClient("test")

	// add more than MaxOutputBuffer items
	for i := 0; i < MaxOutputBuffer+50; i++ {
		client.addOutput(OutputNotification{Message: fmt.Sprintf("msg-%d", i)})
	}

	out := client.GetOutput(false)
	if len(out) != MaxOutputBuffer {
		t.Errorf("expected buffer capped at %d, got %d", MaxOutputBuffer, len(out))
	}

	// oldest should be trimmed: first message should be msg-50
	if out[0].Message != "msg-50" {
		t.Errorf("expected oldest to be msg-50, got %s", out[0].Message)
	}
}

func TestOutputBuffer_GetReturnsCopy(t *testing.T) {
	client := NewClient("test")
	client.addOutput(OutputNotification{Message: "original"})

	out := client.GetOutput(false)
	out[0].Message = "modified"

	// internal buffer should be unaffected
	out2 := client.GetOutput(false)
	if out2[0].Message != "original" {
		t.Errorf("GetOutput should return a copy, but internal buffer was modified")
	}
}

// --- handleMessage ---

func TestHandleMessage_Response(t *testing.T) {
	client := NewClient("test")

	// register a pending request
	ch := make(chan *Response, 1)
	client.pendingMu.Lock()
	client.pending[42] = ch
	client.pendingMu.Unlock()

	msg := `{"id":42,"result":{"success":true}}`
	client.handleMessage([]byte(msg))

	select {
	case resp := <-ch:
		if resp.ID != 42 {
			t.Errorf("expected id=42, got %d", resp.ID)
		}
		if resp.Result == nil {
			t.Fatal("expected result, got nil")
		}
		if resp.Error != nil {
			t.Errorf("expected no error, got %v", resp.Error)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for response")
	}
}

func TestHandleMessage_ResponseWithError(t *testing.T) {
	client := NewClient("test")

	ch := make(chan *Response, 1)
	client.pendingMu.Lock()
	client.pending[7] = ch
	client.pendingMu.Unlock()

	msg := `{"id":7,"error":{"code":-1,"message":"bad request"}}`
	client.handleMessage([]byte(msg))

	select {
	case resp := <-ch:
		if resp.Error == nil {
			t.Fatal("expected error, got nil")
		}
		if resp.Error.Message != "bad request" {
			t.Errorf("expected 'bad request', got %s", resp.Error.Message)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for response")
	}
}

func TestHandleMessage_OutputNotification(t *testing.T) {
	client := NewClient("test")

	msg := `{"method":"output","params":{"type":"log","message":"hello from godot","timestamp":1234.5}}`
	client.handleMessage([]byte(msg))

	out := client.GetOutput(false)
	if len(out) != 1 {
		t.Fatalf("expected 1 output, got %d", len(out))
	}
	if out[0].Message != "hello from godot" {
		t.Errorf("expected 'hello from godot', got %s", out[0].Message)
	}
	if out[0].Type != "log" {
		t.Errorf("expected type=log, got %s", out[0].Type)
	}
}

func TestHandleMessage_InvalidJSON(t *testing.T) {
	client := NewClient("test")
	// should not panic
	client.handleMessage([]byte("not json at all"))
	client.handleMessage([]byte("{broken"))
	client.handleMessage([]byte(""))
}

func TestHandleMessage_UnknownNotification(t *testing.T) {
	client := NewClient("test")
	// unknown method should be silently ignored
	msg := `{"method":"unknown_method","params":{}}`
	client.handleMessage([]byte(msg))

	out := client.GetOutput(false)
	if len(out) != 0 {
		t.Errorf("expected no output for unknown method, got %d", len(out))
	}
}

func TestHandleMessage_NoPendingRequest(t *testing.T) {
	client := NewClient("test")
	// response for non-existent pending request should not panic
	msg := `{"id":999,"result":{"success":true}}`
	client.handleMessage([]byte(msg))
}

// --- sendRequest ---

func TestSendRequest_Roundtrip(t *testing.T) {
	client, serverConn := newTestClient(t)
	defer serverConn.Close()
	defer client.Close()

	// simulate godot: read request from server side, write response back
	go func() {
		scanner := bufio.NewScanner(serverConn)
		if !scanner.Scan() {
			return
		}

		// parse the request to get the id
		var req Request
		json.Unmarshal(scanner.Bytes(), &req)

		// send response with matching id
		resp := fmt.Sprintf(`{"id":%d,"result":{"output":"test output","length":11,"total_length":11}}`, req.ID)
		serverConn.Write([]byte(resp + "\n"))
	}()

	ctx := context.Background()
	resp, err := client.sendRequest(ctx, "get_output", nil)
	if err != nil {
		t.Fatalf("sendRequest: %v", err)
	}

	if resp.Error != nil {
		t.Errorf("expected no error, got %v", resp.Error)
	}

	var result OutputResult
	if err := json.Unmarshal(*resp.Result, &result); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if result.Output != "test output" {
		t.Errorf("expected 'test output', got %s", result.Output)
	}
}

func TestSendRequest_NotConnected(t *testing.T) {
	client := NewClient("test")
	// not connected, should fail
	ctx := context.Background()
	_, err := client.sendRequest(ctx, "ping", nil)
	if err == nil {
		t.Fatal("expected error when not connected")
	}
}

func TestSendRequest_ContextCancel(t *testing.T) {
	client, serverConn := newTestClient(t)
	defer serverConn.Close()
	defer client.Close()

	// drain server side so conn.Write doesn't block (net.Pipe is synchronous),
	// but never send a response back
	go func() {
		scanner := bufio.NewScanner(serverConn)
		for scanner.Scan() {
			// read and discard
		}
	}()

	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan error, 1)
	go func() {
		_, err := client.sendRequest(ctx, "ping", nil)
		done <- err
	}()

	// give sendRequest a moment to register, then cancel
	time.Sleep(50 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected error on cancel")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("sendRequest didn't return after context cancel")
	}
}

// --- writeOverrides ---

func TestWriteOverrides_WritesFile(t *testing.T) {
	// clean up before and after
	os.Remove(OverridesPath)
	defer os.Remove(OverridesPath)

	overrides := Overrides{
		"GameManager": {"debug_mode": true, "speed": 2.5},
	}

	if err := writeOverrides(overrides); err != nil {
		t.Fatalf("writeOverrides: %v", err)
	}

	data, err := os.ReadFile(OverridesPath)
	if err != nil {
		t.Fatalf("read file: %v", err)
	}

	var parsed Overrides
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	props, ok := parsed["GameManager"]
	if !ok {
		t.Fatal("expected GameManager key")
	}
	if props["debug_mode"] != true {
		t.Errorf("expected debug_mode=true, got %v", props["debug_mode"])
	}
}

func TestWriteOverrides_EmptyDeletesFile(t *testing.T) {
	// create the file first
	os.WriteFile(OverridesPath, []byte("{}"), 0644)

	if err := writeOverrides(Overrides{}); err != nil {
		t.Fatalf("writeOverrides: %v", err)
	}

	if _, err := os.Stat(OverridesPath); !os.IsNotExist(err) {
		t.Error("expected file to be deleted for empty overrides")
		os.Remove(OverridesPath)
	}
}

func TestWriteOverrides_NilDeletesFile(t *testing.T) {
	os.WriteFile(OverridesPath, []byte("{}"), 0644)

	if err := writeOverrides(nil); err != nil {
		t.Fatalf("writeOverrides: %v", err)
	}

	if _, err := os.Stat(OverridesPath); !os.IsNotExist(err) {
		t.Error("expected file to be deleted for nil overrides")
		os.Remove(OverridesPath)
	}
}

// --- IsConnected ---

func TestIsConnected(t *testing.T) {
	client := NewClient("test")
	if client.IsConnected() {
		t.Error("new client should not be connected")
	}

	client.mu.Lock()
	client.connected = true
	client.mu.Unlock()

	if !client.IsConnected() {
		t.Error("expected connected after setting flag")
	}
}
