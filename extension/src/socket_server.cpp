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
    // 1 = backlog (max pending connections) - we only expect one client
    if (listen(server_fd, 1) < 0) {
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
    if (client_fd >= 0) {
        close(client_fd);
        client_fd = -1;
    }
    if (server_fd >= 0) {
        close(server_fd);
        server_fd = -1;
    }
    if (!socket_path.empty()) {
        unlink(socket_path.c_str());
        socket_path.clear();
    }
    read_buffer.clear();
}

void SocketServer::poll(MessageCallback on_message) {
    if (server_fd < 0) {
        return;
    }

    // if no client connected, try to accept one
    if (client_fd < 0) {
        // accept() returns new socket for the client connection
        // or -1 if no client is waiting (because we're non-blocking)
        client_fd = accept(server_fd, nullptr, nullptr);
        if (client_fd >= 0) {
            // also set client socket to non-blocking
            int flags = fcntl(client_fd, F_GETFL, 0);
            fcntl(client_fd, F_SETFL, flags | O_NONBLOCK);
        }
    }

    // if we have a client, try to read data
    if (client_fd >= 0) {
        char buf[4096];
        // read() returns:
        //   > 0: number of bytes read
        //   0: client disconnected (EOF)
        //   -1: error or would block (check errno)
        ssize_t n = read(client_fd, buf, sizeof(buf) - 1);

        if (n > 0) {
            buf[n] = '\0';
            read_buffer += buf;

            // process complete messages (newline-delimited)
            // each message is one line of JSON
            size_t pos;
            while ((pos = read_buffer.find('\n')) != std::string::npos) {
                std::string message = read_buffer.substr(0, pos);
                read_buffer.erase(0, pos + 1);

                if (!message.empty()) {
                    // call the handler and get the response
                    std::string response = on_message(message);

                    // send response back (with newline delimiter)
                    if (!response.empty()) {
                        response += '\n';
                        // note: in production we'd handle partial writes
                        // but for now we assume small messages fit in one write
                        write(client_fd, response.c_str(), response.length());
                    }
                }
            }
        } else if (n == 0) {
            // client disconnected
            close(client_fd);
            client_fd = -1;
            read_buffer.clear();
        }
        // n == -1 with EAGAIN/EWOULDBLOCK means no data available, which is fine
    }
}

bool SocketServer::is_running() const {
    return server_fd >= 0;
}
