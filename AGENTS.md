# AGENTS.md

Shared guidance for AI coding assistants (Claude Code, GitHub Copilot, Codex, Cursor, etc.) working in this repository. Tool-specific entry points (`CLAUDE.md`, `.github/copilot-instructions.md`) point here so there's one source of truth.

## Project generation

The `.xcodeproj` is **generated** from [project.yml](project.yml) by XcodeGen and is gitignored. After editing `project.yml` (sources, targets, dependencies, build settings), regenerate before building:

```bash
xcodegen generate
```

If the project file is missing or out of date, no other command will work — start here.

## Common commands

```bash
# Build (Debug, no code signing — matches CI)
xcodebuild -project Speech2Text.xcodeproj -scheme Speech2Text \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | xcbeautify

# Run the full test suite
xcodebuild -project Speech2Text.xcodeproj -scheme Speech2Text \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test | xcbeautify

# Run a single test or suite (Swift Testing uses -only-testing:<Target>/<SuiteName>/<testFunc>)
xcodebuild ... test -only-testing:Speech2TextTests/TranscriptionLanguageTests
xcodebuild ... test -only-testing:Speech2TextTests/TranscriptionLanguageTests/displayNamesAreNonEmpty
```

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`) — not XCTest. Keep new tests in that style.

## Architecture

Three Swift files do all the real work; the UI is intentionally thin.

- [Speech2Text/TranscriptionManager.swift](Speech2Text/TranscriptionManager.swift) — the brain. `@MainActor @Observable` class holding all app state. Owns the `WhisperKit` instance, lazily (re)loads it when `selectedModel` changes, and drives a `TranscriptionStatus` state machine (`idle → loadingModel → transcribing(progress) → completed | error`). For video files it routes through `extractAudio(...)` which uses `AVAssetExportSession` to write a temp `.m4a` before handing the path to WhisperKit. Supported extensions are declared as `nonisolated static` sets on this type — the UI reads from these, so changes propagate everywhere.
- [Speech2Text/ContentView.swift](Speech2Text/ContentView.swift) — SwiftUI view that reads/writes `TranscriptionManager` state. No business logic; drag-and-drop, file picker, language/model pickers, and the result `TextEditor` all bind directly to the manager.
- [Speech2Text/Speech2TextApp.swift](Speech2Text/Speech2TextApp.swift) — app entry point.

**State flow** is one-way: UI mutates `selectedLanguage`/`selectedModel`/`droppedFileURLs`, calls `startTranscription()`, then renders from `status` + `transcriptionResult`. Don't add parallel state in views.

**WhisperKit models** are downloaded on first use into a per-user cache (not bundled). First run with a given model can be slow. `*.bin` and `*.mlmodelc` are gitignored.

**WhisperKit dependency** in `project.yml` tracks `branch: main` (not a pinned version). Be aware when debugging upstream API drift.

## Platform constraints

- Swift 6 strict concurrency is on. `TranscriptionManager` is `@MainActor`; WhisperKit is imported `@preconcurrency`. New async code crossing the actor boundary needs to respect this.
- Deployment target is **macOS 26 (Tahoe)** — APIs like `AVAssetExportSession.export(to:as:)` and the `@Observable` macro require this. Don't lower without updating `project.yml` and regenerating.
- CI pins Xcode **26.4.1** on `macos-26` runners ([.github/workflows/](.github/workflows/) — `main.yml`, `feature.yml`, `release.yml` are near-identical, gated by branch pattern).
