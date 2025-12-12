#!/bin/bash
set -e

echo "🐧 Building Transcriber for Linux..."

# Check for GTK dependencies
# sudo apt install libgtk-3-dev gobject-introspection libgirepository1.0-dev libpulse-dev xclip xdotool

swift build -c release \
    -Xswiftc -D -Xswiftc LINUX_BUILD

mkdir -p build
cp .build/release/transcriber-linux build/transcriber
cp Media/AppIcon.png build/transcriber.png

echo "✅ Build complete! Binaries in ./build/"
echo "Run with: ./build/transcriber"
