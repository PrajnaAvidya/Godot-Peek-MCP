#include "godot_peek_plugin.h"
#include "socket_server.h"
#include "message_handler.h"
#include "editor_control_finder.h"
#include "debugger_plugin.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/project_settings.hpp>

#include <string>

using namespace godot;

// derive a project-specific socket path from the godot project directory name.
// eg project at /home/user/Code/my-game -> /tmp/godot-peek-my-game.sock
// sanitizes to lowercase alphanumeric + dash to avoid path issues.
static std::string get_project_socket_path() {
    ProjectSettings* ps = ProjectSettings::get_singleton();
    if (!ps) {
        return "/tmp/godot-peek.sock";
    }

    // globalize_path resolves res:// to the actual filesystem path
    String project_path = ps->globalize_path("res://");
    std::string path = project_path.utf8().get_data();

    // strip trailing slash(es)
    while (!path.empty() && path.back() == '/') {
        path.pop_back();
    }

    // extract directory name (last component)
    size_t last_sep = path.rfind('/');
    std::string dirname = (last_sep != std::string::npos) ? path.substr(last_sep + 1) : path;

    if (dirname.empty()) {
        return "/tmp/godot-peek.sock";
    }

    // sanitize: lowercase, replace non-alphanumeric with dash
    std::string sanitized;
    for (char c : dirname) {
        if (std::isalnum(static_cast<unsigned char>(c))) {
            sanitized += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        } else if (!sanitized.empty() && sanitized.back() != '-') {
            sanitized += '-';
        }
    }
    // trim trailing dash
    while (!sanitized.empty() && sanitized.back() == '-') {
        sanitized.pop_back();
    }

    if (sanitized.empty()) {
        return "/tmp/godot-peek.sock";
    }

    return "/tmp/godot-peek-" + sanitized + ".sock";
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
    // only stop if we actually own the socket (is_running checks owns_socket internally)
    if (socket_server && socket_server->is_running()) {
        socket_server->stop();
    }
}

void GodotPeekPlugin::_enter_tree() {
    socket_path = get_project_socket_path();

    UtilityFunctions::print("GodotPeekPlugin: starting socket server...");

    // start() probes the existing socket first - if another instance (eg the
    // editor process when we're a game child process) is already listening,
    // it returns false without touching the socket file.
    if (socket_server->start(socket_path)) {
        UtilityFunctions::print("GodotPeekPlugin: listening on ", socket_path.c_str());
    } else {
        UtilityFunctions::print("GodotPeekPlugin: socket server not started (another instance owns ", socket_path.c_str(), ")");
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

    // stop() only unlinks the socket file if we own it (owns_socket flag)
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
