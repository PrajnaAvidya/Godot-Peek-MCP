#include "json_rpc.h"
#include <nlohmann/json.hpp>

using json = nlohmann::json;

std::string make_error(int64_t id, int code, const std::string& message) {
    json response = {
        {"id", id},
        {"error", {
            {"code", code},
            {"message", message}
        }}
    };
    return response.dump();
}

std::string make_result(int64_t id, const std::string& result_json) {
    // parse the result JSON and wrap it in the response structure
    json result = json::parse(result_json, nullptr, false);
    if (result.is_discarded()) {
        result = json::object();
    }

    json response = {
        {"id", id},
        {"result", result}
    };
    return response.dump();
}

static std::string trim_copy(const std::string& value) {
    size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1);
}

ProfilerRow map_profiler_row(const std::vector<std::string>& values) {
    ProfilerRow row;
    row.values = values;

    if (values.empty()) {
        return row;
    }

    row.function = values[0];

    if (values.size() >= 5) {
        // legacy 5-column layout
        row.time_percent = values[1];
        row.self_time = values[2];
        row.total_time = values[3];
        row.calls = values[4];
    } else if (values.size() >= 3) {
        // godot 4.4+ layout: Name | Time | Calls
        // Time reflects the selected Inclusive/Self scope.
        row.self_time = values[1];
        row.calls = values[2];
    } else if (values.size() == 2) {
        row.self_time = values[1];
    }

    return row;
}

std::string extract_type_from_tooltip(const std::string& tooltip) {
    // godot 4.4+ tooltip format: "NodeName\nType: Node3D"
    const std::string type_marker = "Type: ";
    size_t type_pos = tooltip.find(type_marker);
    if (type_pos != std::string::npos) {
        size_t start = type_pos + type_marker.size();
        size_t end = tooltip.find('\n', start);
        std::string type = trim_copy(tooltip.substr(start, end == std::string::npos ? std::string::npos : end - start));
        if (!type.empty()) {
            return type;
        }
    }

    // fallback for older/custom tooltips: "NodeName (Node3D)"
    size_t open = tooltip.find('(');
    if (open != std::string::npos) {
        size_t close = tooltip.find(')', open + 1);
        if (close != std::string::npos) {
            return trim_copy(tooltip.substr(open + 1, close - open - 1));
        }
    }

    return "";
}

std::vector<std::string> split_node_path(const std::string& path) {
    std::vector<std::string> parts;
    std::string clean = path;

    // trim leading slash
    if (!clean.empty() && clean[0] == '/') {
        clean = clean.substr(1);
    }

    // split by /
    size_t start = 0;
    size_t pos;
    while ((pos = clean.find('/', start)) != std::string::npos) {
        if (pos > start) {
            parts.push_back(clean.substr(start, pos - start));
        }
        start = pos + 1;
    }
    if (start < clean.length()) {
        parts.push_back(clean.substr(start));
    }

    return parts;
}
