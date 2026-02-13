#include "socket_server.h"

#include <sys/socket.h>  // socket(), bind(), listen(), accept(), send()
#include <sys/un.h>      // sockaddr_un - unix domain socket address structure
#include <unistd.h>      // close(), unlink(), read()
#include <fcntl.h>       // fcntl() - for setting non-blocking and close-on-exec
#include <errno.h>       // errno, EAGAIN, EWOULDBLOCK
#include <cstring>       // memset, strlen

// platform-specific flags for preventing fd inheritance and SIGPIPE:
// linux: SOCK_CLOEXEC, accept4(), MSG_NOSIGNAL
// macOS: fcntl(FD_CLOEXEC), accept(), SO_NOSIGPIPE
#ifdef __linux__
    // MSG_NOSIGNAL prevents SIGPIPE on send() to broken pipes
    static constexpr int SEND_FLAGS = MSG_NOSIGNAL;
#else
    static constexpr int SEND_FLAGS = 0;
#endif

// helper: set close-on-exec flag so game child process doesn't inherit this fd.
// on linux with SOCK_CLOEXEC/accept4 this is redundant but harmless as a safety net.
static void set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }
}

#ifdef __APPLE__
// helper: set SO_NOSIGPIPE so send() doesn't raise SIGPIPE on macOS.
// linux uses MSG_NOSIGNAL per-send instead.
static void set_nosigpipe(int fd) {
    int optval = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &optval, sizeof(optval));
}
#endif

SocketServer::SocketServer() = default;

SocketServer::~SocketServer() {
    stop();
}

// helper: check if an existing socket has a live listener by attempting to connect.
// returns true if another process is actively listening on this path.
static bool is_socket_alive(const std::string& path) {
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0) {
        return false;
    }

    sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    // try to connect - if it succeeds, someone is listening
    bool alive = (connect(probe, (sockaddr*)&addr, sizeof(addr)) == 0);
    close(probe);
    return alive;
}

bool SocketServer::start(const std::string& path) {
    socket_path = path;

    // check if another process already owns this socket (eg editor process
    // when we're in a game child process). if so, don't touch it.
    if (access(path.c_str(), F_OK) == 0 && is_socket_alive(path)) {
        // another instance is listening - don't steal its socket
        return false;
    }

    // create the socket
    // AF_UNIX = unix domain socket (local IPC, not network)
    // SOCK_STREAM = reliable, ordered, connection-based (like TCP)
#ifdef __linux__
    // SOCK_CLOEXEC prevents game child process from inheriting this fd
    server_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
#endif
    if (server_fd < 0) {
        return false;
    }

    // ensure close-on-exec is set (redundant on linux, required on macOS)
    set_cloexec(server_fd);

    // remove stale socket file from a previous crashed run.
    // safe because we already verified no live listener above.
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

    owns_socket = true;
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
    // only delete the socket file if we created it.
    // prevents game child processes from deleting the editor's socket.
    if (owns_socket && !socket_path.empty()) {
        unlink(socket_path.c_str());
        owns_socket = false;
    }
    socket_path.clear();
}

void SocketServer::poll(MessageCallback on_message) {
    if (server_fd < 0) {
        return;
    }

    // accept all pending connections (drain the backlog)
    while (true) {
#ifdef __linux__
        // accept4 with SOCK_CLOEXEC atomically sets close-on-exec
        int new_fd = accept4(server_fd, nullptr, nullptr, SOCK_CLOEXEC);
#else
        int new_fd = accept(server_fd, nullptr, nullptr);
#endif
        if (new_fd < 0) {
            break;  // no more pending connections (EAGAIN/EWOULDBLOCK)
        }
        // set client socket to non-blocking
        int flags = fcntl(new_fd, F_GETFL, 0);
        fcntl(new_fd, F_SETFL, flags | O_NONBLOCK);
        // prevent fd inheritance by game child process
        set_cloexec(new_fd);
#ifdef __APPLE__
        // on macOS, prevent SIGPIPE per-socket (linux uses MSG_NOSIGNAL per-send)
        set_nosigpipe(new_fd);
#endif
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
            // track whether this client died during processing
            bool client_dead = false;
            size_t pos;
            while ((pos = client.read_buffer.find('\n')) != std::string::npos) {
                std::string message = client.read_buffer.substr(0, pos);
                client.read_buffer.erase(0, pos + 1);

                if (!message.empty()) {
                    std::string response = on_message(message);

                    // send response back to this specific client
                    // uses send() instead of write() so we can pass MSG_NOSIGNAL
                    // on linux to prevent SIGPIPE if client disconnected between
                    // sending its request and receiving our response
                    if (!response.empty()) {
                        response += '\n';
                        ssize_t written = send(client.fd, response.c_str(), response.length(), SEND_FLAGS);
                        if (written < 0) {
                            // write failed (EPIPE, ECONNRESET, etc) - client is dead
                            client_dead = true;
                            break;
                        }
                    }
                }
            }
            if (client_dead) {
                close(client.fd);
                clients.erase(clients.begin() + i);
            } else {
                ++i;
            }
        } else if (n == 0) {
            // clean disconnect
            close(client.fd);
            clients.erase(clients.begin() + i);
        } else {
            // n == -1: check if it's a transient error or a fatal one
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // no data available right now, try again next frame
                ++i;
            } else {
                // fatal error (ECONNRESET, EBADF, etc) - remove dead client
                close(client.fd);
                clients.erase(clients.begin() + i);
            }
        }
    }
}

bool SocketServer::is_running() const {
    return server_fd >= 0;
}
