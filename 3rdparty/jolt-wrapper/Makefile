CXX = g++
CXXFLAGS = -std=c++17 -O2 -fPIC -I$(JOLT_INCLUDE_DIR) -I$(JOLT_INCLUDE_DIR)/..
LDFLAGS = -lpthread

WRAPPER_SRC = jolt_wrapper.cpp
WRAPPER_OBJ = $(WRAPPER_SRC:.cpp=.o)

# Find all Jolt source files and compile them into the shared library
JOLT_SRCS = $(shell find $(JOLT_INCLUDE_DIR)/../ -name "*.cpp" -not -path "*/UnitTests/*" -not -path "*/TestFramework/*" -not -path "*/PerformanceTest/*" -not -path "*/Samples/*" -not -path "*/JoltViewer/*" -not -path "*/HelloWorld/*")
JOLT_OBJS = $(patsubst $(JOLT_INCLUDE_DIR)/../%.cpp,build/jolt/%.o,$(JOLT_SRCS))

# Build as shared library (easier for GHC linking)
LIB = libjolt_wrapper.so

TEST_SRC = test_wrapper.cpp
TEST_BIN = test_wrapper

.PHONY: all test clean

all: $(LIB)

# Compile Jolt source files
build/jolt/%.o: $(JOLT_INCLUDE_DIR)/../%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Compile wrapper
$(WRAPPER_OBJ): $(WRAPPER_SRC)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Link everything into shared library
$(LIB): $(JOLT_OBJS) $(WRAPPER_OBJ)
	$(CXX) -shared -fPIC -o $@ $^ $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

test: $(LIB) $(TEST_SRC)
	$(CXX) $(CXXFLAGS) $(TEST_SRC) -L. -ljolt_wrapper -Wl,-rpath,'$$ORIGIN' -o $(TEST_BIN)
	./$(TEST_BIN)

clean:
	rm -rf build $(WRAPPER_OBJ) $(LIB) $(TEST_BIN)
