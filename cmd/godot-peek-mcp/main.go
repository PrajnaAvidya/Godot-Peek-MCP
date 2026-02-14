package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode"

	"github.com/mark3labs/mcp-go/server"
	"github.com/PrajnaAvidya/godot-peek-mcp/internal/godot"
	"github.com/PrajnaAvidya/godot-peek-mcp/internal/tools"
)

const (
	serverName    = "godot-peek-mcp"
	serverVersion = "0.1.0"
)

// sanitizeProjectName matches the C++ plugin's sanitization logic:
// lowercase, replace non-alphanumeric with dash, trim trailing dashes.
func sanitizeProjectName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		} else if b.Len() > 0 && !strings.HasSuffix(b.String(), "-") {
			b.WriteRune('-')
		}
	}
	return strings.TrimRight(b.String(), "-")
}

func main() {
	// all logging goes to stderr (stdout is reserved for MCP protocol)
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lshortfile)

	// setup context with signal handling
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx); err != nil {
		log.Fatalf("fatal: %v", err)
	}
}

func run(ctx context.Context) error {
	// socket path resolution:
	// 1. GODOT_PEEK_SOCKET env var (explicit full path override)
	// 2. derive from cwd directory name (matches C++ plugin logic)
	socketPath := os.Getenv("GODOT_PEEK_SOCKET")
	if socketPath == "" {
		dir, err := os.Getwd()
		if err == nil {
			sanitized := sanitizeProjectName(filepath.Base(dir))
			if sanitized != "" {
				socketPath = "/tmp/godot-peek-" + sanitized + ".sock"
			}
		}
	}
	if socketPath == "" {
		socketPath = godot.DefaultSocketPath
	}

	client := godot.NewClient(socketPath)

	// try to connect with retries
	if err := connectWithRetry(ctx, client, 3); err != nil {
		return fmt.Errorf("failed to connect to Godot: %w", err)
	}
	defer client.Close()

	// create MCP server
	mcpServer := server.NewMCPServer(
		serverName,
		serverVersion,
		server.WithToolCapabilities(true),
	)

	// register tools
	tools.Register(mcpServer, client)

	log.Printf("starting MCP server (connected to %s)", socketPath)

	// run stdio transport
	return server.ServeStdio(mcpServer)
}

func connectWithRetry(ctx context.Context, client *godot.Client, maxRetries int) error {
	var lastErr error

	for i := 0; i < maxRetries; i++ {
		if i > 0 {
			log.Printf("retrying connection (%d/%d)...", i+1, maxRetries)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(i) * time.Second):
			}
		}

		err := client.Connect(ctx)
		if err == nil {
			return nil
		}
		lastErr = err
		log.Printf("connection attempt failed: %v", err)
	}

	return lastErr
}
