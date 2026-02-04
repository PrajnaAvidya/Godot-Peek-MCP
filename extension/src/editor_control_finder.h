#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/rich_text_label.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/tree.hpp>
#include <vector>

// helper class to find and cache editor UI controls
// traverses EditorInterface::get_base_control() to locate specific controls
// by matching node paths (version-aware for godot 4.4/4.5/4.6)
class EditorControlFinder {
public:
    // find the Output panel RichTextLabel (lazy cached)
    godot::RichTextLabel* get_output_panel();

    // find the Debugger Errors tree (lazy cached)
    godot::Tree* get_errors_tree();

    // find the Monitors tree (lazy cached)
    godot::Tree* get_monitors_tree();

    // find stack trace controls (lazy cached)
    // 4.5/4.6 use RichTextLabel, 4.4 uses Label inside HBoxContainer
    godot::RichTextLabel* get_stack_trace_label();
    godot::Label* get_stack_trace_label_44();
    godot::Tree* get_stack_frames_tree();

    // find debugger inspector for locals (lazy cached)
    godot::Control* get_debugger_inspector();

    // find main inspector in Inspector dock (lazy cached)
    godot::Control* get_main_inspector();

    // find remote scene tree (EditorDebuggerTree) - NOT cached since it may change
    // optionally clicks the Remote button if not already selected
    godot::Tree* get_remote_scene_tree(bool click_remote_button = false);

    // clear cached references (call if editor UI changes)
    void invalidate_cache();

    // track last_output_length for new_only feature
    // public so MessageHandler can access it
    int64_t last_output_length = 0;

private:
    // collect all descendants of a given class
    std::vector<godot::Node*> find_all_by_class(
        godot::Node* root,
        const char* class_name
    );

    // cached references (raw pointers - we don't own these nodes)
    godot::RichTextLabel* output_panel = nullptr;
    godot::Tree* errors_tree = nullptr;
    godot::Tree* monitors_tree = nullptr;
    godot::RichTextLabel* stack_trace_label = nullptr;
    godot::Label* stack_trace_label_44 = nullptr;
    godot::Tree* stack_frames_tree = nullptr;
    godot::Control* debugger_inspector = nullptr;
    godot::Control* main_inspector = nullptr;
};
