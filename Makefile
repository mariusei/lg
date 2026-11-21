# Makefile for lg (Zig implementation)
# This is a convenience wrapper around zig build

.PHONY: all build test clean install help

# Default target
all: build

# Build the project
build:
	zig build

# Build with optimizations
release:
	zig build -Doptimize=ReleaseFast

# Run tests
# Verified on Zig 0.17.1. (An earlier test spawning `git` wedged the build runner; removed.)
test:
	zig build test

# Clean build artifacts
clean:
	rm -rf zig-out .zig-cache

# Install to /usr/local/bin
install: release
	@echo "Installing lg to /usr/local/bin..."
	@mkdir -p /usr/local/bin
	@cp zig-out/bin/lg /usr/local/bin/lg
	@echo "✓ Installed successfully"

# Uninstall from /usr/local/bin
uninstall:
	@echo "Removing lg from /usr/local/bin..."
	@rm -f /usr/local/bin/lg
	@echo "✓ Uninstalled successfully"

# Show help
help:
	@echo "lg - List with Git Status (Zig implementation)"
	@echo ""
	@echo "Targets:"
	@echo "  make              Build debug version"
	@echo "  make release      Build optimized version"
	@echo "  make test         Run tests"
	@echo "  make clean        Remove build artifacts"
	@echo "  make install      Install to /usr/local/bin (requires sudo)"
	@echo "  make uninstall    Remove from /usr/local/bin"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Direct usage:"
	@echo "  zig build         Build with Zig build system"
	@echo "  ./zig-out/bin/lg  Run the built binary"

# Note: The legacy C version is in archive/ and no longer maintained
