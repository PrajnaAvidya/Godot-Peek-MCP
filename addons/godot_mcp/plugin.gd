@tool
extends EditorPlugin

const AUTOLOAD_NAME := "PeekRuntimeHelper"
const AUTOLOAD_PATH := "res://addons/godot_mcp/peek_runtime_helper.gd"


func _enter_tree() -> void:
	# add autoload if not present
	var setting := "autoload/" + AUTOLOAD_NAME
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, "*" + AUTOLOAD_PATH)
		ProjectSettings.save()
		print("[GodotPeek] Added %s autoload" % AUTOLOAD_NAME)


func _exit_tree() -> void:
	pass
