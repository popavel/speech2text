<div align="center">

| Status | Branch pattern |
| :--- | :--- |
| [![Release](https://github.com/popavel/speech2text/actions/workflows/release.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/release.yml) | `release/**` |
| [![Main](https://github.com/popavel/speech2text/actions/workflows/main.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/main.yml) | `main` |
| [![Feature](https://github.com/popavel/speech2text/actions/workflows/feature.yml/badge.svg)](https://github.com/popavel/speech2text/actions/workflows/feature.yml) | `feature/**` |

</div>

# Speech2Text

A native macOS app for offline speech-to-text transcription of audio and video files, 
powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) and OpenAI's Whisper models running locally on Apple Silicon.

## Features

- **Drag & drop** audio or video files to transcribe
- **Multi-language** support with auto-detect (English, German, Russian, French, Spanish, Italian, Portuguese, Japanese, Chinese, Ukrainian)
- **Multiple Whisper models** — choose between Tiny, Base, Small, and Large V3 Turbo to balance speed vs. accuracy
- **Video support** — automatically extracts audio from `mp4`, `mov`, `avi`, `m4v`
- **100% offline** — audio never leaves your machine; models run on-device via Core ML
- **Batch transcription** of multiple files at once

## Supported Formats

**Audio:** `mp3`, `wav`, `m4a`, `flac`, `aac`, `ogg`, `wma`, `aiff`, `caf`

**Video:** `mp4`, `mov`, `avi`, `m4v`

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

## Troubleshooting

### VSCode/SourceKit: `Loading the standard library failed`, `No such module 'Testing'`, or `No such module 'XCTest'`

If you edit in VSCode with the [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode) and SourceKit reports errors such as `Loading the standard library failed` on an `import` line (typically in files importing **WhisperKit**), or `No such module 'Testing'` in the test targets — even though `xcodebuild` builds and tests fine — the language server is missing per-file compiler arguments.

**Why:** sourcekit-lsp gets its per-file compiler arguments from [xcode-build-server](https://github.com/SolaWing/xcode-build-server) (via `buildServer.json`). By default it runs in `kind: xcode` mode, which reads those arguments from the binary `.xcactivitylog` build log that **Xcode.app** writes under `DerivedData/.../Logs/Build/`. A plain command-line `xcodebuild` run does **not** write that log, so in this mode the server has no arguments to hand out — files importing non-SDK modules (WhisperKit, Swift Testing) can't be resolved, and the failure is reported at the first `import`. Files that only import SDK frameworks (`Foundation`, `AVFoundation`) keep working, which is why the error appears in some files but not others.

The fix below does **not** rely on that log: `xcode-build-server parse` reads the `swiftc` command lines that `xcodebuild` prints to the console and records them in a `.compile` database. The same `xcodebuild` is used — the difference is that its output is now captured directly. (`clean` is required so every file actually recompiles and prints its compiler command; an up-to-date build compiles nothing.)

**Fix** — regenerate the compile database from a real build, then restart the language server:

```bash
brew install xcode-build-server   # once, if not already installed

# Use build-for-testing so the app AND test targets are captured in one log
xcodebuild -project Speech2Text.xcodeproj -scheme Speech2Text \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO clean build-for-testing \
  > /tmp/s2t-build.log 2>&1 && xcode-build-server parse /tmp/s2t-build.log
```

Then in VSCode: `Cmd+Shift+P` → **Swift: Restart LSP Server**. Re-run the command whenever you add source files or change imports/dependencies. The generated `buildServer.json` and `.compile` are machine-specific and git-ignored.

#### `No such module 'XCTest'` in `Speech2TextUITests`

The XCUITest target lives in its **own** scheme (`Speech2TextUITests`), kept out of the `Speech2Text` scheme's test action. So the `build-for-testing` command above — which builds the `Speech2Text` scheme — never compiles the UI-test files, and `.compile` ends up with **zero** arguments for them. SourceKit then can't resolve `XCTest` (its framework search path comes from those missing arguments), and reports `No such module 'XCTest'` on the `import XCTest` line.

**Fix** — build the UI-test scheme and **append** (`-a`) its arguments to the existing `.compile`, so the app and unit-test entries are preserved rather than overwritten:

```bash
# No CODE_SIGNING_ALLOWED=NO here — only running UI tests needs signing; building does not.
xcodebuild -project Speech2Text.xcodeproj -scheme Speech2TextUITests \
  -configuration Debug -destination 'platform=macOS' build-for-testing \
  > /tmp/s2t-uitest.log 2>&1 && xcode-build-server parse -a -o .compile /tmp/s2t-uitest.log
```

Then restart the LSP server as above. To confirm the module made it in: `python3 -c "import json; print(sorted({e['module_name'] for e in json.load(open('.compile'))}))"` should list `Speech2TextUITests` alongside `Speech2Text`, `Speech2TextTests`, and `Speech2TextIntegrationTests`.

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

See [.github/workflows/README.md](.github/workflows/README.md) for a per-workflow overview
(including the Claude automation) and its known limitations, and
[.claude/README.md](.claude/README.md) for the local Claude automation — commands, agents, and
the commit-guard hooks — and its caveats.

## License

Speech2Text is open source under the [MIT License](LICENSE) — you are free to
use, modify, and redistribute the source.

The official, ready-to-use build will be sold on the Mac App Store. Releasing
the source under MIT does not conflict with that: an open source license grants
rights to *others*, while the copyright holder retains full rights to the work,
including the right to sell binaries.

Third-party components and their licenses are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax (MIT)
- [OpenAI Whisper](https://github.com/openai/whisper)

See [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) for the full list of
third-party dependencies and their licenses.
