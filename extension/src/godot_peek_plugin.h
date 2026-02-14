#pragma once

#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <memory>  // for std::unique_ptr
#include <string>

// forward declarations to avoid including full headers
class SocketServer;
class MessageHandler;
class EditorControlFinder;

namespace godot {
class GodotPeekDebuggerPlugin;
}

namespace godot {

class GodotPeekPlugin : public EditorPlugin {
    GDCLASS(GodotPeekPlugin, EditorPlugin)

protected:
    static void _bind_methods();

public:
    GodotPeekPlugin();
    ~GodotPeekPlugin();

    void _enter_tree() override;
    void _exit_tree() override;
    void _process(double delta) override;  // called each frame to poll socket

    // getter for debugger plugin (used by message handler)
    GodotPeekDebuggerPlugin* get_debugger_plugin() const;

private:
    // unique_ptr handles cleanup automatically
    // we use pointers + forward declarations to keep the header lightweight
    std::unique_ptr<SocketServer> socket_server;
    std::unique_ptr<MessageHandler> message_handler;
    std::unique_ptr<EditorControlFinder> control_finder;

    // debugger plugin is a Ref<> because EditorDebuggerPlugin inherits RefCounted
    Ref<GodotPeekDebuggerPlugin> debugger_plugin;

    // auto-stop timer state
    double auto_stop_timeout = 0.0;   // seconds remaining, 0 = disabled
    bool auto_stop_active = false;

    // project-specific socket path (computed at enter_tree)
    std::string socket_path;
};

}
