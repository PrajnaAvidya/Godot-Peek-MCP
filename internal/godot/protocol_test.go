package godot

import (
	"encoding/json"
	"sync"
	"testing"
)

func TestNextID_Increments(t *testing.T) {
	a := nextID()
	b := nextID()
	c := nextID()

	if b != a+1 || c != a+2 {
		t.Errorf("expected sequential IDs, got %d, %d, %d", a, b, c)
	}
}

func TestNextID_Concurrent(t *testing.T) {
	const goroutines = 100

	var mu sync.Mutex
	seen := make(map[int64]bool)

	var wg sync.WaitGroup
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			id := nextID()
			mu.Lock()
			seen[id] = true
			mu.Unlock()
		}()
	}
	wg.Wait()

	if len(seen) != goroutines {
		t.Errorf("expected %d unique IDs, got %d", goroutines, len(seen))
	}
}

func TestRequestJSON(t *testing.T) {
	req := Request{
		ID:     42,
		Method: "get_output",
		Params: GetOutputParams{Clear: true, NewOnly: false},
	}

	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// unmarshal into generic map to verify structure
	var m map[string]interface{}
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if m["id"].(float64) != 42 {
		t.Errorf("expected id=42, got %v", m["id"])
	}
	if m["method"].(string) != "get_output" {
		t.Errorf("expected method=get_output, got %v", m["method"])
	}

	params := m["params"].(map[string]interface{})
	if params["clear"] != true {
		t.Errorf("expected clear=true, got %v", params["clear"])
	}
}

func TestRequestJSON_OmitsEmptyParams(t *testing.T) {
	req := Request{ID: 1, Method: "ping"}

	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var m map[string]interface{}
	json.Unmarshal(data, &m)

	if _, exists := m["params"]; exists {
		t.Errorf("expected params to be omitted, got %v", m["params"])
	}
}

func TestResponseUnmarshal(t *testing.T) {
	raw := `{"id":5,"result":{"success":true,"action":"run"}}`

	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if resp.ID != 5 {
		t.Errorf("expected id=5, got %d", resp.ID)
	}
	if resp.Error != nil {
		t.Errorf("expected no error, got %v", resp.Error)
	}
	if resp.Result == nil {
		t.Fatal("expected result, got nil")
	}

	// unmarshal result payload
	var result GenericResult
	if err := json.Unmarshal(*resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if !result.Success {
		t.Error("expected success=true")
	}
	if result.Action != "run" {
		t.Errorf("expected action=run, got %s", result.Action)
	}
}

func TestResponseUnmarshal_WithError(t *testing.T) {
	raw := `{"id":10,"error":{"code":-1,"message":"something broke"}}`

	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if resp.ID != 10 {
		t.Errorf("expected id=10, got %d", resp.ID)
	}
	if resp.Error == nil {
		t.Fatal("expected error, got nil")
	}
	if resp.Error.Code != -1 {
		t.Errorf("expected code=-1, got %d", resp.Error.Code)
	}
	if resp.Error.Message != "something broke" {
		t.Errorf("expected message='something broke', got %s", resp.Error.Message)
	}
}
