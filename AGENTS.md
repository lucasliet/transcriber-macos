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

- **Workflow**: `.github/workflows/release.yml`
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
