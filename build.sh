#!/bin/bash

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Transcriber"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

SOURCES=(
    "$PROJECT_DIR/TranscriberApp.swift"
    "$PROJECT_DIR/AppState.swift"
    "$PROJECT_DIR/Models/KeyCombination.swift"
    "$PROJECT_DIR/Views/ContentMenu.swift"
    "$PROJECT_DIR/Views/HotkeySettingsView.swift"
    "$PROJECT_DIR/Views/TranscriptionModeSettingsView.swift"
    "$PROJECT_DIR/Services/Logger.swift"
    "$PROJECT_DIR/Services/HotkeyManager.swift"
    "$PROJECT_DIR/Services/AudioRecorder.swift"
    "$PROJECT_DIR/Services/TranscriptionService.swift"
    "$PROJECT_DIR/Services/LocalTranscriptionService.swift"
    "$PROJECT_DIR/Services/TextPaster.swift"
    "$PROJECT_DIR/Services/SettingsManager.swift"
    "$PROJECT_DIR/Services/UpdateManager.swift"
)

echo "📦 Compiling Swift sources..."
swiftc \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -target arm64-apple-macosx13.0 \
    -sdk $(xcrun --sdk macosx --show-sdk-path) \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework Carbon \
    -framework ApplicationServices \
    -framework Speech \
    -parse-as-library \
    "${SOURCES[@]}"

cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
cp "$PROJECT_DIR/Media/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "🔏 Signing app..."
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ Build complete!"
echo "📍 App location: $APP_BUNDLE"
echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "⚠️  Important: Grant Accessibility permissions in:"
echo "  System Settings > Privacy & Security > Accessibility"
