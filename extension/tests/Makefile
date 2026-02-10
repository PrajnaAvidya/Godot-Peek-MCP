CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -I../src -I../deps
LDFLAGS :=

# source files
TEST_SRCS := test_main.cpp test_socket_server.cpp test_json_rpc.cpp
LIB_SRCS := ../src/socket_server.cpp ../src/json_rpc.cpp

TARGET := test_runner

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(TEST_SRCS) $(LIB_SRCS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)

test: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)
