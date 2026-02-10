#include "godot_peek_plugin.h"
#include "socket_server.h"
#include "message_handler.h"
#include "editor_control_finder.h"
#include "debugger_plugin.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/editor_interface.hpp>

using namespace godot;

// socket path - hardcoded for now, could make configurable later
static const char* SOCKET_PATH = "/tmp/godot-peek.sock";

void GodotPeekPlugin::_bind_methods() {
    // bind methods/signals here later
}

GodotPeekPlugin::GodotPeekPlugin() {
    // create instances - they're not started yet
    socket_server = std::make_unique<SocketServer>();
    message_handler = std::make_unique<MessageHandler>();
    control_finder = std::make_unique<EditorControlFinder>();

    // create debugger plugin (Ref<> handles reference counting)
    debugger_plugin.instantiate();

    // wire up the control finder so message handler can find UI controls
    message_handler->set_control_finder(control_finder.get());

    // wire up the debugger plugin so message handler can control debugging
    message_handler->set_debugger_plugin(debugger_plugin.ptr());

    // set up callback for auto-stop scheduling
    message_handler->set_scene_launch_callback([this](double timeout) {
        if (timeout > 0.0) {
            auto_stop_timeout = timeout;
            auto_stop_active = true;
            UtilityFunctions::print("GodotPeekPlugin: auto-stop scheduled in ", timeout, "s");
        } else {
            auto_stop_active = false;
        }
    });
}

GodotPeekPlugin::~GodotPeekPlugin() {
    // unique_ptr handles cleanup, but we explicitly stop the server
    // to ensure socket file is removed
    if (socket_server) {
        socket_server->stop();
    }
}

void GodotPeekPlugin::_enter_tree() {
    UtilityFunctions::print("GodotPeekPlugin: starting socket server...");

    if (socket_server->start(SOCKET_PATH)) {
        UtilityFunctions::print("GodotPeekPlugin: listening on ", SOCKET_PATH);
    } else {
        UtilityFunctions::printerr("GodotPeekPlugin: failed to start socket server");
    }

    // register debugger plugin so we can control breakpoints and stepping
    if (debugger_plugin.is_valid()) {
        add_debugger_plugin(debugger_plugin);
        UtilityFunctions::print("GodotPeekPlugin: debugger plugin registered");
    }
}

void GodotPeekPlugin::_exit_tree() {
    UtilityFunctions::print("GodotPeekPlugin: stopping...");

    // unregister debugger plugin
    if (debugger_plugin.is_valid()) {
        remove_debugger_plugin(debugger_plugin);
    }

    socket_server->stop();
}

void GodotPeekPlugin::_process(double delta) {
    // check auto-stop timer
    if (auto_stop_active) {
        auto_stop_timeout -= delta;
        if (auto_stop_timeout <= 0.0) {
            auto_stop_active = false;
            EditorInterface* editor = EditorInterface::get_singleton();
            if (editor && editor->is_playing_scene()) {
                UtilityFunctions::print("GodotPeekPlugin: auto-stopping scene (timeout)");
                editor->stop_playing_scene();
            }
        }
    }

    // poll the socket for incoming messages each frame
    // the callback routes messages through our handler
    if (socket_server && socket_server->is_running()) {
        socket_server->poll([this](const std::string& message) -> std::string {
            return message_handler->handle(message);
        });
    }
}

GodotPeekDebuggerPlugin* GodotPeekPlugin::get_debugger_plugin() const {
    return debugger_plugin.ptr();
}
