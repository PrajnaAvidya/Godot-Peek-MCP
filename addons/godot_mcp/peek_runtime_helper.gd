# runtime helper for godot peek mcp
# handles game screenshots and autoload variable overrides
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


func _send_error(peer: PacketPeerUDP, message: String) -> void:
	var response := {"error": message}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	push_error("[GodotPeek] Screenshot error: %s" % message)


func _exit_tree() -> void:
	if udp_server:
		udp_server.stop()
