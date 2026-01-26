@tool
extends Node

const PORT := 6970

var tcp_server: TCPServer
var clients: Array[WebSocketPeer] = []
var pending_connections: Array[StreamPeerTCP] = []

# output dock reference
var output_rich_text: RichTextLabel = null
var last_output_length: int = 0

# debugger dock references
var debugger_errors_tree: Tree = null
var debugger_stack_trace: RichTextLabel = null
var debugger_stack_frames: Tree = null
var debugger_inspector: Control = null  # EditorDebuggerInspector


func _ready() -> void:
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(PORT)
	if err != OK:
		push_error("[GodotMCP] Failed to start TCP server on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotMCP] WebSocket server listening on ws://localhost:%d" % PORT)

	# find the output and debugger docks
	call_deferred("_find_output_dock")
	call_deferred("_find_debugger_dock")


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


func _find_debugger_dock() -> void:
	var base := EditorInterface.get_base_control()

	# find the Errors Tree (contains warnings/errors)
	var trees := _find_all_by_class(base, "Tree")
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		if "EditorDebuggerNode" in path and "Errors" in path:
			debugger_errors_tree = tree
			print("[GodotMCP] Found Debugger Errors tree: %s" % path)
			break

	# find Stack Trace RichTextLabel (error message header)
	var rich_texts := _find_all_by_class(base, "RichTextLabel")
	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		if "EditorDebuggerNode" in path and "Stack Trace" in path:
			debugger_stack_trace = rt
			print("[GodotMCP] Found Debugger Stack Trace message: %s" % path)
			break

	# find Stack Trace Tree (actual stack frames)
	# look for Tree inside Stack Trace/HSplitContainer/.../VBoxContainer
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		if "Stack Trace" in path and "VBoxContainer" in path:
			debugger_stack_frames = tree
			print("[GodotMCP] Found Debugger Stack Frames tree: %s" % path)
			break

	# find EditorDebuggerInspector (shows locals when frame selected)
	var all_nodes := _find_all_nodes(base)
	for node in all_nodes:
		if node.get_class() == "EditorDebuggerInspector":
			debugger_inspector = node
			print("[GodotMCP] Found EditorDebuggerInspector: %s" % node.get_path())
			break

	if not debugger_errors_tree and not debugger_stack_trace:
		push_warning("[GodotMCP] Could not find Debugger controls")


func _find_all_by_class(node: Node, target_class: String) -> Array[Node]:
	var results: Array[Node] = []
	if node.get_class() == target_class:
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_all_by_class(child, target_class))
	return results


func _find_all_nodes(node: Node) -> Array[Node]:
	var results: Array[Node] = [node]
	for child in node.get_children():
		results.append_array(_find_all_nodes(child))
	return results


func _dump_node_tree(node: Node, depth: int, output: PackedStringArray) -> void:
	var indent := "  ".repeat(depth)
	var info := "%s%s [%s]" % [indent, node.name, node.get_class()]
	# add value info for common types
	if node is Label:
		info += " text='%s'" % node.text
	elif node is LineEdit:
		info += " text='%s'" % node.text
	elif node is Button:
		info += " text='%s'" % node.text
	elif node.has_method("get_value"):
		info += " value=%s" % str(node.get_value())
	output.append(info)
	for child in node.get_children():
		_dump_node_tree(child, depth + 1, output)


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
		"get_output":
			_get_output(ws, id, params)
		"get_debugger_errors":
			_get_debugger_errors(ws, id)
		"get_debugger_stack_trace":
			_get_debugger_stack_trace(ws, id)
		"get_debugger_locals":
			_get_debugger_locals(ws, id, params)
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


func _get_debugger_errors(ws: WebSocketPeer, id: Variant) -> void:
	if not debugger_errors_tree:
		_send_error(ws, id, -32000, "Debugger Errors tree not found")
		return

	var errors := _get_tree_text(debugger_errors_tree)
	_send_result(ws, id, {
		"errors": errors,
		"length": errors.length()
	})


func _get_debugger_stack_trace(ws: WebSocketPeer, id: Variant) -> void:
	if not debugger_stack_trace and not debugger_stack_frames:
		_send_error(ws, id, -32000, "Debugger Stack Trace not found")
		return

	# get error message from RichTextLabel
	var error_msg := ""
	if debugger_stack_trace:
		error_msg = debugger_stack_trace.get_parsed_text()

	# get stack frames from Tree
	var frames := ""
	if debugger_stack_frames:
		frames = _get_tree_text(debugger_stack_frames)

	var combined := ""
	if not error_msg.is_empty():
		combined += error_msg
	if not frames.is_empty():
		if not combined.is_empty():
			combined += "\n\nStack frames:\n"
		combined += frames

	_send_result(ws, id, {
		"stack_trace": combined,
		"length": combined.length()
	})


func _get_debugger_locals(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	if not debugger_inspector:
		_send_error(ws, id, -32000, "EditorDebuggerInspector not found")
		return

	# optionally select a specific stack frame first
	var frame_index: int = params.get("frame_index", -1)
	if frame_index >= 0 and debugger_stack_frames:
		var root := debugger_stack_frames.get_root()
		if root:
			var target_item := _get_tree_item_at_index(root, frame_index)
			if target_item:
				debugger_stack_frames.set_selected(target_item, 0)
				# emit signal to trigger inspector update
				debugger_stack_frames.item_selected.emit()
				# small delay for inspector to update
				await get_tree().create_timer(0.05).timeout

	# extract property info from inspector
	var locals := _extract_inspector_properties(debugger_inspector)
	_send_result(ws, id, {
		"locals": locals,
		"count": locals.size(),
		"frame_index": frame_index
	})


func _get_tree_item_at_index(root: TreeItem, index: int) -> TreeItem:
	var current_index := 0
	for child in root.get_children():
		if current_index == index:
			return child
		current_index += 1
	return null


func _extract_inspector_properties(inspector: Control) -> Array:
	var properties: Array = []
	_collect_editor_properties(inspector, properties)
	return properties


func _collect_editor_properties(node: Node, properties: Array) -> void:
	var node_class := node.get_class()

	# EditorProperty subclasses contain the actual property data
	if node_class.begins_with("EditorProperty"):
		var prop_name := ""
		var prop_value := ""

		# try to get label (property name)
		if node.has_method("get_label"):
			prop_name = node.get_label()

		# look for Label child with property name
		for child in node.get_children():
			if child is Label:
				if prop_name.is_empty():
					prop_name = child.text
				break

		# try to extract value based on property type
		if node_class == "EditorPropertyNil":
			prop_value = "null"
		elif node_class == "EditorPropertyInteger" or node_class == "EditorPropertyFloat":
			for child in node.get_children():
				if child.get_class() == "EditorSpinSlider":
					if child.has_method("get_value"):
						prop_value = str(child.get_value())
					break
		elif node_class == "EditorPropertyText":
			for child in node.get_children():
				if child is LineEdit:
					prop_value = child.text
					break
		elif node_class == "EditorPropertyObjectID":
			for child in node.get_children():
				if child is Button:
					prop_value = child.text
					break
		elif node_class == "EditorPropertyVector3" or node_class == "EditorPropertyVector2":
			# find EditorSpinSlider children recursively
			var sliders := _find_all_by_class(node, "EditorSpinSlider")
			if sliders.size() == 3:
				prop_value = "(%s, %s, %s)" % [sliders[0].get_value(), sliders[1].get_value(), sliders[2].get_value()]
			elif sliders.size() == 2:
				prop_value = "(%s, %s)" % [sliders[0].get_value(), sliders[1].get_value()]
		elif node_class == "EditorPropertyCheck":
			for child in node.get_children():
				if child is CheckBox:
					prop_value = "true" if child.button_pressed else "false"
					break
		elif node_class == "EditorPropertyArray":
			for child in node.get_children():
				if child is Button:
					prop_value = child.text
					break
		else:
			# fallback: try to find any text representation
			for child in node.get_children():
				if child is LineEdit:
					prop_value = child.text
					break
				elif child is Label and child.text != prop_name:
					prop_value = child.text
					break
				elif child is Button:
					prop_value = child.text
					break

		if not prop_name.is_empty():
			properties.append({"name": prop_name, "value": prop_value, "type": node_class})

	# recurse into children
	for child in node.get_children():
		_collect_editor_properties(child, properties)


func _get_tree_text(tree: Tree) -> String:
	var root := tree.get_root()
	if not root:
		return ""
	return _get_tree_item_text(root, 0)


func _get_tree_item_text(item: TreeItem, depth: int) -> String:
	var result := ""
	var indent := "  ".repeat(depth)

	# get text from all columns
	var col_count := item.get_tree().get_columns()
	var line := ""
	for col in range(col_count):
		var text := item.get_text(col)
		if not text.is_empty():
			if not line.is_empty():
				line += " | "
			line += text

	if not line.is_empty():
		result += indent + line + "\n"

	# recurse children
	for child in item.get_children():
		result += _get_tree_item_text(child, depth + 1)

	return result


func _send_result(ws: WebSocketPeer, id: Variant, result: Dictionary) -> void:
	var response := {"id": _normalize_id(id), "result": result}
	ws.send_text(JSON.stringify(response))


func _send_error(ws: WebSocketPeer, id: Variant, code: int, message: String) -> void:
	var response := {"id": _normalize_id(id), "error": {"code": code, "message": message}}
	ws.send_text(JSON.stringify(response))


# convert float ids back to int if they're whole numbers (JSON parser makes all numbers float)
func _normalize_id(id: Variant) -> Variant:
	if id is float and id == floorf(id):
		return int(id)
	return id


func _exit_tree() -> void:
	for ws in clients:
		ws.close()
	clients.clear()

	if tcp_server:
		tcp_server.stop()
		tcp_server = null
