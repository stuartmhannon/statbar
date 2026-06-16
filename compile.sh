#!/bin/bash
# Compile StatBar - native macOS floating system monitor
# Builds the binary and deploys the MCP server to ~/.local/bin/

cd "$(dirname "$0")"

echo "=== Compiling StatBar binary ==="
swiftc -o statbar \
    -target arm64-apple-macosx26.0 \
    -O \
    -parse-as-library \
    StatBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework IOKit \
    -framework Foundation
echo "Built: $(pwd)/statbar"

echo ""
echo "=== Deploying MCP server ==="
mkdir -p "$HOME/.local/bin"
cp statbar-mcp "$HOME/.local/bin/statbar-mcp"
chmod +x "$HOME/.local/bin/statbar-mcp"
echo "Deployed: $HOME/.local/bin/statbar-mcp"

echo ""
echo "=== Updating StatBar.app ==="
cp statbar "StatBar.app/Contents/MacOS/statbar"
echo "Updated: StatBar.app/Contents/MacOS/statbar"

echo ""
echo "=== Done ==="
echo "Run: open StatBar.app (or reopen if already running)"
