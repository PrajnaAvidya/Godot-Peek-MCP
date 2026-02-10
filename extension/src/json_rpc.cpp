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
