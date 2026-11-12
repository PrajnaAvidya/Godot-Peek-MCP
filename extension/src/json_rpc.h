#pragma once

#include <string>
#include <vector>
#include <cstdint>

// pure JSON-RPC helpers (no godot dependency)
// used by message_handler and standalone tests

// build a JSON-RPC error response
std::string make_error(int64_t id, int code, const std::string& message);

// build a JSON-RPC success response wrapping a result JSON string
std::string make_result(int64_t id, const std::string& result_json);

// split a node path like "/root/Main/Player" into ["root", "Main", "Player"]
std::vector<std::string> split_node_path(const std::string& path);

// a single profiler tree row, normalized across godot versions.
// godot 4.4+ uses: Name | Time | Calls
// older builds used: Function | Time(%) | Self(s) | Total(s) | Calls
struct ProfilerRow {
    std::string function;
    std::string time_percent;
    std::string self_time;
    std::string total_time;
    std::string calls;
    std::vector<std::string> values;
};

// map raw profiler tree cell text into normalized fields.
// values[0] is always the function/category name.
ProfilerRow map_profiler_row(const std::vector<std::string>& values);

// extract a node type from an editor tree tooltip.
// godot 4.4+: "NodeName\nType: Node3D"
// fallback:    "NodeName (Node3D)"
std::string extract_type_from_tooltip(const std::string& tooltip);
