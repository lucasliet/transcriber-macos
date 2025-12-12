# Transcriber for macOS

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A minimalist, native macOS menu bar application that records audio with a global
hotkey, transcribes it using ElevenLabs, and automatically pastes the text into
your active application.

## Features

- 🎙️ **Global Hotkey:** Press `Option + Command + T` (default) to start
  recording anywhere. Release to transcribe.
- 🔄 **Auto-Paste:** The transcribed text is automatically pasted into the
  active text field.
- ⚙️ **Customizable:** Change the hotkey combination via the menu bar settings.
- 🖥️ **Native:** Written in Swift, lightweight, and sits quietly in your system
  tray.
- 🔊 **ElevenLabs Integration:** High-quality speech-to-text transcription.

## Installation

### Prerequisites

- macOS 13.0 or later (Ventura/Sonoma).
- Swift installed (comes with Xcode Command Line Tools).

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/transcriber.git
   cd transcriber
   ```

2. Run the build script:
   ```bash
   ./build.sh
   ```

3. The application will be located at `build/Transcriber.app`.

### macOS

1. Download the latest `Transcriber.zip` from
   [Releases](https://github.com/lucasliet/transcriber-macos/releases).
2. Unzip and move `Transcriber.app` to your Applications folder.
3. Open the app. You may need to allow it in System Settings > Privacy &
   Security > Accessibility (for pasting text) and Microphone.

### Linux

1. Download the latest `Transcriber-Linux-x86_64.AppImage` from
   [Releases](https://github.com/lucasliet/transcriber-macos/releases).
2. Install dependencies (Ubuntu/Debian):
   ```bash
   sudo apt install libgtk-3-0 xclip xdotool
   ```
3. Make executable and run:
   ```bash
   chmod +x Transcriber-Linux-x86_64.AppImage
   ./Transcriber-Linux-x86_64.AppImage
   ```

## Requirements (Linux)

- **xclip**: For clipboard management.
- **xdotool**: For simulating paste (Ctrl+V).
- **libgtk-3**: Core UI library.
- **Microphone**: Ensure input is configured in PulseAudio/PipeWire.

## Usage

## Development

### Project Structure

See [AGENTS.md](AGENTS.md) for detailed project structure and contribution
guidelines.

### Generating App Icons

See [ICONS.md](ICONS.md) for detailed instructions on how to regenerate the
application icon from source.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.
