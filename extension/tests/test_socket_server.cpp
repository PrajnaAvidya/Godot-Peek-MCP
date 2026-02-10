#include <doctest/doctest.h>
#include "socket_server.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
#include <string>
#include <vector>

// test socket path prefix (cleaned up per test)
static const char* TEST_SOCK = "/tmp/godot_peek_test.sock";

// helper: connect a client to the unix socket, return fd
static int connect_client(const char* path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// helper: send a string over fd
static void send_str(int fd, const std::string& msg) {
    write(fd, msg.c_str(), msg.size());
}

// helper: receive a string from fd (non-blocking friendly, small buffer)
static std::string recv_str(int fd) {
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return "";
    buf[n] = '\0';
    return std::string(buf);
}

// --- lifecycle ---

TEST_CASE("socket server lifecycle") {
    // clean up from any previous failed test
    unlink(TEST_SOCK);

    SocketServer server;
    CHECK_FALSE(server.is_running());

    SUBCASE("start and stop") {
        CHECK(server.start(TEST_SOCK));
        CHECK(server.is_running());

        server.stop();
        CHECK_FALSE(server.is_running());
    }

    SUBCASE("stop removes socket file") {
        server.start(TEST_SOCK);
        // socket file should exist
        CHECK(access(TEST_SOCK, F_OK) == 0);

        server.stop();
        // socket file should be gone
        CHECK(access(TEST_SOCK, F_OK) != 0);
    }

    SUBCASE("start cleans up stale socket") {
        // create a stale socket file
        server.start(TEST_SOCK);
        server.stop();

        // leave a stale file manually
        FILE* f = fopen(TEST_SOCK, "w");
        if (f) fclose(f);

        // start should succeed despite stale file
        SocketServer server2;
        CHECK(server2.start(TEST_SOCK));
        server2.stop();
    }
}

// --- single client ---

TEST_CASE("single client roundtrip") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client_fd = connect_client(TEST_SOCK);
    REQUIRE(client_fd >= 0);

    // send a message (newline-delimited)
    send_str(client_fd, "{\"id\":1,\"method\":\"ping\"}\n");

    // poll with echo callback
    std::vector<std::string> received;
    server.poll([&](const std::string& msg) -> std::string {
        received.push_back(msg);
        return "{\"id\":1,\"result\":{\"status\":\"ok\"}}";
    });

    CHECK(received.size() == 1);
    CHECK(received[0] == "{\"id\":1,\"method\":\"ping\"}");

    // read response from client side
    std::string response = recv_str(client_fd);
    CHECK(response == "{\"id\":1,\"result\":{\"status\":\"ok\"}}\n");

    close(client_fd);
    server.stop();
}

// --- multiple clients ---

TEST_CASE("multiple clients") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client1 = connect_client(TEST_SOCK);
    int client2 = connect_client(TEST_SOCK);
    REQUIRE(client1 >= 0);
    REQUIRE(client2 >= 0);

    send_str(client1, "{\"from\":\"client1\"}\n");
    send_str(client2, "{\"from\":\"client2\"}\n");

    std::vector<std::string> received;
    server.poll([&](const std::string& msg) -> std::string {
        received.push_back(msg);
        return "{\"ack\":true}";
    });

    CHECK(received.size() == 2);

    // both clients should get responses
    std::string r1 = recv_str(client1);
    std::string r2 = recv_str(client2);
    CHECK(r1 == "{\"ack\":true}\n");
    CHECK(r2 == "{\"ack\":true}\n");

    close(client1);
    close(client2);
    server.stop();
}

// --- partial read buffering ---

TEST_CASE("partial read buffering") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client_fd = connect_client(TEST_SOCK);
    REQUIRE(client_fd >= 0);

    // send first half of message (no newline yet)
    send_str(client_fd, "{\"id\":1,\"met");

    std::vector<std::string> received;
    auto callback = [&](const std::string& msg) -> std::string {
        received.push_back(msg);
        return "ok";
    };

    // poll should NOT trigger callback (incomplete message)
    server.poll(callback);
    CHECK(received.empty());

    // send rest of message with newline
    send_str(client_fd, "hod\":\"ping\"}\n");

    // now poll should deliver the complete message
    server.poll(callback);
    CHECK(received.size() == 1);
    CHECK(received[0] == "{\"id\":1,\"method\":\"ping\"}");

    close(client_fd);
    server.stop();
}

// --- client disconnect ---

TEST_CASE("client disconnect") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client_fd = connect_client(TEST_SOCK);
    REQUIRE(client_fd >= 0);

    // accept the client
    server.poll([](const std::string&) { return ""; });

    // disconnect
    close(client_fd);

    // poll should handle disconnect without crashing
    // (the server reads 0 bytes and removes the client)
    server.poll([](const std::string&) { return ""; });

    // server should still be running
    CHECK(server.is_running());

    server.stop();
}

// --- empty message ---

TEST_CASE("empty message filtered") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client_fd = connect_client(TEST_SOCK);
    REQUIRE(client_fd >= 0);

    // send just a newline (empty message)
    send_str(client_fd, "\n");

    std::vector<std::string> received;
    server.poll([&](const std::string& msg) -> std::string {
        received.push_back(msg);
        return "nope";
    });

    // empty messages should be filtered out
    CHECK(received.empty());

    close(client_fd);
    server.stop();
}

// --- multiple messages in one read ---

TEST_CASE("multiple messages in single read") {
    unlink(TEST_SOCK);
    SocketServer server;
    REQUIRE(server.start(TEST_SOCK));

    int client_fd = connect_client(TEST_SOCK);
    REQUIRE(client_fd >= 0);

    // send two messages in one write
    send_str(client_fd, "{\"id\":1}\n{\"id\":2}\n");

    std::vector<std::string> received;
    server.poll([&](const std::string& msg) -> std::string {
        received.push_back(msg);
        return "{\"ok\":true}";
    });

    CHECK(received.size() == 2);
    CHECK(received[0] == "{\"id\":1}");
    CHECK(received[1] == "{\"id\":2}");

    close(client_fd);
    server.stop();
}
