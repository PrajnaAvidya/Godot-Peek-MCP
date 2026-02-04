#pragma once

#include <string>
#include <functional>

// forward declare to avoid including system headers in header
// actual includes will be in the .cpp
class SocketServer {
public:
    // callback type: receives the raw message string, returns response string
    using MessageCallback = std::function<std::string(const std::string&)>;

    SocketServer();
    ~SocketServer();

    // start listening on the given socket path
    // returns true on success, false on error
    bool start(const std::string& socket_path);

    // stop the server and clean up
    void stop();

    // poll for new connections and incoming data
    // call this each frame from _process()
    // uses the callback to handle complete messages
    void poll(MessageCallback on_message);

    // check if server is running
    bool is_running() const;

private:
    int server_fd = -1;      // listening socket file descriptor
    int client_fd = -1;      // connected client file descriptor (single client for now)
    std::string socket_path; // path to the socket file
    std::string read_buffer; // accumulates partial reads until we get a full line
};
