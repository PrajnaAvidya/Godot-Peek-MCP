@tool
extends EditorDebuggerPlugin

var mcp_server: Node


func _has_capture(prefix: String) -> bool:
	# log all prefixes to understand what Godot sends
	print("[GodotMCP:capture] _has_capture called with prefix: ", prefix)
	# capture output messages from running game
	match prefix:
		"output", "error", "stack_dump", "stack_frame_vars":
			return true
	return false


func _capture(message: String, data: Array, session_id: int) -> bool:
	print("[GodotMCP:capture] _capture called: message=%s, data=%s" % [message, str(data).substr(0, 200)])
	if not mcp_server or not mcp_server.has_method("add_output"):
		print("[GodotMCP:capture] mcp_server not available")
		return false

	match message:
		"output":
			# data format: [type: int, script_path: String, line: int, text: String]
			# type: 0 = output, 1 = error, 2 = warning
			if data.size() >= 4:
				var type_id: int = data[0]
				var script_path: String = data[1]
				var line: int = data[2]
				var text: String = data[3]

				var type_str := "print"
				match type_id:
					1:
						type_str = "error"
					2:
						type_str = "warning"

				var msg := text
				if not script_path.is_empty() and line > 0:
					msg = "[%s:%d] %s" % [script_path.get_file(), line, text]

				mcp_server.add_output(type_str, msg)
			return true

		"error":
			# error message with details
			if data.size() >= 1:
				var error_text: String = str(data[0])
				mcp_server.add_output("error", error_text)
			return true

		"stack_dump":
			# stack trace data
			# format varies but typically array of stack frame info
			if data.size() > 0:
				var stack_text := "Stack trace:\n"
				for frame in data:
					if frame is Dictionary:
						var file: String = frame.get("file", "")
						var line: int = frame.get("line", 0)
						var func_name: String = frame.get("function", "")
						stack_text += "  %s:%d in %s\n" % [file.get_file(), line, func_name]
				mcp_server.add_output("stack", stack_text.strip_edges())
			return true

		"stack_frame_vars":
			# variable state at stack frame - skip for now, too verbose
			return true

	return false


func _setup_session(session_id: int) -> void:
	pass


func _breakpoint_set_in_tree(_script: Script, _line: int, _enabled: bool) -> void:
	pass


func _breakpoints_cleared_in_tree() -> void:
	pass
