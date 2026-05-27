# AGENTS.md

Shared guidance for AI coding assistants (Claude Code, GitHub Copilot, Codex, Cursor, etc.) working in this repository. Tool-specific entry points (`CLAUDE.md`, `.github/copilot-instructions.md`) are symlinks to this file, so there's one source of truth — edit `AGENTS.md` directly.

## Project generation

The `.xcodeproj` is **generated** from [project.yml](project.yml) by XcodeGen. Most of the bundle is gitignored, but a few generated files are checked in (`project.pbxproj`, the shared `xcshareddata/` schemes, `project.xcworkspace/contents.xcworkspacedata`, and `Package.resolved`) so the project opens and resolves packages without regenerating. After editing `project.yml` (sources, targets, dependencies, build settings), regenerate before building:

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

## Workflow for code changes

Every code change follows this loop. Do not skip steps.

1. **Branch.** Create a feature branch off `main` before touching any file: `git checkout -b feature/<short-name>`. Editing on `main` is blocked by a hook (see below).
2. **Test first.** Add or update a Swift Testing test that exercises the behavior you're about to change. The test should fail for the right reason before you start implementing.
3. **Implement** the change in the source file.
4. **Regenerate** the Xcode project if `project.yml` changed: `xcodegen generate`.
5. **Build**, then **test** — using the commands in the "Common commands" section above.
6. **Fix the code, not the test.** If the build fails or any test fails, iterate on the implementation until both go green. Do not delete or weaken a failing test to make it pass. If a test is genuinely wrong, explain why before changing it.
7. **Hand off, don't commit.** When build + tests are green, summarize the changed files and stop. The human reviews and runs `git commit` themselves — `git commit` is blocked by a hook.

Two hooks in [.claude/settings.json](.claude/settings.json) enforce the branch and commit rules; the rest is on you. If a hook denies an action, the message tells you what to do next.

The commit guard is a guardrail, not an adversarial sandbox: it reads the Bash command from the hook's stdin and denies `git commit` at a word boundary — including when followed by `;`, `|`, `&`, `>`, or end-of-line — while leaving `git commit-tree`, `git committed`, and unrelated commands alone. It deliberately does **not** use the hook `if:` filter, because that over-matches any command containing `$VAR` or command substitution and would deny innocent commands. Known gap: global options *between* `git` and `commit` (e.g. `git -c user.name=x commit`) are not caught — matching those reliably would need full shell tokenization.

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
