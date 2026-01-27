# screenshot listener for godot peek mcp
# add this as an autoload in your project to enable game screenshots
#
# setup:
#   1. copy this file to your project (or reference from addon)
#   2. project > project settings > autoload
#   3. add this script with name "ScreenshotListener"
#   4. run your game - screenshots will now work via get_screenshot tool

extends Node

const PORT := 6971
const OUTPUT_PATH := "/tmp/godot_peek_game_screenshot.png"

var udp_server: UDPServer


func _ready() -> void:
	udp_server = UDPServer.new()
	var err := udp_server.listen(PORT)
	if err != OK:
		push_error("[GodotPeek] Screenshot listener failed to start on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotPeek] Screenshot listener ready on UDP port %d" % PORT)


func _process(_delta: float) -> void:
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

	var err := img.save_png(OUTPUT_PATH)
	if err != OK:
		_send_error(peer, "failed to save png: %s" % error_string(err))
		return

	var response := {
		"path": OUTPUT_PATH,
		"width": img.get_width(),
		"height": img.get_height()
	}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	print("[GodotPeek] Screenshot saved: %s (%dx%d)" % [OUTPUT_PATH, img.get_width(), img.get_height()])


func _send_error(peer: PacketPeerUDP, message: String) -> void:
	var response := {"error": message}
	peer.put_packet(JSON.stringify(response).to_utf8_buffer())
	push_error("[GodotPeek] Screenshot error: %s" % message)


func _exit_tree() -> void:
	if udp_server:
		udp_server.stop()
