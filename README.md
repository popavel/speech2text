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
- **Video support** — automatically extracts audio from `mp4`, `mov`, `m4v`
- **100% offline transcription** — audio never leaves your machine; models run on-device via Core ML. The app reaches the network only to download a Whisper model the first time you use it and to check for updates (turn that off in **Settings → Updates**).
- **Batch transcription** of multiple files at once

## Supported Formats

**Audio:** `mp3`, `wav`, `m4a`, `flac`, `aac`, `ogg`, `aiff`, `caf`

**Video:** `mp4`, `mov`, `m4v`

## Requirements

**To run the app:**
- macOS 26 (Tahoe) or later
- Apple Silicon required — the app ships as an arm64-only build (Whisper models run on the Neural Engine / GPU)

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

## Installing & updates

Download `Speech2Text-X.Y.Z.dmg` from the
[Releases page](https://github.com/popavel/speech2text/releases), open it, and drag
`Speech2Text.app` into `/Applications`. Releases are Developer ID-signed and notarized, so
Gatekeeper opens them without ceremony — no right-click-Open, no `xattr` incantation.

The app keeps itself up to date with [Sparkle](https://sparkle-project.org): it checks for new
versions about once a day (opt out in **Settings → Updates**), and you can check any time with
**Speech2Text → Check for Updates…**. Every update's EdDSA signature is verified before it is
installed.

> A `.zip` of the same build is attached to each release — that is the archive Sparkle downloads
> for updates. The `.dmg` is the one to grab for a first install.

The maintainer release process — version bumps, tagging, and the publish workflow — is documented
in [AGENTS.md](AGENTS.md) ("Distribution & updates").

## Uninstalling

macOS has no uninstaller hook — an app can't run cleanup code once it's been dragged to the Trash — so removing Speech2Text is two steps:

1. **Reclaim the model cache.** Downloaded Whisper models can be several GB. The easiest way to remove them is in-app, *before* deleting the app: open **Settings (⌘,) → Storage → Delete Downloaded Models**.
2. **Trash the app.** Quit Speech2Text and move **Speech2Text.app** to the Trash.

If you skip step 1, delete the cache folder by hand:

```
~/Library/Application Support/com.speech2text.app/
```

That folder holds the only data worth reclaiming — the downloaded models, which can be several GB. macOS itself also keeps a few small, system-managed files for the app (each typically a few MB): a window-position preference and the URLSession caches created while downloading models. To remove every last trace, also delete:

```
~/Library/Preferences/com.speech2text.app.plist
~/Library/Caches/com.speech2text.app/
~/Library/HTTPStorages/com.speech2text.app/
```

Being non-sandboxed, Speech2Text writes nothing under `~/Library/Containers/`.

## Project Structure

```
Speech2Text/
├── Speech2TextApp.swift        # App entry point (scenes, menu commands)
├── ContentView.swift           # SwiftUI UI (incl. SettingsView)
├── TranscriptionManager.swift  # WhisperKit integration & audio extraction
├── Updater.swift               # Sparkle auto-update seam
├── ModelDownloadWatchdog.swift # Stall watchdog bounding model download/load
├── AboutView.swift             # About panel window
├── HelpView.swift              # In-app help book (incl. the uninstall guide)
└── speech2text.icon            # App icon (Icon Composer package)
project.yml                     # XcodeGen config — targets, packages, versions
Info.plist                      # Bundle keys + Sparkle SU* keys
Speech2Text.entitlements        # Not sandboxed
.github/workflows/              # CI + the release pipeline
docs/                           # Design rationale — see below
```

## Documentation

Deep rationale for how and why the code is shaped the way it is lives in [docs/](docs/):

| Doc | Covers |
| --- | --- |
| [docs/README.md](docs/README.md) | Index, the comment convention the code follows, and the tripwire list |
| [docs/architecture.md](docs/architecture.md) | State flow, the model cache, scenes and menu commands, the help book's derived facts |
| [docs/concurrency.md](docs/concurrency.md) | The stall watchdog, the model-loading bounds, the removal contract, Swift 6 actor hops |
| [docs/distribution.md](docs/distribution.md) | The Sparkle seam and the release pipeline, including the release runbook |
| [docs/testing.md](docs/testing.md) | Test conventions, the XCUITest exception, hermetic DI, per-suite charters |
| [docs/automation.md](docs/automation.md) | CI workflows, the Claude bot loops, the commit guard, and their known limitations |
| [docs/build.md](docs/build.md) | XcodeGen decisions, platform constraints, `Info.plist` keys |

[AGENTS.md](AGENTS.md) is the contract for AI coding assistants — commands, workflow and
prohibitions; `docs/` is the reference behind it.

## CI

GitHub Actions workflows live in `.github/workflows/`:

- `release.yml` — runs on `release/**` branches
- `main.yml` — builds & tests on pushes to `main` (push-only; see [docs/automation.md](docs/automation.md#push-only-deliberately-no-pull_request-trigger))
- `feature.yml` — runs on `feature/**` and `chore/**` branches
- `publish-release.yml` — on a `vX.Y.Z` tag: notarized DMG + ZIP + Sparkle appcast → GitHub Release

The first three are thin callers of the shared `build-and-test.yml` job (Xcode 26.4.1 on a
`macos-26` runner), and each also calls the integration and UI-test jobs once that is green;
`publish-release.yml` gates on the same build/test job before it signs anything.

[.github/workflows/README.md](.github/workflows/README.md) and
[.claude/README.md](.claude/README.md) list what runs when;
[docs/automation.md](docs/automation.md) explains how it fits together and tables the known
limitations of both the CI automation and the local commit guard.

## License

Speech2Text is open source under the [MIT License](LICENSE) — you are free to
use, modify, and redistribute the source.

Official, ready-to-use builds are distributed directly — Developer ID-signed and
notarized — from the [Releases page](https://github.com/popavel/speech2text/releases)
and the project website. Releasing the source under MIT does not constrain how
those builds are distributed: an open source license grants rights to *others*,
while the copyright holder retains full rights to the work.

Third-party components and their licenses are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax (MIT)
- [OpenAI Whisper](https://github.com/openai/whisper)

See [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) for the full list of
third-party dependencies and their licenses.
