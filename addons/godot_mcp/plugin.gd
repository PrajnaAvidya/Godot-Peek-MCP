@tool
extends EditorPlugin

const AUTOLOAD_NAME := "ScreenshotListener"
const AUTOLOAD_PATH := "res://addons/godot_mcp/screenshot_listener.gd"

var mcp_server: Node


func _enter_tree() -> void:
	mcp_server = preload("res://addons/godot_mcp/mcp_server.gd").new()
	mcp_server.name = "MCPServer"
	add_child(mcp_server)

	_ensure_screenshot_autoload()
	print("[GodotPeek] Plugin enabled")


func _ensure_screenshot_autoload() -> void:
	# check if autoload already exists
	var autoload_setting := "autoload/" + AUTOLOAD_NAME
	if ProjectSettings.has_setting(autoload_setting):
		return

	# add autoload (* prefix means it's a singleton)
	ProjectSettings.set_setting(autoload_setting, "*" + AUTOLOAD_PATH)
	ProjectSettings.save()
	print("[GodotPeek] Added %s autoload for game screenshots" % AUTOLOAD_NAME)


func _exit_tree() -> void:
	if mcp_server:
		mcp_server.queue_free()
		mcp_server = null
	print("[GodotPeek] Plugin disabled")
