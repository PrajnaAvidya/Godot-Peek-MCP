#include "editor_control_finder.h"

#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/button.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

RichTextLabel* EditorControlFinder::get_output_panel() {
    // return cached if still alive (CachedRef checks ObjectDB)
    RichTextLabel* cached = output_panel.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    // find all RichTextLabel nodes in the editor UI
    auto labels = find_all_by_class(base, "RichTextLabel");

    // look for the Output panel by path pattern
    // godot 4.4/4.5: path contains "EditorLog"
    // godot 4.6: path contains "EditorBottomPanel" and "/Output/"
    for (Node* node : labels) {
        String path = node->get_path();
        if (path.contains("EditorLog") ||
            (path.contains("EditorBottomPanel") && path.contains("/Output/"))) {
            output_panel.set(Object::cast_to<RichTextLabel>(node));
            UtilityFunctions::print("EditorControlFinder: found output panel at ", path);
            break;
        }
    }

    return output_panel.get();
}

Tree* EditorControlFinder::get_errors_tree() {
    Tree* cached = errors_tree.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    // find all Tree nodes in the editor UI
    auto trees = find_all_by_class(base, "Tree");

    // look for the debugger errors tree by path pattern
    // godot 4.4/4.5: path contains "EditorDebuggerNode"
    // godot 4.6: path contains "/Debugger/"
    // AND in both cases it must contain "/Errors"
    for (Node* node : trees) {
        String path = node->get_path();
        bool is_debugger = path.contains("EditorDebuggerNode") ||
                           path.contains("/Debugger/");
        bool is_errors = path.contains("/Errors");

        if (is_debugger && is_errors) {
            errors_tree.set(Object::cast_to<Tree>(node));
            UtilityFunctions::print("EditorControlFinder: found errors tree at ", path);
            break;
        }
    }

    return errors_tree.get();
}

Tree* EditorControlFinder::get_monitors_tree() {
    Tree* cached = monitors_tree.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    auto trees = find_all_by_class(base, "Tree");

    // monitors tree path contains "/Monitors" and is inside debugger
    for (Node* node : trees) {
        String path = node->get_path();
        bool is_debugger = path.contains("EditorDebuggerNode") ||
                           path.contains("/Debugger/");
        bool is_monitors = path.contains("/Monitors");

        if (is_debugger && is_monitors) {
            monitors_tree.set(Object::cast_to<Tree>(node));
            UtilityFunctions::print("EditorControlFinder: found monitors tree at ", path);
            break;
        }
    }

    return monitors_tree.get();
}

RichTextLabel* EditorControlFinder::get_stack_trace_label() {
    RichTextLabel* cached = stack_trace_label.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    auto labels = find_all_by_class(base, "RichTextLabel");

    // stack trace RichTextLabel (4.5/4.6) contains "/Stack Trace/" in path
    for (Node* node : labels) {
        String path = node->get_path();
        if (path.contains("/Stack Trace/")) {
            stack_trace_label.set(Object::cast_to<RichTextLabel>(node));
            UtilityFunctions::print("EditorControlFinder: found stack trace label at ", path);
            break;
        }
    }

    return stack_trace_label.get();
}

Label* EditorControlFinder::get_stack_trace_label_44() {
    Label* cached = stack_trace_label_44.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    auto labels = find_all_by_class(base, "Label");

    // 4.4 stack trace Label is inside @HBoxContainer with /Stack Trace/ path
    for (Node* node : labels) {
        String path = node->get_path();
        if (path.contains("/Stack Trace/") && path.contains("@HBoxContainer")) {
            stack_trace_label_44.set(Object::cast_to<Label>(node));
            UtilityFunctions::print("EditorControlFinder: found stack trace label (4.4) at ", path);
            break;
        }
    }

    return stack_trace_label_44.get();
}

Tree* EditorControlFinder::get_stack_frames_tree() {
    Tree* cached = stack_frames_tree.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    auto trees = find_all_by_class(base, "Tree");

    // stack frames tree is inside /Stack Trace/ panel
    for (Node* node : trees) {
        String path = node->get_path();
        if (path.contains("/Stack Trace/")) {
            stack_frames_tree.set(Object::cast_to<Tree>(node));
            UtilityFunctions::print("EditorControlFinder: found stack frames tree at ", path);
            break;
        }
    }

    return stack_frames_tree.get();
}

Control* EditorControlFinder::get_debugger_inspector() {
    Control* cached = debugger_inspector.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    // find EditorDebuggerInspector by exact class name
    // this control displays local variables when debugger is paused
    auto nodes = find_all_by_class(base, "EditorDebuggerInspector");
    if (!nodes.empty()) {
        debugger_inspector.set(Object::cast_to<Control>(nodes[0]));
        UtilityFunctions::print("EditorControlFinder: found debugger inspector at ", nodes[0]->get_path());
    }

    return debugger_inspector.get();
}

Control* EditorControlFinder::get_main_inspector() {
    Control* cached = main_inspector.get();
    if (cached) {
        return cached;
    }

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    // find EditorInspector in the Inspector dock
    // path contains "DockSlotRightUL/Inspector/" or similar dock pattern
    auto inspectors = find_all_by_class(base, "EditorInspector");
    for (Node* node : inspectors) {
        String path = node->get_path();
        // main inspector is in the right dock slot
        if (path.contains("DockSlotRightUL/Inspector/") ||
            path.contains("DockSlotRightBL/Inspector/")) {
            main_inspector.set(Object::cast_to<Control>(node));
            UtilityFunctions::print("EditorControlFinder: found main inspector at ", path);
            break;
        }
    }

    return main_inspector.get();
}

Tree* EditorControlFinder::get_remote_scene_tree(bool click_remote_button) {
    // NOT cached - the tree may come/go based on game state
    // find fresh each time like GDScript does

    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        return nullptr;
    }

    Control* base = editor->get_base_control();
    if (!base) {
        return nullptr;
    }

    // optionally click the Remote button to populate the tree
    if (click_remote_button) {
        auto buttons = find_all_by_class(base, "Button");
        for (Node* node : buttons) {
            String path = node->get_path();
            // Remote button is in Scene dock
            if (path.contains("/Scene/")) {
                Button* btn = Object::cast_to<Button>(node);
                if (btn && btn->get_text() == "Remote") {
                    if (!btn->is_pressed()) {
                        UtilityFunctions::print("EditorControlFinder: clicking Remote button");
                        btn->set_pressed(true);
                        btn->emit_signal("pressed");
                    }
                    break;
                }
            }
        }
    }

    // EditorDebuggerTree is the remote scene tree (inherits from Tree)
    auto nodes = find_all_by_class(base, "EditorDebuggerTree");
    if (!nodes.empty()) {
        Tree* tree = Object::cast_to<Tree>(nodes[0]);
        UtilityFunctions::print("EditorControlFinder: found remote scene tree at ", nodes[0]->get_path());
        return tree;
    }

    return nullptr;
}

void EditorControlFinder::invalidate_cache() {
    output_panel.clear();
    errors_tree.clear();
    monitors_tree.clear();
    stack_trace_label.clear();
    stack_trace_label_44.clear();
    stack_frames_tree.clear();
    debugger_inspector.clear();
    main_inspector.clear();
    // note: don't reset last_output_length - that tracks user's read position
}

std::vector<Node*> EditorControlFinder::find_all_by_class(Node* root, const char* class_name) {
    std::vector<Node*> results;

    // is_class() checks if node is exactly that class or inherits from it
    if (root->is_class(class_name)) {
        results.push_back(root);
    }

    // recurse into children
    int child_count = root->get_child_count();
    for (int i = 0; i < child_count; i++) {
        Node* child = root->get_child(i);
        auto child_results = find_all_by_class(child, class_name);
        results.insert(results.end(), child_results.begin(), child_results.end());
    }

    return results;
}
