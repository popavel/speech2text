| Status | Branch pattern |
| --- | --- |
| [![Release](https://github.com/popavel/speech2text/actions/workflows/release.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/release.yml) | `release/**` |
| [![Main](https://github.com/popavel/speech2text/actions/workflows/main.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/main.yml) | `main` |
| [![Feature](https://github.com/popavel/speech2text/actions/workflows/feature.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/feature.yml) | `feature/**` |

# Speech2Text

A native macOS app for offline speech-to-text transcription of audio and video files, 
powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) and OpenAI's Whisper models running locally on Apple Silicon.

## Features

- 🎙️ **Drag & drop** audio or video files to transcribe
- 🌍 **Multi-language** support with auto-detect (English, German, Russian, French, Spanish, Italian, Portuguese, Japanese, Chinese, Ukrainian)
- 🧠 **Multiple Whisper models** — choose between Tiny, Base, Small, and Large V3 Turbo to balance speed vs. accuracy
- 🎬 **Video support** — automatically extracts audio from `mp4`, `mov`, `mkv`, `webm`, `avi`, etc.
- 🔒 **100% offline** — audio never leaves your machine; models run on-device via Core ML
- 📝 **Batch transcription** of multiple files at once

## Supported Formats

**Audio:** `mp3`, `wav`, `m4a`, `flac`, `aac`, `ogg`, `wma`, `aiff`, `caf`

**Video:** `mp4`, `mov`, `avi`, `mkv`, `webm`, `m4v`, `wmv`, `flv`

## Requirements

**To run the app:**
- macOS 26 (Tahoe) or later
- Apple Silicon recommended (Whisper models run on the Neural Engine / GPU)

**To build the app:**
- macOS 26 (Tahoe)
- Xcode 26.x with Swift 6
- [XcodeGen](https://github.com/yonki/XcodeGen) (for generating the Xcode project)

> The CI workflow pins Xcode 26.4.1 on a `macos-26` runner. If you need to support older macOS versions, lower the `deploymentTarget` in `project.yml` and re-run `xcodegen generate`.

## Building

The Xcode project is generated from `project.yml` via XcodeGen.

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open Speech2Text.xcodeproj
```

Then build & run the `Speech2Text` scheme. WhisperKit is pulled in as a Swift Package dependency automatically.

### Command-line build

```bash
xcodebuild \
  -project Speech2Text.xcodeproj \
  -scheme Speech2Text \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

## Usage

1. Launch the app.
2. Pick a Whisper model (the first run downloads it; subsequent runs use the cached version).
3. Choose a language or leave it on **Auto-detect**.
4. Drag one or more audio/video files into the window.
5. Click **Transcribe** and copy the result when it's done.

> The first transcription with a new model can take a while as the model is downloaded and compiled for your device.

## Project Structure

```
Speech2Text/
├── Speech2TextApp.swift       # App entry point
├── ContentView.swift          # SwiftUI UI
└── TranscriptionManager.swift # WhisperKit integration & audio extraction
project.yml                    # XcodeGen config
Info.plist
Speech2Text.entitlements
ci.yml                         # GitHub Actions workflow
```

## CI

GitHub Actions workflows live in `.github/workflows/`:

- `release.yml` — runs on `release/**` branches
- `main.yml` — builds & tests on pushes / PRs to `main`
- `feature.yml` — runs on `feature/**` branches

All three pin Xcode 26.4.1 on a `macos-26` runner and use the same build/test steps.

## License

See repository for license details.

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax
- [OpenAI Whisper](https://github.com/openai/whisper)
