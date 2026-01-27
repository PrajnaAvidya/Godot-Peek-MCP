@tool
extends Node

const PORT := 6970
const SCREENSHOT_LISTENER_PORT := 6971
const EDITOR_SCREENSHOT_PATH := "/tmp/godot_peek_editor_screenshot.png"
const GAME_SCREENSHOT_PATH := "/tmp/godot_peek_game_screenshot.png"
const OVERRIDES_PATH := "/tmp/godot_peek_overrides.json"

var tcp_server: TCPServer
var clients: Array[WebSocketPeer] = []
var pending_connections: Array[StreamPeerTCP] = []

# output dock reference
var output_rich_text: RichTextLabel = null
var last_output_length: int = 0

# pending run requests waiting for error check
var _pending_run: Dictionary = {}  # {ws, id, action, scene_path, check_time}

# debugger dock references
var debugger_errors_tree: Tree = null
var debugger_stack_trace: RichTextLabel = null
var debugger_stack_frames: Tree = null
var debugger_inspector: Control = null  # EditorDebuggerInspector
var monitors_tree: Tree = null

# remote scene tree reference
var remote_scene_tree: Tree = null

# main inspector reference (for remote node properties)
var main_inspector: Control = null



func _ready() -> void:
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(PORT)
	if err != OK:
		push_error("[GodotPeek] Failed to start TCP server on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotPeek] WebSocket server listening on ws://localhost:%d" % PORT)

	# find the output and debugger docks
	call_deferred("_find_output_dock")
	call_deferred("_find_debugger_dock")
	# note: remote scene tree found lazily when requested (only exists when game running)


func _find_output_dock() -> void:
	var base := EditorInterface.get_base_control()
	var rich_texts := _find_all_by_class(base, "RichTextLabel")

	# look for the EditorLog's RichTextLabel
	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		if "EditorLog" in path:
			output_rich_text = rt
			last_output_length = rt.get_parsed_text().length()
			return

	push_warning("[GodotPeek] Could not find Output dock (EditorLog RichTextLabel)")


func _find_debugger_dock() -> void:
	var base := EditorInterface.get_base_control()

	# find the Errors Tree (contains warnings/errors)
	var trees := _find_all_by_class(base, "Tree")

	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		if "EditorDebuggerNode" in path and "Errors" in path:
			debugger_errors_tree = tree
			break

	# find the Monitors Tree (performance monitors)
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		if "EditorDebuggerNode" in path and "Monitors" in path:
			monitors_tree = tree
			break

	# find Stack Trace RichTextLabel (error message header)
	var rich_texts := _find_all_by_class(base, "RichTextLabel")
	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		if "EditorDebuggerNode" in path and "Stack Trace" in path:
			debugger_stack_trace = rt
			break

	# find Stack Trace Tree (actual stack frames)
	# look for Tree inside Stack Trace/HSplitContainer/.../VBoxContainer
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		if "Stack Trace" in path and "VBoxContainer" in path:
			debugger_stack_frames = tree
			break

	# find EditorDebuggerInspector (shows locals when frame selected)
	var all_nodes := _find_all_nodes(base)
	for node in all_nodes:
		if node.get_class() == "EditorDebuggerInspector":
			debugger_inspector = node
			break

	# warn if critical controls not found
	if not debugger_errors_tree:
		push_warning("[GodotPeek] Could not find Debugger Errors tree")
	if not debugger_stack_trace:
		push_warning("[GodotPeek] Could not find Debugger Stack Trace message")
	if not debugger_stack_frames:
		push_warning("[GodotPeek] Could not find Debugger Stack Frames tree")
	if not debugger_inspector:
		push_warning("[GodotPeek] Could not find EditorDebuggerInspector")
	if not monitors_tree:
		push_warning("[GodotPeek] Could not find Monitors tree")




func _find_remote_scene_tree() -> void:
	var base := EditorInterface.get_base_control()
	var all_nodes := _find_all_nodes(base)

	# EditorDebuggerTree IS the remote scene tree (inherits from Tree)
	for node in all_nodes:
		if node.get_class() == "EditorDebuggerTree":
			remote_scene_tree = node as Tree
			return

	# no warning here - this is expected when game isn't running


func _find_main_inspector() -> void:
	if main_inspector:
		return

	var base := EditorInterface.get_base_control()
	var all_nodes := _find_all_nodes(base)

	for node in all_nodes:
		var path := str(node.get_path())
		if node.get_class() == "EditorInspector" and "DockSlotRightUL/Inspector/@EditorInspector" in path:
			main_inspector = node
			return

	push_warning("[GodotPeek] Could not find main EditorInspector")


func _find_tree_item_by_path(root: TreeItem, path_parts: Array) -> TreeItem:
	# navigate down the tree following path_parts
	# first part should match root itself (usually "root")
	if path_parts.is_empty():
		return root

	var current := root
	var start_idx := 0

	# if first part matches root's text, skip it
	if path_parts[0] == root.get_text(0):
		start_idx = 1

	# navigate through remaining parts
	for i in range(start_idx, path_parts.size()):
		var part: String = path_parts[i]
		var found := false
		for child in current.get_children():
			if child.get_text(0) == part:
				current = child
				found = true
				break
		if not found:
			return null

	return current


func _get_remote_node_properties(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_error(ws, id, -32602, "Missing required parameter: node_path")
		return

	# find remote scene tree (lazy, only exists when game running)
	_find_remote_scene_tree()
	if not remote_scene_tree:
		_send_error(ws, id, -32000, "Remote scene tree not found (is game running?)")
		return

	# find main inspector (lazy)
	_find_main_inspector()
	if not main_inspector:
		_send_error(ws, id, -32000, "Main inspector not found")
		return

	# parse path and find node in tree
	var path_parts := node_path.trim_prefix("/").split("/")
	var root := remote_scene_tree.get_root()
	if not root:
		_send_error(ws, id, -32000, "Remote scene tree has no root")
		return

	var target := _find_tree_item_by_path(root, path_parts)
	if not target:
		_send_error(ws, id, -32000, "Node not found in remote tree: %s" % node_path)
		return

	# get object ID from TreeItem metadata
	var object_id = target.get_metadata(0)
	if object_id == null:
		_send_error(ws, id, -32000, "No object ID for node: %s" % node_path)
		return

	# trigger remote object inspection via objects_selected signal
	remote_scene_tree.set_selected(target, 0)
	var ids := PackedInt64Array([object_id])
	remote_scene_tree.objects_selected.emit(ids, 0)

	# wait for inspector to populate
	await get_tree().create_timer(0.3).timeout

	# extract properties from main inspector
	var props := _extract_inspector_properties(main_inspector)
	_send_result(ws, id, {
		"node_path": node_path,
		"properties": props,
		"count": props.size()
	})


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


func _process(_delta: float) -> void:
	_accept_new_connections()
	_process_pending_connections()
	_process_clients()
	_check_pending_run()


# check if a pending run request is ready for error checking
func _check_pending_run() -> void:
	if _pending_run.is_empty():
		return

	var now := Time.get_ticks_msec()
	if now < _pending_run.check_time:
		return

	# time to check for errors
	var ws: WebSocketPeer = _pending_run.ws
	var id: Variant = _pending_run.id
	var action: String = _pending_run.action
	var scene_path: String = _pending_run.scene_path
	_pending_run = {}

	var error_detected := false
	var stack_trace := ""

	# re-find debugger controls fresh (they may change between sessions)
	_find_debugger_dock()

	var header := ""
	var frames := ""

	if debugger_stack_trace:
		header = debugger_stack_trace.get_parsed_text()

	if debugger_stack_frames:
		frames = _get_tree_text(debugger_stack_frames)

	# check for error in header OR if frames exist (frames only appear on error)
	if "Error" in header or "error" in header:
		error_detected = true
		stack_trace = header
		if not frames.is_empty():
			stack_trace += "\n\nStack frames:\n" + frames
	elif not frames.is_empty():
		# frames exist but header doesn't say error - still an error condition
		error_detected = true
		stack_trace = header + "\n\nStack frames:\n" + frames

	# also check debugger errors tree
	if not error_detected and debugger_errors_tree:
		var errors := _get_tree_text(debugger_errors_tree)
		if not errors.is_empty():
			error_detected = true
			stack_trace = errors

	if error_detected:
		EditorInterface.stop_playing_scene()

	var result := {
		"success": not error_detected,
		"action": action,
		"error_detected": error_detected,
		"stack_trace": stack_trace
	}
	if not scene_path.is_empty():
		result["scene_path"] = scene_path

	_send_result(ws, id, result)


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
				print("[GodotPeek] Client connected")
			else:
				push_error("[GodotPeek] WebSocket accept failed: %s" % error_string(err))
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
			print("[GodotPeek] Client disconnected")
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

	print("[GodotPeek] Received: method=%s id=%s" % [method, str(id)])

	match method:
		"ping":
			_send_result(ws, id, {"pong": true})
		"run_main_scene":
			_run_main_scene(ws, id, params)
		"run_scene":
			_run_scene(ws, id, params)
		"run_current_scene":
			_run_current_scene(ws, id, params)
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
		"get_remote_scene_tree":
			_get_remote_scene_tree(ws, id)
		"get_remote_node_properties":
			_get_remote_node_properties(ws, id, params)
		"get_screenshot":
			_get_screenshot(ws, id, params)
		"get_monitors":
			_get_monitors(ws, id)
		_:
			_send_error(ws, id, -32601, "Method not found: %s" % method)


func _run_main_scene(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_main_scene()

	# queue error check (needs time for game to start and error to appear)
	_pending_run = {
		"ws": ws,
		"id": id,
		"action": "run_main_scene",
		"scene_path": "",
		"check_time": Time.get_ticks_msec() + 1500
	}


func _run_scene(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		_send_error(ws, id, -32602, "Missing required parameter: scene_path")
		return

	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_custom_scene(scene_path)

	# queue error check for 1500ms from now
	_pending_run = {
		"ws": ws,
		"id": id,
		"action": "run_scene",
		"scene_path": scene_path,
		"check_time": Time.get_ticks_msec() + 1500
	}


func _run_current_scene(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_current_scene()

	# queue error check for 1500ms from now
	_pending_run = {
		"ws": ws,
		"id": id,
		"action": "run_current_scene",
		"scene_path": "",
		"check_time": Time.get_ticks_msec() + 1500
	}


# write overrides file for runtime helper to read
func _write_overrides(overrides: Variant) -> void:
	if overrides == null or (overrides is Dictionary and overrides.is_empty()):
		# delete file if no overrides
		if FileAccess.file_exists(OVERRIDES_PATH):
			DirAccess.remove_absolute(OVERRIDES_PATH)
		return

	var file := FileAccess.open(OVERRIDES_PATH, FileAccess.WRITE)
	if not file:
		push_error("[GodotPeek] Failed to write overrides file: %s" % error_string(FileAccess.get_open_error()))
		return

	file.store_string(JSON.stringify(overrides))
	file.close()
	print("[GodotPeek] Wrote overrides to %s" % OVERRIDES_PATH)


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


func _get_remote_scene_tree(ws: WebSocketPeer, id: Variant) -> void:
	# find fresh each time since Remote tab only exists when game is running
	_find_remote_scene_tree()

	if not remote_scene_tree:
		_send_error(ws, id, -32000, "Remote scene tree not found (is game running?)")
		return

	var tree_text := _get_scene_tree_text(remote_scene_tree)
	_send_result(ws, id, {
		"tree": tree_text,
		"length": tree_text.length()
	})


func _get_monitors(ws: WebSocketPeer, id: Variant) -> void:
	if not monitors_tree:
		_send_error(ws, id, -32000, "Monitors tree not found")
		return

	var monitors := _extract_monitors(monitors_tree)
	_send_result(ws, id, {
		"monitors": monitors,
		"count": monitors.size()
	})


func _extract_monitors(tree: Tree) -> Array:
	# monitors tree has groups (Time, Memory, etc) with metric children
	var result: Array = []
	var root := tree.get_root()
	if not root:
		return result

	# iterate through group items (top-level children of root)
	for group_item in root.get_children():
		var group_name := group_item.get_text(0)
		var metrics: Array = []

		# iterate through metric items within the group
		for metric_item in group_item.get_children():
			var metric_name := metric_item.get_text(0)
			var metric_value := metric_item.get_text(1)  # value is in column 1
			metrics.append({"name": metric_name, "value": metric_value})

		result.append({"group": group_name, "metrics": metrics})

	return result


func _get_screenshot(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	var target: String = params.get("target", "")
	if target.is_empty():
		_send_error(ws, id, -32602, "Missing required parameter: target")
		return

	if target == "editor":
		_get_editor_screenshot(ws, id)
	elif target == "game":
		_get_game_screenshot(ws, id)
	else:
		_send_error(ws, id, -32602, "Invalid target '%s': must be 'editor' or 'game'" % target)


func _get_editor_screenshot(ws: WebSocketPeer, id: Variant) -> void:
	# capture 2D and 3D viewports
	var vp_2d := EditorInterface.get_editor_viewport_2d()
	var vp_3d := EditorInterface.get_editor_viewport_3d()

	if not vp_2d and not vp_3d:
		_send_error(ws, id, -32000, "Could not find editor viewports")
		return

	var img_2d: Image = null
	var img_3d: Image = null

	# only capture viewports that have meaningful size (> 10px)
	const MIN_SIZE := 10
	if vp_2d and vp_2d.size.x > MIN_SIZE and vp_2d.size.y > MIN_SIZE:
		var tex := vp_2d.get_texture()
		if tex:
			img_2d = tex.get_image()

	if vp_3d and vp_3d.size.x > MIN_SIZE and vp_3d.size.y > MIN_SIZE:
		var tex := vp_3d.get_texture()
		if tex:
			img_3d = tex.get_image()

	# use whichever viewport(s) are available
	var combined: Image
	var width := 0
	var height := 0

	if img_2d and img_3d:
		# convert both to same format before combining
		img_2d.convert(Image.FORMAT_RGBA8)
		img_3d.convert(Image.FORMAT_RGBA8)
		width = img_2d.get_width() + img_3d.get_width()
		height = max(img_2d.get_height(), img_3d.get_height())
		combined = Image.create(width, height, false, Image.FORMAT_RGBA8)
		combined.blit_rect(img_2d, Rect2i(Vector2i.ZERO, img_2d.get_size()), Vector2i.ZERO)
		combined.blit_rect(img_3d, Rect2i(Vector2i.ZERO, img_3d.get_size()), Vector2i(img_2d.get_width(), 0))
	elif img_2d:
		combined = img_2d
		width = img_2d.get_width()
		height = img_2d.get_height()
	elif img_3d:
		combined = img_3d
		width = img_3d.get_width()
		height = img_3d.get_height()
	else:
		_send_error(ws, id, -32000, "Failed to capture editor viewports (both too small or empty)")
		return

	var err := combined.save_png(EDITOR_SCREENSHOT_PATH)
	if err != OK:
		_send_error(ws, id, -32000, "Failed to save screenshot: %s" % error_string(err))
		return

	_send_result(ws, id, {
		"path": EDITOR_SCREENSHOT_PATH,
		"target": "editor",
		"width": width,
		"height": height
	})


func _get_game_screenshot(ws: WebSocketPeer, id: Variant) -> void:
	# check if game is running
	if not EditorInterface.is_playing_scene():
		_send_error(ws, id, -32000, "Game is not running")
		return

	# send UDP request to screenshot listener in game
	var udp := PacketPeerUDP.new()
	var err := udp.set_dest_address("127.0.0.1", SCREENSHOT_LISTENER_PORT)
	if err != OK:
		_send_error(ws, id, -32000, "Failed to set UDP destination: %s" % error_string(err))
		return

	var request := {"cmd": "screenshot"}
	err = udp.put_packet(JSON.stringify(request).to_utf8_buffer())
	if err != OK:
		_send_error(ws, id, -32000, "Failed to send UDP request: %s" % error_string(err))
		return

	# wait for response with timeout
	var timeout := 2.0
	var elapsed := 0.0
	var poll_interval := 0.05

	while elapsed < timeout:
		await get_tree().create_timer(poll_interval).timeout
		elapsed += poll_interval

		if udp.get_available_packet_count() > 0:
			var packet := udp.get_packet()
			var response_str := packet.get_string_from_utf8()

			var json := JSON.new()
			if json.parse(response_str) != OK:
				_send_error(ws, id, -32000, "Invalid response from screenshot listener")
				return

			var response: Dictionary = json.data
			if response.has("error"):
				_send_error(ws, id, -32000, "Screenshot listener error: %s" % response.error)
				return

			_send_result(ws, id, {
				"path": response.get("path", GAME_SCREENSHOT_PATH),
				"target": "game",
				"width": response.get("width", 0),
				"height": response.get("height", 0)
			})
			return

	_send_error(ws, id, -32000, "Timeout waiting for screenshot. Is screenshot_listener.gd added as autoload in your project?")


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


func _get_scene_tree_text(tree: Tree) -> String:
	var root := tree.get_root()
	if not root:
		return ""
	return _get_scene_tree_item_text(root, 0)


func _get_scene_tree_item_text(item: TreeItem, depth: int) -> String:
	var result := ""
	var indent := "  ".repeat(depth)

	# get node name from column 0
	var node_name := item.get_text(0)
	if not node_name.is_empty():
		# get node type from tooltip or metadata if available
		var node_type := ""
		var tooltip := item.get_tooltip_text(0)
		if not tooltip.is_empty():
			# tooltip often contains "NodeName (Type)" or just type info
			var paren_pos := tooltip.find("(")
			if paren_pos != -1:
				var end_paren := tooltip.find(")", paren_pos)
				if end_paren != -1:
					node_type = tooltip.substr(paren_pos + 1, end_paren - paren_pos - 1)

		# build output line
		if not node_type.is_empty():
			result += indent + node_name + " (" + node_type + ")\n"
		else:
			result += indent + node_name + "\n"

	# recurse children
	for child in item.get_children():
		result += _get_scene_tree_item_text(child, depth + 1)

	return result


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
