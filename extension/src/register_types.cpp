#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/editor_plugin_registration.hpp>

#include "godot_peek_plugin.h"
#include "debugger_plugin.h"

using namespace godot;

void initialize_godot_peek_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_EDITOR) {
        return;
    }

    // register debugger plugin first (it's used by GodotPeekPlugin)
    GDREGISTER_CLASS(GodotPeekDebuggerPlugin);
    GDREGISTER_CLASS(GodotPeekPlugin);
    EditorPlugins::add_by_type<GodotPeekPlugin>();
}

void uninitialize_godot_peek_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_EDITOR) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT godot_peek_library_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization
) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_godot_peek_module);
    init_obj.register_terminator(uninitialize_godot_peek_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_EDITOR);

    return init_obj.init();
}
}
