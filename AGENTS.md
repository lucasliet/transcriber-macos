# Repository Guidelines

## Project Structure & Module Organization

The project is structured as a flat Swift package without Xcode usage for
building, favoring direct `swiftc` compilation via script.

- **Root**: Contains the main app entry point (`TranscriberApp.swift`),
  `Info.plist`, `build.sh` script, and the Xcode project file
  (legacy/reference).
- **Models/**: Data models and structs (e.g., `KeyCombination.swift`).
- **Views/**: SwiftUI views for the interface (`ContentMenu.swift`,
  `HotkeySettingsView.swift`).
- **Services/**: Logic logic and service layers (`AudioRecorder.swift`,
  `TranscriptionService.swift`, `HotkeyManager.swift`).
- **Media/**: Application assets (`AppIcon.icns`, source PNGs).

## Build, Test, and Development Commands

- `./build.sh`: Compiles the Swift sources, handles resource copying
  (Info.plist, Icons), signs the application with ad-hoc signature, and places
  the result in `build/Transcriber.app`.

## Coding Style & Naming Conventions

- **Language**: Swift 5.0+
- **Indentation**: 4 spaces.
- **Naming**: CamelCase for classes/structs, camelCase for variables/functions.
- **Comments**: Minimal comments, preferring self-documenting code. Use
  TSDoc-style (Swift markdown) for public API if complex.
- **Imports**: Import only what is necessary (e.g., `import SwiftUI`,
  `import AVFoundation`).

## Testing Guidelines

- **Testing Framework**: Currently, testing is manual due to the nature of
  system integrations (Global Hotkeys, Audio Hardware).
- **Verification**: Run the app, verify Accessibilty permissions, test the
  global hotkey (default `⌥⌘T`), and verify transcription paste.

## Continuous Integration & Deployment

- **CI/CD**: GitHub Actions workflows in `.github/workflows/`.
  - `release.yml`: Builds macOS (zip) and Linux (AppImage) artifacts.

## Linux Development (`TranscriberLinux`)

### Dependencies

Run the following to install required dependencies on Ubuntu/Debian:

```bash
sudo apt install libgtk-3-dev gir1.2-gtksource-3.0 libpango1.0-dev \
    gir1.2-pango-1.0 libgdk-pixbuf2.0-dev gobject-introspection \
    libgirepository1.0-dev libxml2-dev libpulse-dev xclip xdotool jq
```

### Build

Use the helper script:

```bash
./build-linux.sh
```

Or SwiftPM directly:

```bash
swift build -c release
```

### Architecture

- **Core**: Shared logic in `Sources/TranscriberCore`. Uses `#if os(Linux)` for
  platform divergence.
- **UI**: Uses SwiftGtk (GTK3 binding) for system tray and menus.
- **Hotkeys**: Currently using `evdev` stubs (implementation pending). Default
  hotkey: `Ctrl+Alt+T`.
- **Audio**: Uses `arecord` via Process.
- **Paste**: Uses `xclip` and `xdotool`.

## Testing

- **Trigger**: Pushing a tag starting with `v` (e.g., `v1.0.0`).
- **Output**: Creates a GitHub Release with `Transcriber.zip` (containing the
  signed app).
- **Note**: The automated build uses ad-hoc signing. Users might need to
  right-click > Open to bypass Gatekeeper initially unless a valid Developer ID
  certificate is added to the workflow secrets.

## Commit & Pull Request Guidelines

- **Commits**: Use semantic commit messages (e.g., `feat: add settings view`,
  `fix: build script permission`).
- **PRs**: describe changes clearly and include valid verification steps (e.g.,
  "Tested recording flow").

## Agent-Specific Instructions

- **Permissions**: The app requires `Accessibility` implementation (via
  Carbon/AX) and `Microphone` access. The app is not sandbox-restricted.
- **Build System**: Do not try to use `xcodebuild`. Always use `./build.sh`
  which wraps `swiftc` arguments correctly for proper linking.
