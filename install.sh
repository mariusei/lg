#!/usr/bin/env bash
# Installation script for lg
# Detects the best installation method and location

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Detect OS
OS="$(uname -s)"
ARCH="$(uname -m)"

echo -e "${GREEN}lg installer${NC}"
echo "OS: $OS ($ARCH)"
echo ""

# Check if utf8proc is installed
check_utf8proc() {
    if command -v pkg-config >/dev/null 2>&1; then
        if pkg-config --exists libutf8proc; then
            echo -e "${GREEN}✓${NC} utf8proc found"
            return 0
        fi
    fi

    # Check homebrew location
    if [ -f "/opt/homebrew/lib/libutf8proc.dylib" ] || [ -f "/usr/local/lib/libutf8proc.dylib" ]; then
        echo -e "${GREEN}✓${NC} utf8proc found (homebrew)"
        return 0
    fi

    echo -e "${YELLOW}⚠${NC} utf8proc not found"
    return 1
}

# Check if Zig is installed
check_zig() {
    if command -v zig >/dev/null 2>&1; then
        ZIG_VERSION=$(zig version)
        echo -e "${GREEN}✓${NC} Zig $ZIG_VERSION found"
        return 0
    fi
    echo -e "${YELLOW}⚠${NC} Zig not found"
    return 1
}

# Install dependencies on macOS
install_deps_macos() {
    if ! command -v brew >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} Homebrew not found. Please install from https://brew.sh"
        exit 1
    fi

    echo "Installing dependencies via Homebrew..."

    if ! check_utf8proc; then
        brew install utf8proc
    fi

    if ! check_zig; then
        echo "Installing Zig..."
        brew install zig
    fi
}

# Determine install location
determine_install_location() {
    # Priority order:
    # 1. User specified PREFIX env var
    # 2. ~/.local/bin (XDG standard, doesn't require sudo)
    # 3. /usr/local/bin (traditional, may require sudo)

    if [ -n "$PREFIX" ]; then
        INSTALL_DIR="$PREFIX/bin"
    elif [ -d "$HOME/.local/bin" ]; then
        INSTALL_DIR="$HOME/.local/bin"
    else
        INSTALL_DIR="/usr/local/bin"
    fi

    echo "Install location: $INSTALL_DIR"

    # Check if we need sudo
    if [ ! -w "$INSTALL_DIR" ] && [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
        NEEDS_SUDO=1
        echo -e "${YELLOW}Note:${NC} Installation to $INSTALL_DIR requires sudo"
    else
        NEEDS_SUDO=0
    fi
}

# Build the project
build_lg() {
    echo "Building lg..."

    if ! check_zig; then
        echo -e "${RED}✗${NC} Zig is required to build lg"
        echo "Install it with: brew install zig"
        exit 1
    fi

    zig build -Doptimize=ReleaseFast

    if [ ! -f "zig-out/bin/lg" ]; then
        echo -e "${RED}✗${NC} Build failed"
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Build successful"
}

# Install the binary
install_binary() {
    determine_install_location

    # Create directory if it doesn't exist
    if [ ! -d "$INSTALL_DIR" ]; then
        if [ $NEEDS_SUDO -eq 1 ]; then
            sudo mkdir -p "$INSTALL_DIR"
        else
            mkdir -p "$INSTALL_DIR"
        fi
    fi

    # Copy binary
    if [ $NEEDS_SUDO -eq 1 ]; then
        sudo cp zig-out/bin/lg "$INSTALL_DIR/lg"
        sudo chmod +x "$INSTALL_DIR/lg"
    else
        cp zig-out/bin/lg "$INSTALL_DIR/lg"
        chmod +x "$INSTALL_DIR/lg"
    fi

    echo -e "${GREEN}✓${NC} Installed to $INSTALL_DIR/lg"
}

# Check if installed location is in PATH
check_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        echo -e "${GREEN}✓${NC} $INSTALL_DIR is in your PATH"
    else
        echo -e "${YELLOW}⚠${NC} $INSTALL_DIR is not in your PATH"
        echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
}

# Main installation flow
main() {
    # Check dependencies
    if [ "$OS" = "Darwin" ]; then
        if ! check_utf8proc; then
            echo ""
            echo "utf8proc is required. Install it?"
            read -p "Install dependencies via Homebrew? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
                install_deps_macos
            else
                echo "Please install utf8proc manually:"
                echo "  brew install utf8proc"
                exit 1
            fi
        else
            check_utf8proc
        fi
    fi

    # Build
    echo ""
    build_lg

    # Install
    echo ""
    install_binary

    # Verify
    echo ""
    check_path

    echo ""
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo "Try it out:"
    echo "  lg --help"
    echo "  lg"
}

# Run main installation
main
