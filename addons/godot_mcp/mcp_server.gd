@tool
extends Node

const PORT := 6970
const MAX_OUTPUT_BUFFER := 1000

var tcp_server: TCPServer
var clients: Array[WebSocketPeer] = []
var pending_connections: Array[StreamPeerTCP] = []
var output_buffer: Array[Dictionary] = []


func _ready() -> void:
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(PORT)
	if err != OK:
		push_error("[GodotMCP] Failed to start TCP server on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotMCP] WebSocket server listening on ws://localhost:%d" % PORT)


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
	_send_result(ws, id, {
		"playing": EditorInterface.is_playing_scene(),
		"output_buffer_size": output_buffer.size()
	})


func _get_output(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	var clear: bool = params.get("clear", false)
	var result := {
		"output": output_buffer.duplicate(),
		"count": output_buffer.size()
	}

	if clear:
		output_buffer.clear()

	_send_result(ws, id, result)


func _send_result(ws: WebSocketPeer, id: Variant, result: Dictionary) -> void:
	var response := {"id": id, "result": result}
	var json := JSON.stringify(response)
	print("[GodotMCP] Sending response: %s" % json.substr(0, 200))
	ws.send_text(json)


func _send_error(ws: WebSocketPeer, id: Variant, code: int, message: String) -> void:
	var response := {"id": id, "error": {"code": code, "message": message}}
	var json := JSON.stringify(response)
	print("[GodotMCP] Sending error: %s" % json)
	ws.send_text(json)


# called by output_capture.gd to add captured output
func add_output(type: String, message: String, timestamp: float = -1.0) -> void:
	if timestamp < 0:
		timestamp = Time.get_unix_time_from_system()

	var entry := {
		"type": type,
		"message": message,
		"timestamp": timestamp
	}

	output_buffer.append(entry)

	# trim buffer if too large
	while output_buffer.size() > MAX_OUTPUT_BUFFER:
		output_buffer.pop_front()

	# broadcast to all connected clients
	var notification := {"method": "output", "params": entry}
	var json := JSON.stringify(notification)
	for ws in clients:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(json)


func _exit_tree() -> void:
	for ws in clients:
		ws.close()
	clients.clear()

	if tcp_server:
		tcp_server.stop()
		tcp_server = null
