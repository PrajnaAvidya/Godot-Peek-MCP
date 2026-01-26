@tool
extends Node

const PORT := 6970

var tcp_server: TCPServer
var clients: Array[WebSocketPeer] = []
var pending_connections: Array[StreamPeerTCP] = []

# output dock reference
var output_rich_text: RichTextLabel = null
var last_output_length: int = 0


func _ready() -> void:
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(PORT)
	if err != OK:
		push_error("[GodotMCP] Failed to start TCP server on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotMCP] WebSocket server listening on ws://localhost:%d" % PORT)

	# find the output dock
	call_deferred("_find_output_dock")


func _find_output_dock() -> void:
	var base := EditorInterface.get_base_control()
	var rich_texts := _find_all_by_class(base, "RichTextLabel")

	# look for the EditorLog's RichTextLabel
	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		if "EditorLog" in path:
			output_rich_text = rt
			last_output_length = rt.get_parsed_text().length()
			print("[GodotMCP] Found Output dock: %s" % path)
			return

	push_warning("[GodotMCP] Could not find EditorLog RichTextLabel")


func _find_all_by_class(node: Node, target_class: String) -> Array[Node]:
	var results: Array[Node] = []
	if node.get_class() == target_class:
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_all_by_class(child, target_class))
	return results


func _process(_delta: float) -> void:
	_accept_new_connections()
	_process_pending_connections()
	_process_clients()


func _accept_new_connections() -> void:
	while tcp_server and tcp_server.is_connection_available():
		var conn := tcp_server.take_connection()
		if conn:
			pending_connections.append(conn)


func _process_pending_connections() -> void:
	var still_pending: Array[StreamPeerTCP] = []

	for conn in pending_connections:
		conn.poll()
		var status := conn.get_status()

		if status == StreamPeerTCP.STATUS_CONNECTED:
			var ws := WebSocketPeer.new()
			var err := ws.accept_stream(conn)
			if err == OK:
				clients.append(ws)
				print("[GodotMCP] Client connected")
			else:
				push_error("[GodotMCP] WebSocket accept failed: %s" % error_string(err))
		elif status == StreamPeerTCP.STATUS_CONNECTING:
			still_pending.append(conn)
		# else: connection failed, drop it

	pending_connections = still_pending


func _process_clients() -> void:
	var active_clients: Array[WebSocketPeer] = []

	for ws in clients:
		ws.poll()
		var state := ws.get_ready_state()

		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				_handle_message(ws, packet.get_string_from_utf8())
			active_clients.append(ws)
		elif state == WebSocketPeer.STATE_CLOSING:
			active_clients.append(ws)
		elif state == WebSocketPeer.STATE_CLOSED:
			print("[GodotMCP] Client disconnected")
		# STATE_CONNECTING - keep in list

	clients = active_clients


func _handle_message(ws: WebSocketPeer, message: String) -> void:
	var json := JSON.new()
	var err := json.parse(message)
	if err != OK:
		_send_error(ws, null, -32700, "Parse error")
		return

	var data: Variant = json.data
	if not data is Dictionary:
		_send_error(ws, null, -32600, "Invalid request")
		return

	var req: Dictionary = data
	var id: Variant = req.get("id")
	var method: String = req.get("method", "")
	var params: Dictionary = req.get("params", {})

	print("[GodotMCP] Received: method=%s id=%s" % [method, str(id)])

	match method:
		"ping":
			_send_result(ws, id, {"pong": true})
		"run_main_scene":
			_run_main_scene(ws, id)
		"run_scene":
			_run_scene(ws, id, params)
		"run_current_scene":
			_run_current_scene(ws, id)
		"stop_scene":
			_stop_scene(ws, id)
		"get_status":
			_get_status(ws, id)
		"get_output":
			_get_output(ws, id, params)
		_:
			_send_error(ws, id, -32601, "Method not found: %s" % method)


func _run_main_scene(ws: WebSocketPeer, id: Variant) -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		# small delay helps avoid issues
		await get_tree().create_timer(0.1).timeout

	EditorInterface.play_main_scene()
	_send_result(ws, id, {"success": true, "action": "run_main_scene"})


func _run_scene(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		_send_error(ws, id, -32602, "Missing required parameter: scene_path")
		return

	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await get_tree().create_timer(0.1).timeout

	EditorInterface.play_custom_scene(scene_path)
	_send_result(ws, id, {"success": true, "action": "run_scene", "scene_path": scene_path})


func _run_current_scene(ws: WebSocketPeer, id: Variant) -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await get_tree().create_timer(0.1).timeout

	EditorInterface.play_current_scene()
	_send_result(ws, id, {"success": true, "action": "run_current_scene"})


func _stop_scene(ws: WebSocketPeer, id: Variant) -> void:
	var was_playing: bool = EditorInterface.is_playing_scene()
	if was_playing:
		EditorInterface.stop_playing_scene()

	_send_result(ws, id, {"success": true, "was_playing": was_playing})


func _get_status(ws: WebSocketPeer, id: Variant) -> void:
	var output_available := output_rich_text != null
	var output_length := 0
	if output_rich_text:
		output_length = output_rich_text.get_parsed_text().length()

	_send_result(ws, id, {
		"playing": EditorInterface.is_playing_scene(),
		"output_available": output_available,
		"output_length": output_length
	})


func _get_output(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	if not output_rich_text:
		_send_error(ws, id, -32000, "Output dock not found")
		return

	# use get_parsed_text() - the text property and get_text() return empty
	# because the Output panel uses append_text() with BBCode
	var full_text := output_rich_text.get_parsed_text()
	var new_only: bool = params.get("new_only", false)
	var clear: bool = params.get("clear", false)

	var output_text: String
	if new_only:
		# return only text added since last call
		output_text = full_text.substr(last_output_length)
	else:
		output_text = full_text

	if clear:
		last_output_length = full_text.length()

	_send_result(ws, id, {
		"output": output_text,
		"length": output_text.length(),
		"total_length": full_text.length()
	})


func _send_result(ws: WebSocketPeer, id: Variant, result: Dictionary) -> void:
	var response := {"id": id, "result": result}
	ws.send_text(JSON.stringify(response))


func _send_error(ws: WebSocketPeer, id: Variant, code: int, message: String) -> void:
	var response := {"id": id, "error": {"code": code, "message": message}}
	ws.send_text(JSON.stringify(response))


func _exit_tree() -> void:
	for ws in clients:
		ws.close()
	clients.clear()

	if tcp_server:
		tcp_server.stop()
		tcp_server = null
