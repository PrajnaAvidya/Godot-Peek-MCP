#pragma once

#include <string>
#include <functional>
#include <vector>

// forward declarations
class EditorControlFinder;
namespace godot {
    class Node;
    class Tree;
    class TreeItem;
    class GodotPeekDebuggerPlugin;
}

// callback for scene launch events (used by plugin for auto-stop timer)
using SceneLaunchCallback = std::function<void(double timeout_seconds)>;

class MessageHandler {
public:
    // process a JSON-RPC message and return the response
    // input: {"id": 1, "method": "ping", "params": {...}}
    // output: {"id": 1, "result": {...}} or {"id": 1, "error": {...}}
    std::string handle(const std::string& message);

    // set callback for scene launch (to schedule auto-stop)
    void set_scene_launch_callback(SceneLaunchCallback cb) { on_scene_launch = cb; }

    // set the control finder (injected by plugin)
    void set_control_finder(EditorControlFinder* finder) { control_finder = finder; }

    // set the debugger plugin (injected by plugin)
    void set_debugger_plugin(godot::GodotPeekDebuggerPlugin* plugin) { debugger_plugin = plugin; }

private:
    // individual method handlers
    std::string handle_ping(int64_t id);
    std::string handle_run_main_scene(int64_t id, const std::string& params_str);
    std::string handle_run_scene(int64_t id, const std::string& params_str);
    std::string handle_run_current_scene(int64_t id, const std::string& params_str);
    std::string handle_stop_scene(int64_t id);
    std::string handle_get_output(int64_t id, const std::string& params_str);
    std::string handle_get_debugger_errors(int64_t id);
    std::string handle_get_monitors(int64_t id);
    std::string handle_get_debugger_stack_trace(int64_t id);
    std::string handle_get_debugger_locals(int64_t id);
    std::string handle_get_remote_scene_tree(int64_t id);
    std::string handle_get_remote_node_properties(int64_t id, const std::string& params_str);

    // debugger control handlers
    std::string handle_set_breakpoint(int64_t id, const std::string& params_str);
    std::string handle_clear_breakpoints(int64_t id);
    std::string handle_get_debugger_state(int64_t id);
    std::string handle_debug_continue(int64_t id);
    std::string handle_debug_step(int64_t id, const std::string& params_str);
    std::string handle_debug_break(int64_t id);

    // screenshot handlers
    std::string handle_get_screenshot(int64_t id, const std::string& params_str);
    std::string capture_editor(int64_t id);
    std::string capture_game(int64_t id);

    // helper to build error response
    std::string make_error(int64_t id, int code, const std::string& message);

    // helper to build success response
    std::string make_result(int64_t id, const std::string& result_json);

    // extract timeout and trigger callback
    void schedule_auto_stop(const std::string& params_str);

    // helper to extract text from a Tree widget (recursive traversal)
    std::string get_tree_text(godot::Tree* tree);
    std::string get_tree_item_text(godot::TreeItem* item, int depth);

    // helpers for remote node inspection
    godot::TreeItem* find_tree_item_by_path(godot::TreeItem* root, const std::vector<std::string>& path_parts);
    bool trigger_remote_inspection(godot::Tree* tree, godot::TreeItem* item);

    SceneLaunchCallback on_scene_launch;
    EditorControlFinder* control_finder = nullptr;
    godot::GodotPeekDebuggerPlugin* debugger_plugin = nullptr;
};
