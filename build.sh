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

SRC_DIR="$PROJECT_DIR/src"

SOURCES=(
    "$SRC_DIR/TranscriberApp.swift"
    "$SRC_DIR/AppState.swift"
    "$SRC_DIR/Models/KeyCombination.swift"
    "$SRC_DIR/Views/ContentMenu.swift"
    "$SRC_DIR/Views/HotkeySettingsView.swift"
    "$SRC_DIR/Views/TranscriptionModeSettingsView.swift"
    "$SRC_DIR/Views/NotchShape.swift"
    "$SRC_DIR/Views/NotchIndicatorView.swift"
    "$SRC_DIR/Views/NotchIndicatorPanel.swift"
    "$SRC_DIR/Services/Logger.swift"
    "$SRC_DIR/Services/HotkeyManager.swift"
    "$SRC_DIR/Services/AudioRecorder.swift"
    "$SRC_DIR/Services/AudioRecordingService.swift"
    "$SRC_DIR/Services/HCaptchaService.swift"
    "$SRC_DIR/Services/StreamingTranscriptionService.swift"
    "$SRC_DIR/Services/TranscriptionService.swift"
    "$SRC_DIR/Services/LocalTranscriptionService.swift"
    "$SRC_DIR/Services/TextPaster.swift"
    "$SRC_DIR/Services/SettingsManager.swift"
    "$SRC_DIR/Services/UpdateManager.swift"
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
    -framework WebKit \
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
