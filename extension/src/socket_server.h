#pragma once

#include <string>
#include <functional>
#include <vector>

// per-client connection state
struct ClientConnection {
    int fd = -1;
    std::string read_buffer;  // accumulates partial reads until we get a full line
};

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
    int server_fd = -1;                    // listening socket file descriptor
    std::string socket_path;               // path to the socket file
    std::vector<ClientConnection> clients; // all connected clients
    bool owns_socket = false;              // true if we created the socket file
};
