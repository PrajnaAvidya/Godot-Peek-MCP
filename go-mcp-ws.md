# Building MCP servers in Go: The definitive approach for 2025

The Go MCP ecosystem has matured significantly, with **mark3labs/mcp-go** emerging as the most production-ready option with 7,600+ stars and 2,400+ dependents, while the official SDK is now stable and recommended for new projects. For WebSocket connectivity, **coder/websocket** is the clear modern choice, officially recommended by Go authors. Your architecture will need custom transport bridging since MCP SDKs don't natively support WebSocket—but this is straightforward with Go's flexible interfaces.

## Two strong MCP SDK choices dominate the ecosystem

The Go MCP landscape has consolidated around two primary options. The **official SDK** (`github.com/modelcontextprotocol/go-sdk`) reached v1.0.0 stable in late 2025 with Google collaboration, offering excellent type safety through struct tags, built-in OAuth support, and guaranteed spec compliance. It currently has **3,000+ stars** and 354 projects using it in production.

However, **mark3labs/mcp-go** (`github.com/mark3labs/mcp-go`) remains the most battle-tested choice with **7,600+ stars**, 2,400+ dependents including DataDog, and 63 releases. Its builder pattern with functional options provides excellent developer ergonomics, and it supports all major transports including stdio, SSE, and Streamable HTTP.

| Feature | Official go-sdk | mark3labs/mcp-go |
|---------|----------------|------------------|
| Stars | 3,000+ | 7,600+ |
| Production dependents | 354 | 2,400+ |
| Auto JSON schema | ✅ struct tags | ✅ functional builders |
| Session management | ✅ | ✅ with per-session tools |
| Middleware support | ✅ | ✅ recovery + hooks |
| OAuth support | ✅ built-in | ❌ |
| WebSocket transport | ❌ not native | ❌ not native |

**Recommendation**: Use mark3labs/mcp-go for maximum production stability and community support. Choose the official SDK if you need OAuth or want guaranteed long-term spec alignment.

## coder/websocket is the correct choice for Go WebSocket clients

The Go WebSocket library landscape has a clear winner. **coder/websocket** (`github.com/coder/websocket`, formerly nhooyr.io/websocket) is now **officially recommended by Go authors** in the golang.org/x/net/websocket documentation. It offers first-class `context.Context` support, concurrent writes, zero-allocation reads, and active maintenance by Coder.

Gorilla/websocket, despite its **24,300 stars**, has a troubled maintenance history—archived in December 2022, controversially updated in v1.5.1-1.5.2, then reverted in v1.5.3. It lacks native context support and concurrent write handling. The standard library's `golang.org/x/net/websocket` is effectively deprecated with known bugs around ping handling and continuation frames.

```go
// Connecting to Godot editor with coder/websocket
import "github.com/coder/websocket"

func ConnectToGodot(ctx context.Context, addr string) (*websocket.Conn, error) {
    dialCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
    defer cancel()
    
    c, _, err := websocket.Dial(dialCtx, "ws://"+addr, nil)
    if err != nil {
        return nil, err
    }
    return c, nil
}
```

Neither library provides built-in reconnection—implement exponential backoff yourself for production reliability.

## Architecture: Bridge WebSocket transport to MCP protocol layer

Since MCP SDKs don't natively support WebSocket transport, you'll need to implement a custom transport adapter. Both major SDKs provide clean interfaces for this. The architecture follows a three-layer pattern: **Transport** (WebSocket ↔ Godot), **Protocol** (JSON-RPC 2.0 message handling), and **Application** (MCP tools/resources).

```go
// Custom WebSocket transport implementing MCP transport interface
type WebSocketTransport struct {
    conn   *websocket.Conn
    ctx    context.Context
    cancel context.CancelFunc
}

func (t *WebSocketTransport) Read() ([]byte, error) {
    msgType, data, err := t.conn.Read(t.ctx)
    if err != nil {
        return nil, err
    }
    if msgType != websocket.MessageText {
        return nil, fmt.Errorf("unexpected message type: %d", msgType)
    }
    return data, nil
}

func (t *WebSocketTransport) Write(data []byte) error {
    return t.conn.Write(t.ctx, websocket.MessageText, data)
}

func (t *WebSocketTransport) Close() error {
    t.cancel()
    return t.conn.Close(websocket.StatusNormalClosure, "shutdown")
}
```

For the JSON-RPC 2.0 layer, **sourcegraph/jsonrpc2** (234 stars) works well if you need lower-level control, offering symmetric client/server design over any `io.ReadWriteCloser`. However, using a full MCP SDK handles JSON-RPC 2.0 internally and is the recommended approach.

## Critical pattern: Never write to stdout in stdio mode

The single most important rule for MCP servers using stdio transport: **stdout is reserved exclusively for JSON-RPC protocol messages**. Any stray output corrupts the message stream and breaks communication.

```go
// ❌ WRONG - These break stdio transport
fmt.Println("Server started")
log.Println("Processing request")  // Default Go logger uses stdout

// ✅ CORRECT - Use stderr for all logging
fmt.Fprintln(os.Stderr, "Server started")
log.SetOutput(os.Stderr)

// ✅ BETTER - Use structured logging to stderr
import "log/slog"
logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
slog.SetDefault(logger)
```

For your WebSocket-based architecture connecting to Godot, this constraint doesn't apply directly since you're not using stdio—but understanding it matters if you later need to support Claude Desktop or other stdio-based MCP hosts.

## Tool registration patterns favor type safety

Both major SDKs support automatic JSON schema generation from Go structs, eliminating manual schema writing. The mark3labs/mcp-go approach uses functional options for readable schema building:

```go
// mark3labs/mcp-go pattern
tool := mcp.NewTool("execute_gdscript",
    mcp.WithDescription("Execute GDScript code in Godot editor"),
    mcp.WithString("code", 
        mcp.Required(), 
        mcp.Description("GDScript code to execute")),
    mcp.WithString("node_path",
        mcp.Description("Optional scene node path context")),
)

s.AddTool(tool, func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
    code, _ := req.RequireString("code")
    // Send to Godot via WebSocket, await response
    result, err := executeInGodot(ctx, code)
    if err != nil {
        return mcp.NewToolResultError(err.Error()), nil  // Tool error, not protocol error
    }
    return mcp.NewToolResultText(result), nil
})
```

The official SDK uses struct tags with jsonschema annotations:

```go
// Official SDK pattern
type ExecuteGDScriptInput struct {
    Code     string `json:"code" jsonschema:"required,description=GDScript code to execute"`
    NodePath string `json:"node_path,omitempty" jsonschema:"description=Optional scene node path"`
}

mcp.AddTool(server, &mcp.Tool{
    Name:        "execute_gdscript",
    Description: "Execute GDScript code in Godot editor",
}, handleExecuteGDScript)
```

## Error handling must distinguish tool failures from protocol errors

MCP specification requires that tool execution errors be returned **inside the result object** with `isError: true`, not as JSON-RPC protocol errors. Protocol-level errors indicate the tool couldn't be invoked at all (not found, server misconfiguration), while tool errors mean execution occurred but encountered a problem.

```go
func handleTool(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
    // Validate input - return tool error for bad input
    code, err := req.RequireString("code")
    if err != nil {
        return mcp.NewToolResultError("missing required 'code' parameter"), nil
    }
    
    // Execute - return tool error for execution failures
    result, err := executeInGodot(ctx, code)
    if err != nil {
        return mcp.NewToolResultError(fmt.Sprintf("execution failed: %v", err)), nil
    }
    
    return mcp.NewToolResultText(result), nil
    
    // Only return non-nil error for true protocol issues like context cancellation
}
```

Use context cancellation consistently for long-running operations:

```go
func handleLongRunningTool(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
    select {
    case <-ctx.Done():
        return nil, ctx.Err()  // Protocol-level cancellation
    case result := <-doExpensiveWork(ctx):
        return mcp.NewToolResultText(result), nil
    }
}
```

## Recommended project structure for Godot MCP integration

```
godot-mcp-server/
├── cmd/
│   └── server/
│       └── main.go              # Entry point, transport setup
├── internal/
│   ├── transport/
│   │   └── websocket.go         # WebSocket adapter for MCP
│   ├── tools/
│   │   ├── registry.go          # Tool registration
│   │   ├── gdscript.go          # GDScript execution tool
│   │   ├── scene.go             # Scene manipulation tools
│   │   └── editor.go            # Editor control tools
│   └── godot/
│       ├── client.go            # WebSocket client to Godot
│       └── protocol.go          # Godot<->MCP message mapping
├── go.mod
└── go.sum
```

Initialize your server with proper graceful shutdown:

```go
func main() {
    ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
    defer cancel()
    
    // Connect to Godot editor WebSocket server
    godotConn, err := connectToGodot(ctx, "localhost:6970")
    if err != nil {
        log.Fatalf("Failed to connect to Godot: %v", err)
    }
    defer godotConn.Close()
    
    // Create MCP server with tools
    mcpServer := server.NewMCPServer("godot-mcp", "1.0.0",
        server.WithToolCapabilities(true),
        server.WithRecovery(),  // Recover from tool panics
    )
    
    registerGodotTools(mcpServer, godotConn)
    
    // Use custom WebSocket transport instead of stdio
    transport := NewWebSocketTransport(godotConn)
    if err := mcpServer.Serve(ctx, transport); err != nil && err != context.Canceled {
        log.Fatalf("Server error: %v", err)
    }
}
```

## Conclusion

For your Go MCP server connecting to Godot 4.5, use **mark3labs/mcp-go** for the MCP protocol implementation and **coder/websocket** for WebSocket connectivity. Implement a custom transport adapter to bridge WebSocket messages to the MCP SDK's transport interface. Focus on proper error handling (tool errors vs protocol errors), context-based cancellation for long operations, and structured logging to stderr if you ever need stdio transport compatibility.

The Go MCP ecosystem is now mature enough for production use, with both the official SDK and mark3labs/mcp-go providing stable, well-documented foundations. The main architectural challenge—WebSocket transport—is easily solved through Go's interface-based design.