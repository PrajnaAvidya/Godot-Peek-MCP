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
