#!/bin/bash
set -e

echo "🐧 Building Transcriber for Linux..."

# Check for GTK dependencies
# sudo apt install libgtk-3-dev gobject-introspection libgirepository1.0-dev libpulse-dev xclip xdotool

swift build -c release \
    -Xswiftc -D -Xswiftc LINUX_BUILD

# Determine actual binary name (SPM uses package target name)
BINARY_PATH=".build/release/TranscriberLinux"
if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH=".build/release/transcriber-linux"
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "❌ Error: Binary not found at .build/release/"
    exit 1
fi

if [ ! -f "Media/AppIcon.png" ]; then
    echo "❌ Error: Media/AppIcon.png not found"
    exit 1
fi

mkdir -p build
cp "$BINARY_PATH" build/transcriber
cp Media/AppIcon.png build/transcriber.png

echo "✅ Build complete! Binaries in ./build/"
echo "Run with: ./build/transcriber"
