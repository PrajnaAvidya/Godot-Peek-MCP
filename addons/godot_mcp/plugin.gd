@tool
extends EditorPlugin

var mcp_server: Node
var output_capture: EditorDebuggerPlugin


func _enter_tree() -> void:
	mcp_server = preload("res://addons/godot_mcp/mcp_server.gd").new()
	mcp_server.name = "MCPServer"
	add_child(mcp_server)

	output_capture = preload("res://addons/godot_mcp/output_capture.gd").new()
	output_capture.mcp_server = mcp_server
	add_debugger_plugin(output_capture)

	print("[GodotMCP] Plugin enabled, WebSocket server starting on port 6970")


func _exit_tree() -> void:
	if output_capture:
		remove_debugger_plugin(output_capture)
		output_capture = null

	if mcp_server:
		mcp_server.queue_free()
		mcp_server = null

	print("[GodotMCP] Plugin disabled")
