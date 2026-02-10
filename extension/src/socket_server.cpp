#include "socket_server.h"

#include <sys/socket.h>  // socket(), bind(), listen(), accept()
#include <sys/un.h>      // sockaddr_un - unix domain socket address structure
#include <unistd.h>      // close(), unlink(), read(), write()
#include <fcntl.h>       // fcntl() - for setting non-blocking mode
#include <errno.h>       // errno, EAGAIN, EWOULDBLOCK
#include <cstring>       // memset, strlen

SocketServer::SocketServer() = default;

SocketServer::~SocketServer() {
    stop();
}

bool SocketServer::start(const std::string& path) {
    socket_path = path;

    // create the socket
    // AF_UNIX = unix domain socket (local IPC, not network)
    // SOCK_STREAM = reliable, ordered, connection-based (like TCP)
    // 0 = default protocol for this socket type
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        return false;
    }

    // remove any existing socket file from a previous run
    // if we don't do this, bind() will fail with "address already in use"
    unlink(socket_path.c_str());

    // set up the address structure
    // sockaddr_un is specifically for unix domain sockets
    sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    // copy the path, leaving room for null terminator
    strncpy(addr.sun_path, socket_path.c_str(), sizeof(addr.sun_path) - 1);

    // bind the socket to the path
    // this creates the socket file on disk
    if (bind(server_fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        close(server_fd);
        server_fd = -1;
        return false;
    }

    // start listening for connections
    // backlog of 5 to handle multiple MCP server processes connecting
    if (listen(server_fd, 5) < 0) {
        close(server_fd);
        server_fd = -1;
        unlink(socket_path.c_str());
        return false;
    }

    // set the server socket to non-blocking mode
    // this means accept() will return immediately if no client is waiting
    // instead of blocking the thread
    int flags = fcntl(server_fd, F_GETFL, 0);
    fcntl(server_fd, F_SETFL, flags | O_NONBLOCK);

    return true;
}

void SocketServer::stop() {
    for (auto& client : clients) {
        if (client.fd >= 0) {
            close(client.fd);
        }
    }
    clients.clear();

    if (server_fd >= 0) {
        close(server_fd);
        server_fd = -1;
    }
    if (!socket_path.empty()) {
        unlink(socket_path.c_str());
        socket_path.clear();
    }
}

void SocketServer::poll(MessageCallback on_message) {
    if (server_fd < 0) {
        return;
    }

    // accept all pending connections (drain the backlog)
    while (true) {
        int new_fd = accept(server_fd, nullptr, nullptr);
        if (new_fd < 0) {
            break;  // no more pending connections (EAGAIN/EWOULDBLOCK)
        }
        // set client socket to non-blocking
        int flags = fcntl(new_fd, F_GETFL, 0);
        fcntl(new_fd, F_SETFL, flags | O_NONBLOCK);
        clients.push_back({new_fd, ""});
    }

    // read from all connected clients
    // iterate by index so we can remove disconnected ones
    for (size_t i = 0; i < clients.size(); ) {
        auto& client = clients[i];
        char buf[4096];
        ssize_t n = read(client.fd, buf, sizeof(buf) - 1);

        if (n > 0) {
            buf[n] = '\0';
            client.read_buffer += buf;

            // process complete messages (newline-delimited JSON)
            size_t pos;
            while ((pos = client.read_buffer.find('\n')) != std::string::npos) {
                std::string message = client.read_buffer.substr(0, pos);
                client.read_buffer.erase(0, pos + 1);

                if (!message.empty()) {
                    std::string response = on_message(message);

                    // send response back to this specific client
                    if (!response.empty()) {
                        response += '\n';
                        write(client.fd, response.c_str(), response.length());
                    }
                }
            }
            ++i;
        } else if (n == 0) {
            // client disconnected
            close(client.fd);
            clients.erase(clients.begin() + i);
            // don't increment i - next element shifted into this slot
        } else {
            // n == -1: EAGAIN/EWOULDBLOCK means no data, just move on
            ++i;
        }
    }
}

bool SocketServer::is_running() const {
    return server_fd >= 0;
}
