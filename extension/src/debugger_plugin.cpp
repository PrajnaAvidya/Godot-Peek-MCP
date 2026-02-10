#include "debugger_plugin.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/script_editor.hpp>
#include <godot_cpp/classes/script_editor_base.hpp>
#include <godot_cpp/classes/code_edit.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/resource_loader.hpp>

using namespace godot;

void GodotPeekDebuggerPlugin::_bind_methods() {
    // bind methods here if needed for GDScript access
}

GodotPeekDebuggerPlugin::GodotPeekDebuggerPlugin() {
}

GodotPeekDebuggerPlugin::~GodotPeekDebuggerPlugin() {
}

void GodotPeekDebuggerPlugin::_setup_session(int32_t session_id) {
    // called when a debugger session starts (game is run with debugger attached)
    current_session_id = session_id;
    session_valid = true;

    Ref<EditorDebuggerSession> session = get_session(session_id);
    if (session.is_valid()) {
        apply_cached_breakpoints(session);
    }
}

bool GodotPeekDebuggerPlugin::_has_capture(const String& capture) const {
    // we don't capture any custom messages from the game side
    return capture == "godot_peek";
}

bool GodotPeekDebuggerPlugin::_capture(const String& message, const Array& data, int32_t session_id) {
    // handle messages from the game (if any)
    if (message.begins_with("godot_peek:")) {
        return true;
    }
    return false;
}

Ref<EditorDebuggerSession> GodotPeekDebuggerPlugin::get_current_session() {
    if (!session_valid) {
        return Ref<EditorDebuggerSession>();
    }
    return get_session(current_session_id);
}

void GodotPeekDebuggerPlugin::apply_cached_breakpoints(Ref<EditorDebuggerSession> session) {
    // re-apply cached breakpoints when session starts
    // note: this uses the session API which alone doesn't trigger breakpoints,
    // but the CodeEdit breakpoints are already set from when set_breakpoint was called
    for (const auto& bp : cached_breakpoints) {
        if (bp.enabled) {
            session->set_breakpoint(String(bp.path.c_str()), bp.line, bp.enabled);
        }
    }
}

void GodotPeekDebuggerPlugin::set_breakpoint(const String& path, int line, bool enabled) {
    std::string path_str = path.utf8().get_data();

    // update cache: remove existing entry for this path:line
    for (auto it = cached_breakpoints.begin(); it != cached_breakpoints.end(); ) {
        if (it->path == path_str && it->line == line) {
            it = cached_breakpoints.erase(it);
        } else {
            ++it;
        }
    }

    // add to cache if enabling
    if (enabled) {
        cached_breakpoints.push_back({path_str, line, enabled});
    }

    // set breakpoint via CodeEdit - this is what actually makes breakpoints work
    // EditorDebuggerSession::set_breakpoint alone doesn't trigger breaks
    EditorInterface* editor = EditorInterface::get_singleton();
    if (!editor) {
        UtilityFunctions::print("GodotPeek: set_breakpoint failed - EditorInterface not available");
        return;
    }

    Ref<Script> script = ResourceLoader::get_singleton()->load(path);
    if (!script.is_valid()) {
        UtilityFunctions::print("GodotPeek: set_breakpoint failed - could not load script: ", path);
        return;
    }

    // open script in editor (ensures it's the current tab)
    editor->edit_script(script, line, 0, false);

    ScriptEditor* script_editor = editor->get_script_editor();
    if (!script_editor) {
        UtilityFunctions::print("GodotPeek: set_breakpoint failed - ScriptEditor not available");
        return;
    }

    ScriptEditorBase* editor_base = script_editor->get_current_editor();
    if (!editor_base) {
        UtilityFunctions::print("GodotPeek: set_breakpoint failed - no current script editor");
        return;
    }

    Control* base_control = editor_base->get_base_editor();
    CodeEdit* code_edit = Object::cast_to<CodeEdit>(base_control);
    if (!code_edit) {
        UtilityFunctions::print("GodotPeek: set_breakpoint failed - editor is not CodeEdit (external editor?)");
        return;
    }

    // CodeEdit uses 0-indexed lines
    code_edit->set_line_as_breakpoint(line - 1, enabled);
}

void GodotPeekDebuggerPlugin::clear_all_breakpoints() {
    // clear all cached breakpoints via CodeEdit
    for (const auto& bp : cached_breakpoints) {
        set_breakpoint(String(bp.path.c_str()), bp.line, false);
    }
    cached_breakpoints.clear();
}

bool GodotPeekDebuggerPlugin::is_paused() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        return session->is_breaked();
    }
    return false;
}

bool GodotPeekDebuggerPlugin::is_session_active() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        return session->is_active();
    }
    return false;
}

bool GodotPeekDebuggerPlugin::is_debuggable() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        return session->is_debuggable();
    }
    return false;
}

void GodotPeekDebuggerPlugin::step_into() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        Array args;
        session->send_message("step", args);
    }
}

void GodotPeekDebuggerPlugin::step_over() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        Array args;
        session->send_message("next", args);
    }
}

void GodotPeekDebuggerPlugin::step_out() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        Array args;
        session->send_message("out", args);
    }
}

void GodotPeekDebuggerPlugin::continue_execution() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        Array args;
        session->send_message("continue", args);
    }
}

void GodotPeekDebuggerPlugin::request_break() {
    Ref<EditorDebuggerSession> session = get_current_session();
    if (session.is_valid()) {
        Array args;
        session->send_message("break", args);
    }
}
