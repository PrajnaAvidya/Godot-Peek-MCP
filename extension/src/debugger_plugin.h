#pragma once

#include <godot_cpp/classes/editor_debugger_plugin.hpp>
#include <godot_cpp/classes/editor_debugger_session.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <vector>
#include <string>

namespace godot {

// cached breakpoint info for applying when session becomes available
struct CachedBreakpoint {
    std::string path;
    int line;
    bool enabled;
};

// debugger plugin that provides control over the running game's debugger
// allows setting breakpoints, stepping, continue/pause from MCP
class GodotPeekDebuggerPlugin : public EditorDebuggerPlugin {
    GDCLASS(GodotPeekDebuggerPlugin, EditorDebuggerPlugin)

protected:
    static void _bind_methods();

public:
    GodotPeekDebuggerPlugin();
    ~GodotPeekDebuggerPlugin();

    // virtual overrides from EditorDebuggerPlugin
    void _setup_session(int32_t session_id) override;
    bool _has_capture(const String& capture) const override;
    bool _capture(const String& message, const Array& data, int32_t session_id) override;

    // breakpoint control
    void set_breakpoint(const String& path, int line, bool enabled);
    void clear_all_breakpoints();

    // debugger state queries (not const because get_session isn't const in base class)
    bool is_paused();
    bool is_session_active();
    bool is_debuggable();

    // execution control
    void step_into();
    void step_over();
    void step_out();
    void continue_execution();
    void request_break();

private:
    // track the current active session
    int32_t current_session_id = 0;
    bool session_valid = false;

    // cache breakpoints set before session is available
    // applied when _setup_session is called
    std::vector<CachedBreakpoint> cached_breakpoints;

    // helper to get current session ref (not const because base get_session isn't const)
    Ref<EditorDebuggerSession> get_current_session();

    // apply cached breakpoints to a session
    void apply_cached_breakpoints(Ref<EditorDebuggerSession> session);
};

}
