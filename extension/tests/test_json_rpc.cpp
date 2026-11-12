#include <doctest/doctest.h>
#include "json_rpc.h"
#include <nlohmann/json.hpp>

using json = nlohmann::json;

// --- make_error ---

TEST_CASE("make_error produces valid JSON-RPC error") {
    std::string result = make_error(42, -32600, "Invalid request");
    json parsed = json::parse(result);

    CHECK(parsed["id"] == 42);
    CHECK(parsed.contains("error"));
    CHECK(parsed["error"]["code"] == -32600);
    CHECK(parsed["error"]["message"] == "Invalid request");
    CHECK_FALSE(parsed.contains("result"));
}

TEST_CASE("make_error with zero id") {
    std::string result = make_error(0, -1, "fail");
    json parsed = json::parse(result);

    CHECK(parsed["id"] == 0);
    CHECK(parsed["error"]["code"] == -1);
}

// --- make_result ---

TEST_CASE("make_result wraps valid JSON") {
    std::string result = make_result(7, R"({"success":true,"action":"ping"})");
    json parsed = json::parse(result);

    CHECK(parsed["id"] == 7);
    CHECK(parsed.contains("result"));
    CHECK(parsed["result"]["success"] == true);
    CHECK(parsed["result"]["action"] == "ping");
    CHECK_FALSE(parsed.contains("error"));
}

TEST_CASE("make_result with nested JSON") {
    std::string inner = R"({"data":{"items":[1,2,3]}})";
    std::string result = make_result(1, inner);
    json parsed = json::parse(result);

    CHECK(parsed["result"]["data"]["items"].size() == 3);
    CHECK(parsed["result"]["data"]["items"][0] == 1);
}

TEST_CASE("make_result with invalid JSON falls back to empty object") {
    std::string result = make_result(5, "not valid json");
    json parsed = json::parse(result);

    CHECK(parsed["id"] == 5);
    // should fall back to empty object
    CHECK(parsed["result"].is_object());
    CHECK(parsed["result"].empty());
}

// --- split_node_path ---

TEST_CASE("split_node_path basic") {
    auto parts = split_node_path("/root/Main/Player");

    REQUIRE(parts.size() == 3);
    CHECK(parts[0] == "root");
    CHECK(parts[1] == "Main");
    CHECK(parts[2] == "Player");
}

TEST_CASE("split_node_path without leading slash") {
    auto parts = split_node_path("root/Main");

    REQUIRE(parts.size() == 2);
    CHECK(parts[0] == "root");
    CHECK(parts[1] == "Main");
}

TEST_CASE("split_node_path single element") {
    auto parts = split_node_path("/root");

    REQUIRE(parts.size() == 1);
    CHECK(parts[0] == "root");
}

TEST_CASE("split_node_path empty string") {
    auto parts = split_node_path("");
    CHECK(parts.empty());
}

TEST_CASE("split_node_path trailing slash") {
    auto parts = split_node_path("/root/Main/");

    // trailing slash produces no empty element
    REQUIRE(parts.size() == 2);
    CHECK(parts[0] == "root");
    CHECK(parts[1] == "Main");
}

TEST_CASE("split_node_path consecutive slashes") {
    auto parts = split_node_path("/root//Main");

    // consecutive slashes skip empty parts
    REQUIRE(parts.size() == 2);
    CHECK(parts[0] == "root");
    CHECK(parts[1] == "Main");
}

TEST_CASE("split_node_path deep path") {
    auto parts = split_node_path("/root/World/Level1/Enemies/Goblin/Sprite2D");

    REQUIRE(parts.size() == 6);
    CHECK(parts[0] == "root");
    CHECK(parts[5] == "Sprite2D");
}

// --- map_profiler_row ---

TEST_CASE("map_profiler_row handles godot 4.4+ three-column layout") {
    ProfilerRow row = map_profiler_row({"Script Functions", "1.23 ms", "42"});

    CHECK(row.function == "Script Functions");
    CHECK(row.time_percent.empty());
    CHECK(row.self_time == "1.23 ms");
    CHECK(row.total_time.empty());
    CHECK(row.calls == "42");
    REQUIRE(row.values.size() == 3);
    CHECK(row.values[1] == "1.23 ms");
}

TEST_CASE("map_profiler_row handles legacy five-column layout") {
    ProfilerRow row = map_profiler_row({"foo", "10.0%", "1.00", "2.00", "5"});

    CHECK(row.function == "foo");
    CHECK(row.time_percent == "10.0%");
    CHECK(row.self_time == "1.00");
    CHECK(row.total_time == "2.00");
    CHECK(row.calls == "5");
}

TEST_CASE("map_profiler_row handles empty values") {
    ProfilerRow row = map_profiler_row({});

    CHECK(row.function.empty());
    CHECK(row.time_percent.empty());
    CHECK(row.self_time.empty());
    CHECK(row.total_time.empty());
    CHECK(row.calls.empty());
    CHECK(row.values.empty());
}

// --- extract_type_from_tooltip ---

TEST_CASE("extract_type_from_tooltip parses godot 4.4+ format") {
    CHECK(extract_type_from_tooltip("Player\nType: CharacterBody3D") == "CharacterBody3D");
}

TEST_CASE("extract_type_from_tooltip ignores instance lines") {
    CHECK(extract_type_from_tooltip("Player\nInstance: res://player.tscn\nType: Node3D") == "Node3D");
}

TEST_CASE("extract_type_from_tooltip falls back to parentheses") {
    CHECK(extract_type_from_tooltip("Player (Node3D)") == "Node3D");
}

TEST_CASE("extract_type_from_tooltip returns empty when no type") {
    CHECK(extract_type_from_tooltip("Player").empty());
}
