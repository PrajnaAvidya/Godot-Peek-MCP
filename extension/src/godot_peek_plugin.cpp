#include "godot_peek_plugin.h"
#include "socket_server.h"
#include "message_handler.h"
#include "editor_control_finder.h"
#include "debugger_plugin.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>

#include <cstdio>   // fopen, fprintf
#include <ctime>    // time, localtime, strftime
#include <unistd.h> // access, getpid

using namespace godot;

// socket path - hardcoded for now, could make configurable later
static const char* SOCKET_PATH = "/tmp/godot-peek.sock";
static const char* DEBUG_LOG = "/tmp/godot-peek-debug.log";

// append a timestamped line to the debug log
static void debug_log(const char* msg) {
    FILE* f = fopen(DEBUG_LOG, "a");
    if (!f) return;
    time_t now = time(nullptr);
    struct tm* t = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%H:%M:%S", t);
    fprintf(f, "[%s pid=%d] %s\n", ts, getpid(), msg);
    fclose(f);
}

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
    debug_log("~GodotPeekPlugin destructor called");
    // only stop the server if it's actually running (editor process).
    // game child processes never start() so stop() would be a no-op,
    // but guard anyway to be safe against unlink()ing the editor's socket.
    if (socket_server && socket_server->is_running()) {
        socket_server->stop();
    }
}

void GodotPeekPlugin::_enter_tree() {
    debug_log("_enter_tree called");

    // only start the socket server in the editor process, not in game child processes.
    // the gdextension can load in game processes too, and if we start() there it will
    // unlink() the editor's socket file, killing all MCP connections.
    if (!Engine::get_singleton()->is_editor_hint()) {
        debug_log("_enter_tree: NOT editor, skipping socket server");
        return;
    }

    UtilityFunctions::print("GodotPeekPlugin: starting socket server...");

    if (socket_server->start(SOCKET_PATH)) {
        debug_log("socket server started OK");
        UtilityFunctions::print("GodotPeekPlugin: listening on ", SOCKET_PATH);
    } else {
        debug_log("socket server FAILED to start");
        UtilityFunctions::printerr("GodotPeekPlugin: failed to start socket server");
    }

    // register debugger plugin so we can control breakpoints and stepping
    if (debugger_plugin.is_valid()) {
        add_debugger_plugin(debugger_plugin);
        UtilityFunctions::print("GodotPeekPlugin: debugger plugin registered");
    }
}

void GodotPeekPlugin::_exit_tree() {
    debug_log("_exit_tree called");

    if (!Engine::get_singleton()->is_editor_hint()) {
        debug_log("_exit_tree: NOT editor, skipping");
        return;
    }

    UtilityFunctions::print("GodotPeekPlugin: stopping...");

    // unregister debugger plugin
    if (debugger_plugin.is_valid()) {
        remove_debugger_plugin(debugger_plugin);
    }

    socket_server->stop();
    debug_log("_exit_tree done, socket stopped");
}

void GodotPeekPlugin::_process(double delta) {
    // diagnostic heartbeat: log every 30s so we can tell if _process stops
    heartbeat_timer += delta;
    if (heartbeat_timer >= 30.0) {
        heartbeat_timer = 0.0;
        bool running = socket_server && socket_server->is_running();
        bool sock_exists = (access(SOCKET_PATH, F_OK) == 0);
        char msg[256];
        snprintf(msg, sizeof(msg), "heartbeat: socket_running=%d sock_file_exists=%d", running, sock_exists);
        debug_log(msg);
    }

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
