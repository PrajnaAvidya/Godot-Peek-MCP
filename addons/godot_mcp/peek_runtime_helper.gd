# runtime helper for godot peek mcp
# handles game screenshots, autoload variable overrides, expression evaluation, input injection
#
# setup:
#   - automatically added when plugin is enabled
#   - for best results, ensure this is FIRST in Project Settings > Autoload
#     so overrides apply before other autoloads' _ready()

extends Node

const SCREENSHOT_PORT := 6971
const SCREENSHOT_PATH := "/tmp/godot_peek_game_screenshot.png"
const OVERRIDES_PATH := "/tmp/godot_peek_overrides.json"

var udp_server: UDPServer


func _ready() -> void:
	# skip in export builds — no mcp server to talk to
	if not OS.has_feature("editor"):
		return
	_apply_overrides()
	_start_screenshot_server()


func _apply_overrides() -> void:
	if not FileAccess.file_exists(OVERRIDES_PATH):
		return

	var file := FileAccess.open(OVERRIDES_PATH, FileAccess.READ)
	if not file:
		push_warning("[GodotPeek] Could not open overrides file")
		return

	var content := file.get_as_text()
	file.close()

	# delete file after reading (one-shot)
	DirAccess.remove_absolute(OVERRIDES_PATH)

	var json := JSON.new()
	if json.parse(content) != OK:
		push_warning("[GodotPeek] Failed to parse overrides JSON: %s" % json.get_error_message())
		return

	var overrides: Dictionary = json.data
	if overrides.is_empty():
		return

	print("[GodotPeek] Applying %d autoload override(s)..." % overrides.size())

	for autoload_name: String in overrides:
		var props: Dictionary = overrides[autoload_name]
		var autoload := get_node_or_null("/root/" + autoload_name)

		if not autoload:
			push_warning("[GodotPeek] Autoload '%s' not found, skipping overrides" % autoload_name)
			continue

		for prop_name: String in props:
			var value: Variant = props[prop_name]
			if prop_name in autoload:
				autoload.set(prop_name, value)
				print("[GodotPeek] Set %s.%s = %s" % [autoload_name, prop_name, str(value)])
			else:
				push_warning("[GodotPeek] Property '%s' not found on autoload '%s'" % [prop_name, autoload_name])


func _start_screenshot_server() -> void:
	udp_server = UDPServer.new()
	var err := udp_server.listen(SCREENSHOT_PORT)
	if err != OK:
		push_error("[GodotPeek] Screenshot listener failed to start on port %d: %s" % [SCREENSHOT_PORT, error_string(err)])
		return
	print("[GodotPeek] Screenshot listener ready on UDP port %d" % SCREENSHOT_PORT)


func _process(_delta: float) -> void:
	if not udp_server:
		return

	udp_server.poll()

	if udp_server.is_connection_available():
		var peer := udp_server.take_connection()
		_handle_peer(peer)


func _handle_peer(peer: PacketPeerUDP) -> void:
	while peer.get_available_packet_count() > 0:
		var packet := peer.get_packet()
		var message := packet.get_string_from_utf8()

		var json := JSON.new()
		if json.parse(message) != OK:
			_send_error(peer, "parse error")
			return

		var data: Dictionary = json.data
		var cmd: String = data.get("cmd", "")

		if cmd == "screenshot":
			_take_screenshot(peer)
		elif cmd == "evaluate":
			var expr_str: String = data.get("expression", "")
			_evaluate_expression(peer, expr_str)
		elif cmd == "input":
			_handle_input(peer, data)
		else:
			_send_error(peer, "unknown command: %s" % cmd)


func _take_screenshot(peer: PacketPeerUDP) -> void:
	# wait for frame to finish rendering
	await RenderingServer.frame_post_draw

	var viewport := get_viewport()
	if not viewport:
		_send_error(peer, "no viewport")
		return

	var img := viewport.get_texture().get_image()
	if not img:
		_send_error(peer, "failed to get viewport image")
		return

	var err := img.save_png(SCREENSHOT_PATH)
	if err != OK:
		_send_error(peer, "failed to save png: %s" % error_string(err))
		return

	var response := {
		"path": SCREENSHOT_PATH,
		"width": img.get_width(),
		"height": img.get_height()
	}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	print("[GodotPeek] Screenshot saved: %s (%dx%d)" % [SCREENSHOT_PATH, img.get_width(), img.get_height()])


func _evaluate_expression(peer: PacketPeerUDP, expr_str: String) -> void:
	if expr_str.is_empty():
		_send_error(peer, "empty expression")
		return

	var expression := Expression.new()
	var parse_err := expression.parse(expr_str)
	if parse_err != OK:
		_send_error(peer, "parse error: %s" % expression.get_error_text())
		return

	# use scene root as base so expressions can call get_node(), get_tree(), etc.
	var base := get_tree().root
	var result: Variant = expression.execute([], base)

	if expression.has_execute_failed():
		_send_error(peer, "execution failed")
		return

	var response := {
		"value": _variant_to_string(result),
		"type": type_string(typeof(result))
	}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())


func _variant_to_string(value: Variant) -> String:
	# handle common types with cleaner output
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_STRING:
			return value
		TYPE_OBJECT:
			if value == null:
				return "null"
			if value is Node:
				return "%s (%s)" % [value.name, value.get_class()]
			return str(value)
		_:
			return str(value)


func _handle_input(peer: PacketPeerUDP, data: Dictionary) -> void:
	var input_type: String = data.get("type", "")
	var event: InputEvent = null

	match input_type:
		"action":
			event = InputEventAction.new()
			event.action = data.get("action", "")
			event.pressed = data.get("pressed", true)
			# strength for analog actions (default 1.0)
			event.strength = data.get("strength", 1.0)

		"key":
			event = InputEventKey.new()
			# accept keycode as string like "KEY_W" or int
			var keycode = data.get("keycode", "")
			if keycode is String:
				event.keycode = _string_to_keycode(keycode)
			else:
				event.keycode = keycode
			event.pressed = data.get("pressed", true)

		"mouse_button":
			event = InputEventMouseButton.new()
			event.button_index = _string_to_mouse_button(data.get("button", "left"))
			event.pressed = data.get("pressed", true)
			var pos = data.get("position", [0, 0])
			event.position = Vector2(pos[0], pos[1])

		"mouse_motion":
			event = InputEventMouseMotion.new()
			var rel = data.get("relative", [0, 0])
			event.relative = Vector2(rel[0], rel[1])
			var pos = data.get("position", [0, 0])
			event.position = Vector2(pos[0], pos[1])

		_:
			_send_error(peer, "unknown input type: %s" % input_type)
			return

	if event:
		Input.parse_input_event(event)
		var response := {"success": true, "type": input_type}
		peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	else:
		_send_error(peer, "failed to create input event")


func _string_to_keycode(s: String) -> Key:
	# strip "KEY_" prefix if present
	s = s.to_upper()
	if s.begins_with("KEY_"):
		s = s.substr(4)
	# common keys - expand as needed
	match s:
		"W": return KEY_W
		"A": return KEY_A
		"S": return KEY_S
		"D": return KEY_D
		"SPACE": return KEY_SPACE
		"ESCAPE", "ESC": return KEY_ESCAPE
		"ENTER", "RETURN": return KEY_ENTER
		"SHIFT": return KEY_SHIFT
		"CTRL", "CONTROL": return KEY_CTRL
		"UP": return KEY_UP
		"DOWN": return KEY_DOWN
		"LEFT": return KEY_LEFT
		"RIGHT": return KEY_RIGHT
		"TAB": return KEY_TAB
		"1": return KEY_1
		"2": return KEY_2
		"3": return KEY_3
		"4": return KEY_4
		"5": return KEY_5
		"6": return KEY_6
		"7": return KEY_7
		"8": return KEY_8
		"9": return KEY_9
		"0": return KEY_0
		"F1": return KEY_F1
		"F2": return KEY_F2
		"F3": return KEY_F3
		"F4": return KEY_F4
		"F5": return KEY_F5
		_: return KEY_NONE


func _string_to_mouse_button(s: String) -> MouseButton:
	match s.to_lower():
		"left", "1": return MOUSE_BUTTON_LEFT
		"right", "2": return MOUSE_BUTTON_RIGHT
		"middle", "3": return MOUSE_BUTTON_MIDDLE
		"wheel_up", "4": return MOUSE_BUTTON_WHEEL_UP
		"wheel_down", "5": return MOUSE_BUTTON_WHEEL_DOWN
		_: return MOUSE_BUTTON_LEFT


func _send_error(peer: PacketPeerUDP, message: String) -> void:
	var response := {"error": message}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	push_error("[GodotPeek] Screenshot error: %s" % message)


func _exit_tree() -> void:
	if udp_server:
		udp_server.stop()
