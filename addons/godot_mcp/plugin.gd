@tool
extends EditorPlugin

var mcp_server: Node


func _enter_tree() -> void:
	mcp_server = preload("res://addons/godot_mcp/mcp_server.gd").new()
	mcp_server.name = "MCPServer"
	add_child(mcp_server)
	print("[GodotPeek] Plugin enabled")


func _exit_tree() -> void:
	if mcp_server:
		mcp_server.queue_free()
		mcp_server = null
	print("[GodotPeek] Plugin disabled")
