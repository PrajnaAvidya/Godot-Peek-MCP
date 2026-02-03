@tool
extends Node

# set to true to enable verbose logging for node discovery debugging
const DEBUG_VERBOSE := false

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

# godot version - explicitly supported: 4.4, 4.5, 4.6
# version string like "4.4", "4.5", "4.6" (no patch version)
var _godot_version := ""

# pending run requests waiting for error check
var _pending_run: Dictionary = {}  # {ws, id, action, scene_path, check_time}

# auto-stop tracking
var _mcp_launch_id: int = 0  # increments each time MCP starts a scene
var _auto_stop_timer: SceneTreeTimer = null
var _auto_stop_launch_id: int = 0  # launch_id when timer was scheduled
var _was_playing: bool = false  # track play state to detect stops

# debugger dock references
var debugger_errors_tree: Tree = null
var debugger_stack_trace: RichTextLabel = null
var debugger_stack_trace_label: Label = null  # 4.4 only (4.5/4.6 use RichTextLabel above)
var debugger_stack_frames: Tree = null
var debugger_inspector: Control = null  # EditorDebuggerInspector
var monitors_tree: Tree = null

# remote scene tree reference
var remote_scene_tree: Tree = null

# main inspector reference (for remote node properties)
var main_inspector: Control = null



func _ready() -> void:
	# detect and validate godot version
	var version := Engine.get_version_info()
	var major: int = version.major
	var minor: int = version.minor

	# only support specific 4.x versions
	if major == 4 and minor in [4, 5, 6]:
		_godot_version = "%d.%d" % [major, minor]
	else:
		push_error("[GodotPeek] Unsupported Godot version %d.%d. Supported versions: 4.4, 4.5, 4.6" % [major, minor])
		return

	print("[GodotPeek] Godot %s detected" % _godot_version)
	if DEBUG_VERBOSE:
		print("[GodotPeek] DEBUG_VERBOSE is ON - verbose logging enabled")

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


func _debug(msg: String) -> void:
	if DEBUG_VERBOSE:
		print("[GodotPeek:DEBUG] %s" % msg)


func _find_output_dock() -> void:
	_debug("=== _find_output_dock ===")
	var base := EditorInterface.get_base_control()
	var rich_texts := _find_all_by_class(base, "RichTextLabel")
	_debug("found %d RichTextLabel nodes" % rich_texts.size())

	# look for the EditorLog's RichTextLabel
	# path patterns differ by version
	_debug("using pattern for version %s" % _godot_version)

	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		var found := false
		match _godot_version:
			"4.6":
				# 4.6: node renamed to "Output" under EditorBottomPanel
				found = "EditorBottomPanel" in path and "/Output/" in path
			"4.4", "4.5":
				# 4.4/4.5: node named "EditorLog" contains it
				found = "EditorLog" in path
		_debug("  checking: %s -> %s" % [path, "MATCH" if found else "no match"])
		if found:
			output_rich_text = rt
			last_output_length = rt.get_parsed_text().length()
			_debug("output_rich_text FOUND")
			return

	_debug("output_rich_text NOT FOUND")
	push_warning("[GodotPeek] Could not find Output dock (EditorLog RichTextLabel)")


func _find_debugger_dock() -> void:
	_debug("=== _find_debugger_dock ===")
	var base := EditorInterface.get_base_control()

	# debugger node path differs by version
	var debugger_pattern := ""
	match _godot_version:
		"4.6":
			# 4.6: node renamed to "/Debugger/"
			debugger_pattern = "/Debugger/"
		"4.4", "4.5":
			# 4.4/4.5: "EditorDebuggerNode" in path
			debugger_pattern = "EditorDebuggerNode"
	_debug("debugger_pattern for %s: %s" % [_godot_version, debugger_pattern])

	# find the Errors Tree (contains warnings/errors)
	# note: in 4.6 tab name may include count like "Errors (1)" but path still matches
	var trees := _find_all_by_class(base, "Tree")
	_debug("found %d Tree nodes" % trees.size())

	_debug("--- searching for Errors tree ---")
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		var matches_debugger := debugger_pattern in path
		var matches_errors := "/Errors" in path
		if matches_debugger or matches_errors:
			_debug("  %s -> debugger:%s errors:%s" % [path, matches_debugger, matches_errors])
		if matches_debugger and matches_errors:
			debugger_errors_tree = tree
			_debug("  -> SELECTED as debugger_errors_tree")
			break

	# find the Monitors Tree (performance monitors)
	_debug("--- searching for Monitors tree ---")
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		var matches_debugger := debugger_pattern in path
		var matches_monitors := "/Monitors" in path
		if matches_debugger or matches_monitors:
			_debug("  %s -> debugger:%s monitors:%s" % [path, matches_debugger, matches_monitors])
		if matches_debugger and matches_monitors:
			monitors_tree = tree
			_debug("  -> SELECTED as monitors_tree")
			break

	# find Stack Trace error message header
	# 4.5/4.6: RichTextLabel, 4.4: Label
	var rich_texts := _find_all_by_class(base, "RichTextLabel")
	_debug("--- searching for Stack Trace RichTextLabel (found %d total) ---" % rich_texts.size())
	for rt: RichTextLabel in rich_texts:
		var path: String = str(rt.get_path())
		var matches_debugger := debugger_pattern in path
		var matches_stack := "/Stack Trace/" in path
		if matches_debugger or matches_stack:
			_debug("  %s -> debugger:%s stack:%s" % [path, matches_debugger, matches_stack])
		if matches_debugger and matches_stack:
			debugger_stack_trace = rt
			_debug("  -> SELECTED as debugger_stack_trace")
			break

	# 4.4: Stack Trace uses Label instead of RichTextLabel
	if not debugger_stack_trace and _godot_version == "4.4":
		_debug("--- searching for Stack Trace Label (4.4) ---")
		var labels := _find_all_by_class(base, "Label")
		for lbl: Label in labels:
			var path: String = str(lbl.get_path())
			var matches_debugger := debugger_pattern in path
			var matches_stack := "/Stack Trace/" in path
			# prefer the one directly under Stack Trace/@HBoxContainer (error header)
			var is_header := "/Stack Trace/@HBoxContainer" in path
			if matches_debugger or matches_stack:
				_debug("  %s -> debugger:%s stack:%s header:%s" % [path, matches_debugger, matches_stack, is_header])
			if matches_debugger and matches_stack and is_header:
				debugger_stack_trace_label = lbl
				_debug("  -> SELECTED as debugger_stack_trace_label")
				break

	# find Stack Trace Tree (actual stack frames)
	# look for Tree inside Stack Trace/HSplitContainer/.../VBoxContainer
	_debug("--- searching for Stack Frames tree ---")
	for tree: Tree in trees:
		var path: String = str(tree.get_path())
		var matches_stack := "/Stack Trace/" in path
		var matches_vbox := "VBoxContainer" in path
		if matches_stack or matches_vbox:
			_debug("  %s -> stack:%s vbox:%s" % [path, matches_stack, matches_vbox])
		if matches_stack and matches_vbox:
			debugger_stack_frames = tree
			_debug("  -> SELECTED as debugger_stack_frames")
			break

	# find EditorDebuggerInspector (shows locals when frame selected)
	_debug("--- searching for EditorDebuggerInspector ---")
	var all_nodes := _find_all_nodes(base)
	_debug("searching %d total nodes for EditorDebuggerInspector class" % all_nodes.size())
	for node in all_nodes:
		if node.get_class() == "EditorDebuggerInspector":
			debugger_inspector = node
			_debug("  FOUND: %s" % node.get_path())
			break

	# summary
	_debug("--- summary ---")
	_debug("  debugger_errors_tree: %s" % ("FOUND" if debugger_errors_tree else "NOT FOUND"))
	_debug("  monitors_tree: %s" % ("FOUND" if monitors_tree else "NOT FOUND"))
	_debug("  debugger_stack_trace: %s" % ("FOUND" if debugger_stack_trace else "NOT FOUND"))
	_debug("  debugger_stack_trace_label: %s" % ("FOUND" if debugger_stack_trace_label else "NOT FOUND"))
	_debug("  debugger_stack_frames: %s" % ("FOUND" if debugger_stack_frames else "NOT FOUND"))
	_debug("  debugger_inspector: %s" % ("FOUND" if debugger_inspector else "NOT FOUND"))

	# warn if critical controls not found
	if not debugger_errors_tree:
		push_warning("[GodotPeek] Could not find Debugger Errors tree")
	if not debugger_stack_trace and not debugger_stack_trace_label:
		push_warning("[GodotPeek] Could not find Debugger Stack Trace message")
	if not debugger_stack_frames:
		push_warning("[GodotPeek] Could not find Debugger Stack Frames tree")
	if not debugger_inspector:
		push_warning("[GodotPeek] Could not find EditorDebuggerInspector")
	if not monitors_tree:
		push_warning("[GodotPeek] Could not find Monitors tree")




func _find_remote_scene_tree() -> void:
	_debug("=== _find_remote_scene_tree ===")
	var base := EditorInterface.get_base_control()
	var all_nodes := _find_all_nodes(base)
	_debug("searching %d total nodes" % all_nodes.size())

	# click "Remote" button to populate the tree (required in 4.4/4.5/4.6)
	_debug("searching for Remote button")
	var found_remote_btn := false
	var all_scene_buttons: Array[String] = []
	for node in all_nodes:
		var path := str(node.get_path())
		if "/Scene/" in path and node is Button:
			var btn := node as Button
			all_scene_buttons.append("'%s' at %s" % [btn.text, path])
			if btn.text == "Remote":
				found_remote_btn = true
				_debug("  FOUND Remote button: pressed=%s path=%s" % [btn.button_pressed, path])
				if not btn.button_pressed:
					_debug("  -> clicking Remote button")
					btn.button_pressed = true
					btn.pressed.emit()
				else:
					_debug("  -> Remote button already pressed")
				break
	if not found_remote_btn:
		_debug("  Remote button NOT FOUND")
		_debug("  all buttons in /Scene/: %s" % str(all_scene_buttons))

	# EditorDebuggerTree IS the remote scene tree (inherits from Tree)
	_debug("--- searching for EditorDebuggerTree ---")
	for node in all_nodes:
		if node.get_class() == "EditorDebuggerTree":
			remote_scene_tree = node as Tree
			_debug("  FOUND: %s" % node.get_path())
			return

	_debug("  EditorDebuggerTree NOT FOUND")
	remote_scene_tree = null


func _find_main_inspector() -> void:
	_debug("=== _find_main_inspector ===")
	if main_inspector:
		_debug("already cached, skipping")
		return

	var base := EditorInterface.get_base_control()
	var all_nodes := _find_all_nodes(base)
	_debug("searching %d total nodes for EditorInspector" % all_nodes.size())

	# inspector path differs slightly by version but all have DockSlotRightUL/Inspector/
	# use looser match that works across 4.4/4.5/4.6
	for node in all_nodes:
		var path := str(node.get_path())
		if node.get_class() == "EditorInspector":
			var matches_dock := "DockSlotRightUL/Inspector/" in path
			_debug("  EditorInspector: %s -> dock_match:%s" % [path, matches_dock])
			if matches_dock:
				main_inspector = node
				_debug("  -> SELECTED as main_inspector")
				return

	_debug("main_inspector NOT FOUND")
	push_warning("[GodotPeek] Could not find main EditorInspector")


func _find_tree_item_by_path(root: TreeItem, path_parts: Array) -> TreeItem:
	_debug("=== _find_tree_item_by_path: %s ===" % str(path_parts))
	# navigate down the tree following path_parts
	# first part should match root itself (usually "root")
	if path_parts.is_empty():
		_debug("  empty path_parts, returning root")
		return root

	var current := root
	var start_idx := 0

	# if first part matches root's text, skip it
	if path_parts[0] == root.get_text(0):
		_debug("  first part '%s' matches root, skipping" % path_parts[0])
		start_idx = 1

	# navigate through remaining parts
	for i in range(start_idx, path_parts.size()):
		var part: String = path_parts[i]
		var found := false
		var children_names: Array[String] = []
		for child in current.get_children():
			var child_text := child.get_text(0)
			children_names.append(child_text)
			if child_text == part:
				current = child
				found = true
				break
		_debug("  level %d: looking for '%s' in %s -> %s" % [i, part, children_names, "FOUND" if found else "NOT FOUND"])
		if not found:
			return null

	_debug("  final item: '%s'" % current.get_text(0))
	return current


func _get_remote_node_properties(ws: WebSocketPeer, id: Variant, params: Dictionary) -> void:
	_debug("=== _get_remote_node_properties ===")
	var node_path: String = params.get("node_path", "")
	_debug("node_path: %s" % node_path)
	if node_path.is_empty():
		_send_error(ws, id, -32602, "Missing required parameter: node_path")
		return

	# find remote scene tree (lazy, only exists when game running)
	# also clicks the Remote button if needed to populate the tree
	_find_remote_scene_tree()
	if not remote_scene_tree:
		_debug("remote_scene_tree not found, aborting")
		_send_error(ws, id, -32000, "Remote scene tree not found (is game running?)")
		return

	# find main inspector (lazy)
	_find_main_inspector()
	if not main_inspector:
		_debug("main_inspector not found, aborting")
		_send_error(ws, id, -32000, "Main inspector not found")
		return

	# parse path and find node in tree
	var path_parts := node_path.trim_prefix("/").split("/")
	_debug("path_parts: %s" % str(path_parts))
	var root := remote_scene_tree.get_root()
	_debug("remote_scene_tree.get_root(): %s" % ("exists" if root else "null"))

	# wait for tree to populate if needed (after clicking Remote button)
	if not root or root.get_child_count() == 0:
		_debug("root empty or no children, waiting 0.15s...")
		await get_tree().create_timer(0.15).timeout
		root = remote_scene_tree.get_root()
		_debug("after wait: root=%s child_count=%d" % [
			"exists" if root else "null",
			root.get_child_count() if root else 0
		])

	if not root:
		_send_error(ws, id, -32000, "Remote scene tree has no root")
		return

	var target := _find_tree_item_by_path(root, path_parts)
	if not target:
		_debug("target tree item not found")
		_send_error(ws, id, -32000, "Node not found in remote tree: %s" % node_path)
		return

	# get object ID from TreeItem metadata
	var object_id = target.get_metadata(0)
	_debug("object_id from metadata: %s" % str(object_id))
	if object_id == null:
		_send_error(ws, id, -32000, "No object ID for node: %s" % node_path)
		return

	# trigger remote object inspection
	_debug("triggering inspection for object_id %s" % str(object_id))
	_debug("remote_scene_tree class: %s" % remote_scene_tree.get_class())

	remote_scene_tree.set_selected(target, 0)

	# trigger inspection via version-specific signal
	match _godot_version:
		"4.5", "4.6":
			_debug("using objects_selected signal (%s)" % _godot_version)
			var ids := PackedInt64Array([object_id])
			remote_scene_tree.objects_selected.emit(ids, 0)
		"4.4":
			_debug("using object_selected signal (4.4)")
			remote_scene_tree.object_selected.emit(object_id, 0)

	# wait for inspector to populate
	_debug("waiting 0.3s for inspector to populate...")
	await get_tree().create_timer(0.3).timeout

	# extract properties from main inspector
	_debug("main_inspector class: %s" % main_inspector.get_class())
	_debug("main_inspector visible: %s" % main_inspector.visible)
	var props := _extract_inspector_properties(main_inspector)
	_debug("extracted %d properties" % props.size())
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
	_check_play_state()


# check if a pending run request is ready for error checking
func _check_pending_run() -> void:
	if _pending_run.is_empty():
		return

	var now := Time.get_ticks_msec()
	if now < _pending_run.check_time:
		return

	_debug("=== _check_pending_run (error check time reached) ===")

	# time to check for errors
	var ws: WebSocketPeer = _pending_run.ws
	var id: Variant = _pending_run.id
	var action: String = _pending_run.action
	var scene_path: String = _pending_run.scene_path
	_pending_run = {}
	_debug("action: %s, scene_path: %s" % [action, scene_path])

	var error_detected := false
	var stack_trace := ""

	# re-find debugger controls fresh (they may change between sessions)
	_find_debugger_dock()

	var header := ""
	var frames := ""

	if debugger_stack_trace:
		header = debugger_stack_trace.get_parsed_text()
		_debug("stack_trace header from RichTextLabel (%d chars): %s" % [header.length(), header.substr(0, 200)])
	elif debugger_stack_trace_label:
		header = debugger_stack_trace_label.text
		_debug("stack_trace header from Label (%d chars): %s" % [header.length(), header.substr(0, 200)])
	else:
		_debug("no stack_trace control found, no header")

	if debugger_stack_frames:
		frames = _get_tree_text(debugger_stack_frames)
		_debug("stack_frames (%d chars): %s" % [frames.length(), frames.substr(0, 200)])
	else:
		_debug("debugger_stack_frames is null, no frames")

	# check for error in header OR if frames exist (frames only appear on error)
	# note: debugger errors tree contains warnings too (eg INTEGER_DIVISION) which shouldn't stop the game
	var has_error_keyword := "Error" in header or "error" in header
	var has_frames := not frames.is_empty()
	_debug("has_error_keyword: %s, has_frames: %s" % [has_error_keyword, has_frames])

	if has_error_keyword:
		error_detected = true
		stack_trace = header
		if has_frames:
			stack_trace += "\n\nStack frames:\n" + frames
	elif has_frames:
		# frames exist but header doesn't say error - still an error condition
		error_detected = true
		stack_trace = header + "\n\nStack frames:\n" + frames

	_debug("error_detected: %s" % error_detected)

	if error_detected:
		_debug("stopping scene due to error")
		EditorInterface.stop_playing_scene()

	# collect warnings/errors from errors tree (informational, doesn't affect success)
	var warnings := ""
	if debugger_errors_tree:
		warnings = _get_tree_text(debugger_errors_tree)
		_debug("warnings (%d chars): %s" % [warnings.length(), warnings.substr(0, 200)])

	var result := {
		"success": not error_detected,
		"action": action,
		"error_detected": error_detected,
		"stack_trace": stack_trace,
		"warnings": warnings
	}
	if not scene_path.is_empty():
		result["scene_path"] = scene_path

	_send_result(ws, id, result)


# detect when game stops to invalidate auto-stop timer
func _check_play_state() -> void:
	var is_playing := EditorInterface.is_playing_scene()
	if _was_playing and not is_playing:
		# game just stopped - invalidate launch_id so pending timer won't match
		# this handles: user closes game, then reopens manually before timer fires
		_mcp_launch_id += 1
		_debug("game stopped, invalidated launch_id (now %d)" % _mcp_launch_id)
		_auto_stop_timer = null
		_auto_stop_launch_id = 0
	_was_playing = is_playing


# schedule auto-stop for current scene
func _schedule_auto_stop(timeout_seconds: float) -> void:
	if timeout_seconds <= 0:
		return

	# cancel any existing timer
	_auto_stop_timer = null

	# capture current launch id
	_auto_stop_launch_id = _mcp_launch_id
	var captured_launch_id := _mcp_launch_id

	_debug("scheduling auto-stop in %.1fs for launch_id %d" % [timeout_seconds, captured_launch_id])

	# create timer
	_auto_stop_timer = get_tree().create_timer(timeout_seconds)
	_auto_stop_timer.timeout.connect(func():
		_on_auto_stop_timeout(captured_launch_id)
	)


func _on_auto_stop_timeout(launch_id: int) -> void:
	_debug("auto-stop timeout fired for launch_id %d (current: %d)" % [launch_id, _mcp_launch_id])

	# only stop if this is still the same launch we scheduled for
	if launch_id != _mcp_launch_id:
		_debug("launch_id mismatch, not stopping")
		return

	if not EditorInterface.is_playing_scene():
		_debug("game not running, not stopping")
		return

	print("[GodotPeek] Auto-stopping scene (timeout reached)")
	EditorInterface.stop_playing_scene()
	_auto_stop_timer = null
	_auto_stop_launch_id = 0


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

	# increment launch id before starting
	_mcp_launch_id += 1
	_debug("run_main_scene: launch_id now %d" % _mcp_launch_id)

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_main_scene()

	# schedule auto-stop if timeout specified
	var timeout: float = params.get("timeout_seconds", 0.0)
	_schedule_auto_stop(timeout)

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

	# increment launch id before starting
	_mcp_launch_id += 1
	_debug("run_scene: launch_id now %d" % _mcp_launch_id)

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_custom_scene(scene_path)

	# schedule auto-stop if timeout specified
	var timeout: float = params.get("timeout_seconds", 0.0)
	_schedule_auto_stop(timeout)

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

	# increment launch id before starting
	_mcp_launch_id += 1
	_debug("run_current_scene: launch_id now %d" % _mcp_launch_id)

	_write_overrides(params.get("overrides", {}))
	EditorInterface.play_current_scene()

	# schedule auto-stop if timeout specified
	var timeout: float = params.get("timeout_seconds", 0.0)
	_schedule_auto_stop(timeout)

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
	if not debugger_stack_trace and not debugger_stack_trace_label and not debugger_stack_frames:
		_send_error(ws, id, -32000, "Debugger Stack Trace not found")
		return

	# get error message: RichTextLabel (4.5/4.6) or Label (4.4)
	var error_msg := ""
	if debugger_stack_trace:
		error_msg = debugger_stack_trace.get_parsed_text()
	elif debugger_stack_trace_label:
		error_msg = debugger_stack_trace_label.text

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
	_debug("=== _get_debugger_locals ===")
	if not debugger_inspector:
		_debug("debugger_inspector not found, aborting")
		_send_error(ws, id, -32000, "EditorDebuggerInspector not found")
		return

	# optionally select a specific stack frame first
	var frame_index: int = params.get("frame_index", -1)
	_debug("frame_index: %d" % frame_index)
	if frame_index >= 0 and debugger_stack_frames:
		_debug("selecting frame %d in stack_frames tree" % frame_index)
		var root := debugger_stack_frames.get_root()
		_debug("stack_frames root: %s" % ("exists" if root else "null"))
		if root:
			var target_item := _get_tree_item_at_index(root, frame_index)
			_debug("target_item at index %d: %s" % [frame_index, "found" if target_item else "not found"])
			if target_item:
				debugger_stack_frames.set_selected(target_item, 0)
				# emit signal to trigger inspector update
				debugger_stack_frames.item_selected.emit()
				_debug("emitted item_selected, waiting 0.05s...")
				# small delay for inspector to update
				await get_tree().create_timer(0.05).timeout
	elif frame_index >= 0:
		_debug("frame_index specified but debugger_stack_frames is null")

	# extract property info from inspector
	var locals := _extract_inspector_properties(debugger_inspector)
	_debug("extracted %d locals" % locals.size())
	_send_result(ws, id, {
		"locals": locals,
		"count": locals.size(),
		"frame_index": frame_index
	})


func _get_remote_scene_tree(ws: WebSocketPeer, id: Variant) -> void:
	# find fresh each time since Remote tab only exists when game is running
	# also clicks the Remote button if needed to populate the tree
	_find_remote_scene_tree()

	if not remote_scene_tree:
		_send_error(ws, id, -32000, "Remote scene tree not found (is game running?)")
		return

	# wait for tree to populate (may be empty immediately after clicking Remote)
	var root := remote_scene_tree.get_root()
	if not root or root.get_child_count() == 0:
		await get_tree().create_timer(0.15).timeout
		root = remote_scene_tree.get_root()

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
	_debug("=== _extract_inspector_properties ===")
	var properties: Array = []
	_collect_editor_properties(inspector, properties, 0)
	_debug("total properties extracted: %d" % properties.size())
	return properties


func _collect_editor_properties(node: Node, properties: Array, depth: int) -> void:
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
			_debug("  property: %s = '%s' (%s)" % [prop_name, prop_value, node_class])
			properties.append({"name": prop_name, "value": prop_value, "type": node_class})
		else:
			_debug("  skipped %s (no name extracted)" % node_class)

	# recurse into children
	for child in node.get_children():
		_collect_editor_properties(child, properties, depth + 1)


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
