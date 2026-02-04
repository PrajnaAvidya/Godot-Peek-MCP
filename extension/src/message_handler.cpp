#include "message_handler.h"
#include "editor_control_finder.h"
#include "debugger_plugin.h"

#include <nlohmann/json.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/rich_text_label.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/tree.hpp>
#include <godot_cpp/classes/tree_item.hpp>
#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/line_edit.hpp>
#include <godot_cpp/classes/check_box.hpp>
#include <godot_cpp/classes/button.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/packet_peer_udp.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// nlohmann::json lives in a versioned namespace, alias it for convenience
using json = nlohmann::json;
using namespace godot;

std::string MessageHandler::handle(const std::string& message) {
    // parse JSON without exceptions (godot-cpp disables exceptions)
    json request = json::parse(message, nullptr, false);

    // check if parsing failed - parse returns discarded value on error
    if (request.is_discarded()) {
        return R"({"id":null,"error":{"code":-32700,"message":"Parse error"}})";
    }

    // extract the request id
    int64_t id = 0;
    if (request.contains("id")) {
        if (request["id"].is_number_integer()) {
            id = request["id"].get<int64_t>();
        } else if (request["id"].is_number_float()) {
            id = static_cast<int64_t>(request["id"].get<double>());
        }
    }

    // extract the method name
    if (!request.contains("method") || !request["method"].is_string()) {
        return make_error(id, -32600, "Invalid request: missing method");
    }
    std::string method = request["method"].get<std::string>();

    // extract params as string (re-serialize for handlers to parse)
    // this avoids passing json objects across the header boundary
    std::string params_str = "{}";
    if (request.contains("params") && request["params"].is_object()) {
        params_str = request["params"].dump();
    }

    // route to the appropriate handler
    if (method == "ping") {
        return handle_ping(id);
    } else if (method == "run_main_scene") {
        return handle_run_main_scene(id, params_str);
    } else if (method == "run_scene") {
        return handle_run_scene(id, params_str);
    } else if (method == "run_current_scene") {
        return handle_run_current_scene(id, params_str);
    } else if (method == "stop_scene") {
        return handle_stop_scene(id);
    } else if (method == "get_output") {
        return handle_get_output(id, params_str);
    } else if (method == "get_debugger_errors") {
        return handle_get_debugger_errors(id);
    } else if (method == "get_monitors") {
        return handle_get_monitors(id);
    } else if (method == "get_debugger_stack_trace") {
        return handle_get_debugger_stack_trace(id);
    } else if (method == "get_debugger_locals") {
        return handle_get_debugger_locals(id);
    } else if (method == "get_remote_scene_tree") {
        return handle_get_remote_scene_tree(id);
    } else if (method == "get_remote_node_properties") {
        return handle_get_remote_node_properties(id, params_str);
    } else if (method == "set_breakpoint") {
        return handle_set_breakpoint(id, params_str);
    } else if (method == "clear_breakpoints") {
        return handle_clear_breakpoints(id);
    } else if (method == "get_debugger_state") {
        return handle_get_debugger_state(id);
    } else if (method == "debug_continue") {
        return handle_debug_continue(id);
    } else if (method == "debug_step") {
        return handle_debug_step(id, params_str);
    } else if (method == "debug_break") {
        return handle_debug_break(id);
    } else if (method == "get_screenshot") {
        return handle_get_screenshot(id, params_str);
    } else {
        return make_error(id, -32601, "Method not found: " + method);
    }
}

std::string MessageHandler::handle_ping(int64_t id) {
    return make_result(id, R"({"status":"ok"})");
}

std::string MessageHandler::handle_run_main_scene(int64_t id, const std::string& params_str) {
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    editor->play_main_scene();
    schedule_auto_stop(params_str);

    return make_result(id, R"({"success":true,"action":"run_main_scene"})");
}

std::string MessageHandler::handle_run_scene(int64_t id, const std::string& params_str) {
    // parse params to get scene_path
    json params = json::parse(params_str, nullptr, false);
    if (params.is_discarded()) {
        return make_error(id, -32602, "Invalid params");
    }

    if (!params.contains("scene_path") || !params["scene_path"].is_string()) {
        return make_error(id, -32602, "Missing required param: scene_path");
    }
    std::string scene_path = params["scene_path"].get<std::string>();

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    editor->play_custom_scene(String(scene_path.c_str()));
    schedule_auto_stop(params_str);

    // build result with scene_path included
    json result = {
        {"success", true},
        {"action", "run_scene"},
        {"scene_path", scene_path}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_run_current_scene(int64_t id, const std::string& params_str) {
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    editor->play_current_scene();
    schedule_auto_stop(params_str);

    return make_result(id, R"({"success":true,"action":"run_current_scene"})");
}

std::string MessageHandler::handle_stop_scene(int64_t id) {
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    editor->stop_playing_scene();

    return make_result(id, R"({"success":true,"action":"stop_scene"})");
}

void MessageHandler::schedule_auto_stop(const std::string& params_str) {
    if (!on_scene_launch) {
        return;
    }

    // parse params to extract timeout_seconds
    json params = json::parse(params_str, nullptr, false);
    double timeout = 0.0;

    if (!params.is_discarded() &&
        params.contains("timeout_seconds") &&
        params["timeout_seconds"].is_number()) {
        timeout = params["timeout_seconds"].get<double>();
    }

    on_scene_launch(timeout);
}

std::string MessageHandler::make_error(int64_t id, int code, const std::string& message) {
    json response = {
        {"id", id},
        {"error", {
            {"code", code},
            {"message", message}
        }}
    };
    return response.dump();
}

std::string MessageHandler::make_result(int64_t id, const std::string& result_json) {
    // parse the result JSON and wrap it in the response structure
    json result = json::parse(result_json, nullptr, false);
    if (result.is_discarded()) {
        result = json::object();
    }

    json response = {
        {"id", id},
        {"result", result}
    };
    return response.dump();
}

std::string MessageHandler::handle_get_output(int64_t id, const std::string& params_str) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    RichTextLabel* output = control_finder->get_output_panel();
    if (!output) {
        return make_error(id, -32000, "Output dock not found");
    }

    // parse params to get new_only and clear flags
    json params = json::parse(params_str, nullptr, false);
    bool new_only = false;
    bool clear = false;
    if (!params.is_discarded()) {
        if (params.contains("new_only") && params["new_only"].is_boolean()) {
            new_only = params["new_only"].get<bool>();
        }
        if (params.contains("clear") && params["clear"].is_boolean()) {
            clear = params["clear"].get<bool>();
        }
    }

    // get_parsed_text() returns visible text without BBCode formatting
    String full_text = output->get_parsed_text();
    int64_t full_length = full_text.length();

    String output_text;
    if (new_only) {
        // return only text added since last clear
        if (control_finder->last_output_length < full_length) {
            output_text = full_text.substr(control_finder->last_output_length);
        }
        // if last_output_length >= full_length, output_text stays empty
    } else {
        output_text = full_text;
    }

    if (clear) {
        // mark current position for future new_only calls
        control_finder->last_output_length = full_length;
    }

    // convert godot String to std::string for JSON
    std::string output_str = output_text.utf8().get_data();

    json result = {
        {"output", output_str},
        {"length", static_cast<int64_t>(output_text.length())},
        {"total_length", full_length}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_get_debugger_errors(int64_t id) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    Tree* tree = control_finder->get_errors_tree();
    if (!tree) {
        return make_error(id, -32000, "Debugger Errors tree not found");
    }

    std::string errors = get_tree_text(tree);

    json result = {
        {"errors", errors},
        {"length", static_cast<int64_t>(errors.length())}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::get_tree_text(Tree* tree) {
    TreeItem* root = tree->get_root();
    if (!root) {
        return "";
    }
    return get_tree_item_text(root, 0);
}

std::string MessageHandler::get_tree_item_text(TreeItem* item, int depth) {
    std::string result;
    std::string indent(depth * 2, ' ');  // 2 spaces per depth level

    // get text from all columns, join with " | "
    Tree* tree = item->get_tree();
    int col_count = tree->get_columns();
    std::string line;

    for (int col = 0; col < col_count; col++) {
        String text = item->get_text(col);
        if (text.length() > 0) {
            if (!line.empty()) {
                line += " | ";
            }
            line += text.utf8().get_data();
        }
    }

    if (!line.empty()) {
        result += indent + line + "\n";
    }

    // recurse into children
    TreeItem* child = item->get_first_child();
    while (child) {
        result += get_tree_item_text(child, depth + 1);
        child = child->get_next();
    }

    return result;
}

std::string MessageHandler::handle_get_monitors(int64_t id) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    Tree* tree = control_finder->get_monitors_tree();
    if (!tree) {
        return make_error(id, -32000, "Monitors tree not found");
    }

    TreeItem* root = tree->get_root();
    if (!root) {
        // empty tree - return empty monitors array
        json result = {
            {"monitors", json::array()},
            {"count", 0}
        };
        return make_result(id, result.dump());
    }

    // monitors tree structure: root -> groups (Time, Memory, etc) -> metrics
    // each metric has name in col 0, value in col 1
    json monitors = json::array();

    TreeItem* group = root->get_first_child();
    while (group) {
        String group_name_gd = group->get_text(0);
        std::string group_name = group_name_gd.utf8().get_data();

        json metrics = json::array();
        TreeItem* metric = group->get_first_child();
        while (metric) {
            String name_gd = metric->get_text(0);
            String value_gd = metric->get_text(1);
            metrics.push_back({
                {"name", std::string(name_gd.utf8().get_data())},
                {"value", std::string(value_gd.utf8().get_data())}
            });
            metric = metric->get_next();
        }

        monitors.push_back({
            {"group", group_name},
            {"metrics", metrics}
        });

        group = group->get_next();
    }

    json result = {
        {"monitors", monitors},
        {"count", static_cast<int64_t>(monitors.size())}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_get_debugger_stack_trace(int64_t id) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    // try to get error message from RichTextLabel (4.5/4.6) or Label (4.4)
    std::string error_msg;
    RichTextLabel* rtl = control_finder->get_stack_trace_label();
    if (rtl) {
        String text = rtl->get_parsed_text();
        error_msg = text.utf8().get_data();
    } else {
        Label* lbl = control_finder->get_stack_trace_label_44();
        if (lbl) {
            String text = lbl->get_text();
            error_msg = text.utf8().get_data();
        }
    }

    // get stack frames from tree
    std::string frames;
    Tree* tree = control_finder->get_stack_frames_tree();
    if (tree) {
        frames = get_tree_text(tree);
    }

    // require at least one control to be found
    if (error_msg.empty() && frames.empty()) {
        return make_error(id, -32000, "Stack trace not found (is debugger paused?)");
    }

    // combine error message and frames
    std::string combined;
    if (!error_msg.empty()) {
        combined += error_msg;
    }
    if (!frames.empty()) {
        if (!combined.empty()) {
            combined += "\n\nStack frames:\n";
        }
        combined += frames;
    }

    json result = {
        {"stack_trace", combined},
        {"length", static_cast<int64_t>(combined.length())}
    };
    return make_result(id, result.dump());
}

// helper: recursively find all descendants matching a class name
static std::vector<Node*> find_children_by_class(Node* root, const char* class_name) {
    std::vector<Node*> results;

    int child_count = root->get_child_count();
    for (int i = 0; i < child_count; i++) {
        Node* child = root->get_child(i);
        if (child->is_class(class_name)) {
            results.push_back(child);
        }
        // recurse into children
        auto nested = find_children_by_class(child, class_name);
        results.insert(results.end(), nested.begin(), nested.end());
    }

    return results;
}

// helper: extract value from an EditorProperty* node based on its type
static std::string extract_property_value(Node* node, const std::string& cls) {
    // EditorPropertyNil
    if (cls == "EditorPropertyNil") {
        return "null";
    }

    // EditorPropertyInteger, EditorPropertyFloat -> find EditorSpinSlider
    if (cls == "EditorPropertyInteger" || cls == "EditorPropertyFloat") {
        auto sliders = find_children_by_class(node, "EditorSpinSlider");
        if (!sliders.empty() && sliders[0]->has_method("get_value")) {
            Variant val = sliders[0]->call("get_value");
            return String(val).utf8().get_data();
        }
    }

    // EditorPropertyText -> find LineEdit
    if (cls == "EditorPropertyText") {
        auto edits = find_children_by_class(node, "LineEdit");
        if (!edits.empty()) {
            LineEdit* le = Object::cast_to<LineEdit>(edits[0]);
            if (le) {
                return le->get_text().utf8().get_data();
            }
        }
    }

    // EditorPropertyCheck -> find CheckBox
    if (cls == "EditorPropertyCheck") {
        auto boxes = find_children_by_class(node, "CheckBox");
        if (!boxes.empty()) {
            CheckBox* cb = Object::cast_to<CheckBox>(boxes[0]);
            if (cb) {
                return cb->is_pressed() ? "true" : "false";
            }
        }
    }

    // EditorPropertyVector2/3/4 -> find multiple EditorSpinSliders
    if (cls.find("EditorPropertyVector") == 0) {
        auto sliders = find_children_by_class(node, "EditorSpinSlider");
        if (!sliders.empty()) {
            std::string result = "(";
            for (size_t i = 0; i < sliders.size(); i++) {
                if (i > 0) result += ", ";
                if (sliders[i]->has_method("get_value")) {
                    Variant val = sliders[i]->call("get_value");
                    result += String(val).utf8().get_data();
                }
            }
            result += ")";
            return result;
        }
    }

    // EditorPropertyObjectID, EditorPropertyArray -> find Button text
    if (cls == "EditorPropertyObjectID" || cls == "EditorPropertyArray") {
        auto buttons = find_children_by_class(node, "Button");
        if (!buttons.empty()) {
            Button* btn = Object::cast_to<Button>(buttons[0]);
            if (btn) {
                return btn->get_text().utf8().get_data();
            }
        }
    }

    // fallback: try to find LineEdit, Label (with different text), or Button
    auto line_edits = find_children_by_class(node, "LineEdit");
    if (!line_edits.empty()) {
        LineEdit* le = Object::cast_to<LineEdit>(line_edits[0]);
        if (le) {
            return le->get_text().utf8().get_data();
        }
    }

    auto buttons = find_children_by_class(node, "Button");
    if (!buttons.empty()) {
        Button* btn = Object::cast_to<Button>(buttons[0]);
        if (btn) {
            return btn->get_text().utf8().get_data();
        }
    }

    return "";
}

// helper: recursively collect EditorProperty* nodes and extract name/value
static void collect_editor_properties(Node* node, json& properties) {
    String class_name = node->get_class();
    std::string cls = class_name.utf8().get_data();

    // check if this is an EditorProperty* subclass
    if (cls.rfind("EditorProperty", 0) == 0) {
        std::string prop_name;
        std::string prop_value;

        // try to get label via get_label() method (EditorProperty has this)
        if (node->has_method("get_label")) {
            String label = node->call("get_label");
            prop_name = label.utf8().get_data();
        }

        // fallback: look for Label child with property name
        if (prop_name.empty()) {
            auto labels = find_children_by_class(node, "Label");
            for (Node* lbl_node : labels) {
                Label* lbl = Object::cast_to<Label>(lbl_node);
                if (lbl) {
                    String text = lbl->get_text();
                    if (text.length() > 0) {
                        prop_name = text.utf8().get_data();
                        break;
                    }
                }
            }
        }

        // extract value based on type
        prop_value = extract_property_value(node, cls);

        if (!prop_name.empty()) {
            properties.push_back({
                {"name", prop_name},
                {"value", prop_value},
                {"type", cls}
            });
        }
    }

    // recurse into children
    int count = node->get_child_count();
    for (int i = 0; i < count; i++) {
        collect_editor_properties(node->get_child(i), properties);
    }
}

std::string MessageHandler::handle_get_debugger_locals(int64_t id) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    Control* inspector = control_finder->get_debugger_inspector();
    if (!inspector) {
        return make_error(id, -32000, "EditorDebuggerInspector not found (is debugger paused?)");
    }

    // extract properties from inspector
    // note: frame_index selection not implemented yet (would require async handling)
    json locals = json::array();
    collect_editor_properties(inspector, locals);

    json result = {
        {"locals", locals},
        {"count", static_cast<int64_t>(locals.size())},
        {"frame_index", -1}
    };
    return make_result(id, result.dump());
}

// helper: extract scene tree text with type info from tooltips
static std::string get_scene_tree_item_text(TreeItem* item, int depth) {
    std::string result;
    std::string indent(depth * 2, ' ');

    // get node name from column 0
    String node_name = item->get_text(0);
    if (node_name.length() > 0) {
        std::string name_str = node_name.utf8().get_data();

        // try to get node type from tooltip
        String tooltip = item->get_tooltip_text(0);
        std::string type_str;
        if (tooltip.length() > 0) {
            // tooltip often contains "NodeName (Type)" or type info
            std::string tt = tooltip.utf8().get_data();
            size_t paren_pos = tt.find('(');
            if (paren_pos != std::string::npos) {
                size_t end_paren = tt.find(')', paren_pos);
                if (end_paren != std::string::npos) {
                    type_str = tt.substr(paren_pos + 1, end_paren - paren_pos - 1);
                }
            }
        }

        // build output line: "  NodeName (Type)" or just "  NodeName"
        result += indent + name_str;
        if (!type_str.empty()) {
            result += " (" + type_str + ")";
        }
        result += "\n";
    }

    // recurse into children
    TreeItem* child = item->get_first_child();
    while (child) {
        result += get_scene_tree_item_text(child, depth + 1);
        child = child->get_next();
    }

    return result;
}

std::string MessageHandler::handle_get_remote_scene_tree(int64_t id) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    // try without clicking first
    Tree* tree = control_finder->get_remote_scene_tree(false);
    TreeItem* root = tree ? tree->get_root() : nullptr;
    bool has_content = root && root->get_child_count() > 0;

    // if empty, click Remote button
    // note: tree won't populate until next frame, caller should retry
    bool clicked_button = false;
    if (!has_content) {
        control_finder->get_remote_scene_tree(true);
        clicked_button = true;

        // re-check tree after click (might already have content if Remote was selected)
        tree = control_finder->get_remote_scene_tree(false);
        root = tree ? tree->get_root() : nullptr;
        has_content = root && root->get_child_count() > 0;
    }

    if (!tree) {
        return make_error(id, -32000, "Remote scene tree not found (is game running?)");
    }

    // if we clicked the button but tree is still empty, tell caller to retry
    if (!has_content && clicked_button) {
        json result = {
            {"tree", ""},
            {"length", 0},
            {"pending", true},
            {"message", "Remote button clicked, retry in ~100ms to get tree data"}
        };
        return make_result(id, result.dump());
    }

    if (!root || !has_content) {
        return make_error(id, -32000, "Remote scene tree is empty (is game running?)");
    }

    // extract tree with type info
    std::string tree_text = get_scene_tree_item_text(root, 0);

    json result = {
        {"tree", tree_text},
        {"length", static_cast<int64_t>(tree_text.length())},
        {"pending", false}
    };
    return make_result(id, result.dump());
}

// helper: split node path into parts (e.g., "/root/Main/Player" -> ["root", "Main", "Player"])
static std::vector<std::string> split_node_path(const std::string& path) {
    std::vector<std::string> parts;
    std::string clean = path;

    // trim leading slash
    if (!clean.empty() && clean[0] == '/') {
        clean = clean.substr(1);
    }

    // split by /
    size_t start = 0;
    size_t pos;
    while ((pos = clean.find('/', start)) != std::string::npos) {
        if (pos > start) {
            parts.push_back(clean.substr(start, pos - start));
        }
        start = pos + 1;
    }
    if (start < clean.length()) {
        parts.push_back(clean.substr(start));
    }

    return parts;
}

TreeItem* MessageHandler::find_tree_item_by_path(TreeItem* root, const std::vector<std::string>& path_parts) {
    if (path_parts.empty()) {
        return root;
    }

    TreeItem* current = root;
    size_t start_idx = 0;

    // if first part matches root's text, skip it
    String root_text = root->get_text(0);
    if (!path_parts.empty() && path_parts[0] == root_text.utf8().get_data()) {
        start_idx = 1;
    }

    // navigate through remaining parts
    for (size_t i = start_idx; i < path_parts.size(); i++) {
        bool found = false;
        TreeItem* child = current->get_first_child();
        while (child) {
            String child_text = child->get_text(0);
            if (path_parts[i] == child_text.utf8().get_data()) {
                current = child;
                found = true;
                break;
            }
            child = child->get_next();
        }
        if (!found) {
            return nullptr;
        }
    }

    return current;
}

bool MessageHandler::trigger_remote_inspection(Tree* tree, TreeItem* item) {
    // get object_id from metadata (column 0)
    Variant meta = item->get_metadata(0);
    if (meta.get_type() == Variant::NIL) {
        return false;
    }
    int64_t object_id = meta;

    // select the item in the tree
    tree->set_selected(item, 0);

    // emit signal to trigger inspection
    // 4.5/4.6 use "objects_selected" with PackedInt64Array
    // 4.4 uses "object_selected" with single int
    if (tree->has_signal("objects_selected")) {
        PackedInt64Array ids;
        ids.push_back(object_id);
        tree->emit_signal("objects_selected", ids, 0);
    } else if (tree->has_signal("object_selected")) {
        tree->emit_signal("object_selected", object_id, 0);
    } else {
        return false;
    }

    return true;
}

std::string MessageHandler::handle_get_remote_node_properties(int64_t id, const std::string& params_str) {
    if (!control_finder) {
        return make_error(id, -32000, "Control finder not initialized");
    }

    // parse node_path from params
    json params = json::parse(params_str, nullptr, false);
    if (params.is_discarded() || !params.contains("node_path") || !params["node_path"].is_string()) {
        return make_error(id, -32602, "Missing required param: node_path");
    }
    std::string node_path = params["node_path"].get<std::string>();

    // ensure remote tree exists (click Remote button if needed)
    Tree* tree = control_finder->get_remote_scene_tree(true);
    if (!tree) {
        return make_error(id, -32000, "Remote scene tree not found (is game running?)");
    }

    TreeItem* root = tree->get_root();
    if (!root || root->get_child_count() == 0) {
        // tree not populated yet - return pending
        json result = {
            {"node_path", node_path},
            {"properties", json::array()},
            {"count", 0},
            {"pending", true},
            {"message", "Remote tree populating, retry in ~200ms"}
        };
        return make_result(id, result.dump());
    }

    // find main inspector
    Control* inspector = control_finder->get_main_inspector();
    if (!inspector) {
        return make_error(id, -32000, "Main inspector not found");
    }

    // parse path and find target node
    auto path_parts = split_node_path(node_path);
    TreeItem* target = find_tree_item_by_path(root, path_parts);
    if (!target) {
        return make_error(id, -32000, "Node not found in remote tree: " + node_path);
    }

    // check if this node is already selected in the tree
    // if so, don't re-trigger (this allows retry to work)
    TreeItem* selected = tree->get_selected();
    bool already_selected = (selected == target);

    if (!already_selected) {
        // trigger inspection (select + emit signal)
        trigger_remote_inspection(tree, target);

        // return pending - caller should retry after delay
        json result = {
            {"node_path", node_path},
            {"properties", json::array()},
            {"count", 0},
            {"pending", true},
            {"message", "Inspection triggered, retry in ~300ms"}
        };
        return make_result(id, result.dump());
    }

    // node is already selected, inspector should be populated
    json props = json::array();
    collect_editor_properties(inspector, props);

    if (props.empty()) {
        // still no properties - maybe inspector not ready yet, try one more time
        json result = {
            {"node_path", node_path},
            {"properties", json::array()},
            {"count", 0},
            {"pending", true},
            {"message", "Inspector may still be loading, retry in ~300ms"}
        };
        return make_result(id, result.dump());
    }

    // have properties - return them
    json result = {
        {"node_path", node_path},
        {"properties", props},
        {"count", static_cast<int64_t>(props.size())},
        {"pending", false}
    };
    return make_result(id, result.dump());
}

// ============================================================================
// debugger control handlers
// ============================================================================

std::string MessageHandler::handle_set_breakpoint(int64_t id, const std::string& params_str) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    json params = json::parse(params_str, nullptr, false);
    if (params.is_discarded()) {
        return make_error(id, -32602, "Invalid params");
    }

    if (!params.contains("path") || !params["path"].is_string()) {
        return make_error(id, -32602, "Missing required param: path");
    }
    if (!params.contains("line") || !params["line"].is_number_integer()) {
        return make_error(id, -32602, "Missing required param: line");
    }

    std::string path = params["path"].get<std::string>();
    int line = params["line"].get<int>();
    bool enabled = params.value("enabled", true);

    debugger_plugin->set_breakpoint(String(path.c_str()), line, enabled);

    json result = {
        {"success", true},
        {"path", path},
        {"line", line},
        {"enabled", enabled}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_clear_breakpoints(int64_t id) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    debugger_plugin->clear_all_breakpoints();

    json result = {{"success", true}};
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_get_debugger_state(int64_t id) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    json result = {
        {"paused", debugger_plugin->is_paused()},
        {"active", debugger_plugin->is_session_active()},
        {"debuggable", debugger_plugin->is_debuggable()}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_debug_continue(int64_t id) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    debugger_plugin->continue_execution();

    json result = {{"success", true}};
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_debug_step(int64_t id, const std::string& params_str) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    json params = json::parse(params_str, nullptr, false);
    std::string mode = "over";  // default to step over
    if (!params.is_discarded() && params.contains("mode") && params["mode"].is_string()) {
        mode = params["mode"].get<std::string>();
    }

    if (mode == "into") {
        debugger_plugin->step_into();
    } else if (mode == "over") {
        debugger_plugin->step_over();
    } else if (mode == "out") {
        debugger_plugin->step_out();
    } else {
        return make_error(id, -32602, "Invalid mode: " + mode + " (expected: into, over, out)");
    }

    json result = {
        {"success", true},
        {"mode", mode}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::handle_debug_break(int64_t id) {
    if (!debugger_plugin) {
        return make_error(id, -32000, "Debugger plugin not initialized");
    }

    debugger_plugin->request_break();

    json result = {{"success", true}};
    return make_result(id, result.dump());
}

// ============================================================================
// screenshot handlers
// ============================================================================

std::string MessageHandler::handle_get_screenshot(int64_t id, const std::string& params_str) {
    json params = json::parse(params_str, nullptr, false);
    std::string target;

    if (!params.is_discarded() && params.contains("target") && params["target"].is_string()) {
        target = params["target"].get<std::string>();
    }

    if (target.empty()) {
        return make_error(id, -32602, "Missing required parameter: target");
    }

    if (target == "editor") {
        return capture_editor(id);
    } else if (target == "game") {
        return capture_game(id);
    } else {
        return make_error(id, -32602, "Invalid target: " + target + " (expected: editor, game)");
    }
}

std::string MessageHandler::capture_editor(int64_t id) {
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    SubViewport* vp_2d = editor->get_editor_viewport_2d();
    SubViewport* vp_3d = editor->get_editor_viewport_3d(0);

    Ref<Image> img_2d;
    Ref<Image> img_3d;
    const int MIN_SIZE = 10;

    // capture 2D viewport if available and large enough
    if (vp_2d) {
        Vector2i size = vp_2d->get_size();
        if (size.x > MIN_SIZE && size.y > MIN_SIZE) {
            Ref<ViewportTexture> tex = vp_2d->get_texture();
            if (tex.is_valid()) {
                img_2d = tex->get_image();
            }
        }
    }

    // capture 3D viewport if available and large enough
    if (vp_3d) {
        Vector2i size = vp_3d->get_size();
        if (size.x > MIN_SIZE && size.y > MIN_SIZE) {
            Ref<ViewportTexture> tex = vp_3d->get_texture();
            if (tex.is_valid()) {
                img_3d = tex->get_image();
            }
        }
    }

    Ref<Image> combined;
    int width = 0;
    int height = 0;

    if (img_2d.is_valid() && img_3d.is_valid()) {
        // combine side-by-side
        img_2d->convert(Image::FORMAT_RGBA8);
        img_3d->convert(Image::FORMAT_RGBA8);

        width = img_2d->get_width() + img_3d->get_width();
        height = MAX(img_2d->get_height(), img_3d->get_height());

        combined = Image::create(width, height, false, Image::FORMAT_RGBA8);
        combined->blit_rect(img_2d, Rect2i(Vector2i(), img_2d->get_size()), Vector2i());
        combined->blit_rect(img_3d, Rect2i(Vector2i(), img_3d->get_size()), Vector2i(img_2d->get_width(), 0));
    } else if (img_2d.is_valid()) {
        combined = img_2d;
        width = img_2d->get_width();
        height = img_2d->get_height();
    } else if (img_3d.is_valid()) {
        combined = img_3d;
        width = img_3d->get_width();
        height = img_3d->get_height();
    } else {
        return make_error(id, -32000, "No editor viewports available (both too small or empty)");
    }

    const char* path = "/tmp/godot_peek_editor_screenshot.png";
    Error err = combined->save_png(path);
    if (err != OK) {
        return make_error(id, -32000, "Failed to save screenshot");
    }

    json result = {
        {"path", path},
        {"target", "editor"},
        {"width", width},
        {"height", height}
    };
    return make_result(id, result.dump());
}

std::string MessageHandler::capture_game(int64_t id) {
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return make_error(id, -32000, "EditorInterface not available");
    }

    if (!editor->is_playing_scene()) {
        return make_error(id, -32000, "Game is not running");
    }

    // send UDP request to screenshot_listener in game
    Ref<PacketPeerUDP> udp;
    udp.instantiate();

    Error err = udp->set_dest_address("127.0.0.1", 6971);
    if (err != OK) {
        return make_error(id, -32000, "Failed to set UDP destination");
    }

    // send screenshot request
    json request = {{"cmd", "screenshot"}};
    std::string req_str = request.dump();

    PackedByteArray packet;
    packet.resize(req_str.size());
    memcpy(packet.ptrw(), req_str.c_str(), req_str.size());

    err = udp->put_packet(packet);
    if (err != OK) {
        return make_error(id, -32000, "Failed to send UDP request");
    }

    // poll for response with timeout (max ~1 second)
    // game should respond quickly since it just grabs viewport
    for (int attempt = 0; attempt < 20; attempt++) {
        OS::get_singleton()->delay_msec(50);  // 50ms delay

        if (udp->get_available_packet_count() > 0) {
            PackedByteArray response = udp->get_packet();
            std::string resp_str((const char*)response.ptr(), response.size());

            json resp = json::parse(resp_str, nullptr, false);
            if (resp.is_discarded()) {
                return make_error(id, -32000, "Invalid response from screenshot listener");
            }

            if (resp.contains("error")) {
                return make_error(id, -32000, "Screenshot listener error: " + resp["error"].get<std::string>());
            }

            json result = {
                {"path", resp.value("path", "/tmp/godot_peek_game_screenshot.png")},
                {"target", "game"},
                {"width", resp.value("width", 0)},
                {"height", resp.value("height", 0)}
            };
            return make_result(id, result.dump());
        }
    }

    return make_error(id, -32000, "Timeout waiting for game screenshot. Is screenshot_listener.gd added as autoload in your project?");
}
