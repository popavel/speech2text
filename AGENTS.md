# AGENTS.md

Shared guidance for AI coding assistants (Claude Code, GitHub Copilot, Codex, Cursor, etc.) working in this repository. Tool-specific entry points (`CLAUDE.md`, `.github/copilot-instructions.md`) are symlinks to this file, so there's one source of truth — edit `AGENTS.md` directly.

**This file is the contract: the commands, the workflow and the prohibitions you must follow before
you act.** The reasoning behind the code lives in [docs/](docs/) and is read on demand.

## Documentation map

| Doc | Read it when |
| --- | --- |
| [docs/README.md](docs/README.md) | You are about to write a comment — it holds the comment convention and the tripwire index. |
| [docs/architecture.md](docs/architecture.md) | Touching state flow, the model cache, persisted settings, scenes, or the help book. |
| [docs/concurrency.md](docs/concurrency.md) | Touching the stall watchdog, model loading, the removal paths, or anything that hops actors. |
| [docs/distribution.md](docs/distribution.md) | Touching `Updater.swift`, `Info.plist`'s `SU*` keys, or the release pipeline. |
| [docs/testing.md](docs/testing.md) | Writing or changing tests. |
| [docs/automation.md](docs/automation.md) | Touching `.github/workflows/` or `.claude/`. |
| [docs/build.md](docs/build.md) | Touching `project.yml` or the platform constraints. |

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

# Run a single SUITE — the finest granularity that works here (see caveat below).
# The path uses the struct name (TranscriptionLanguageTests), NOT the @Suite display name.
xcodebuild ... test -only-testing:Speech2TextTests/TranscriptionLanguageTests
```

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`) — not XCTest. Keep new tests in that style. **One exception:** `Speech2TextUITests` is an XCUITest target, and `XCUIApplication` lives only in XCTest, so those tests are `XCTestCase` subclasses. Don't "fix" them to Swift Testing — there is no Swift Testing equivalent for UI automation.

> **Subsetting tests is limited — `-only-testing` only resolves to the suite, not a single test.** With Swift Testing under `xcodebuild` here, `-only-testing:<Target>/<SuiteStruct>` works, but the single-test form `-only-testing:<Target>/<SuiteStruct>/<testFunc>` silently runs **0 tests** — even with a correct function name (verified against real functions in both `Speech2TextTests` and `Speech2TextIntegrationTests`). To focus on one test, run its whole suite, or run the full suite and `grep` the output. Relatedly, `xcbeautify` swallows parameterized `@Test(arguments:)` cases (they don't show individually and can look like the test never ran); pipe raw `xcodebuild` output through `grep` to confirm they executed.

The UI tests are **not** in that scheme and need their own run — and, unlike every other command
here, they must **not** get `CODE_SIGNING_ALLOWED=NO`, because an unsigned runner is killed before
it can attach:

```bash
xcodebuild -project Speech2Text.xcodeproj -scheme Speech2TextUITests \
  -destination 'platform=macOS' test | xcbeautify
```

**Never tap Transcribe in a UI test** — it loads WhisperKit and downloads a model. Seed state
through the `-uiTesting` launch seam instead; see [docs/testing.md](docs/testing.md).

## Workflow for code changes

Every code change follows this loop. Do not skip steps.

1. **Branch.** Create a feature branch off `main` before touching any file: `git checkout -b feature/<short-name>`. Editing on `main` is blocked by a hook (see below).
2. **Test first.** Add or update a Swift Testing test that exercises the behavior you're about to change. The test should fail for the right reason before you start implementing.
3. **Implement** the change in the source file.
4. **Regenerate** the Xcode project if `project.yml` changed: `xcodegen generate`.
5. **Build**, then **test** — using the commands in the "Common commands" section above.
6. **Fix the code, not the test.** If the build fails or any test fails, iterate on the implementation until both go green. Do not delete or weaken a failing test to make it pass. If a test is genuinely wrong, explain why before changing it.
7. **Commit via `/precommit`.** On a feature branch, the agent commits through the
   [`/precommit`](.claude/commands/precommit.md) command: it loops build+test → review → fix until
   the build is green and a `code-review` comes back clean, then stages, records a
   review marker, and commits. A direct commit by the agent is blocked until
   that review has passed; on `main` it is blocked outright. **Commits you type in
   your own terminal are never intercepted** — hooks only see commands the agent runs.

Hooks in [.claude/settings.json](.claude/settings.json) enforce the branch and commit rules; the rest is on you. If a hook denies an action, the message tells you what to do next.

The commit guard is a guardrail, not an adversarial sandbox: its marker attests *that a review ran
on this exact code*, not that the review was thorough. Its behaviour and its accepted gaps are
tabled in [docs/automation.md](docs/automation.md#the-commit-guard).

## Comment & documentation conventions

This is what keeps the prose from growing back into the code. Stated in full in
[docs/README.md](docs/README.md#the-comment-convention); in brief:

- **A rationale block of 3 lines or fewer stays in the code. 4 or more moves to a doc** and leaves a
  pointer.
- Declarations keep **one summary sentence** plus `Why: docs/<file>.md#<anchor>` — plain text, not a
  Markdown link, so it greps cleanly and resolves from any directory.
- **When you add rationale, add it to `docs/` and point at it** rather than growing the comment.
- Anchors are API: renaming a heading is a breaking change that must sweep the pointers with it.
- A warning stays **in the code** only if removing it would let a plausible edit build green *and*
  test green while breaking behaviour at runtime. Those are two lines maximum, start with
  `DO NOT` / `NEVER` / `MUST`, sit immediately above the tempting token, and get a row in the
  tripwire index.

## Repo tripwires

The prohibitions worth knowing before you touch the relevant code. Each has its argument at its
anchor; the full list, and the sweep that verifies it, is in
[docs/README.md](docs/README.md#tripwire-index).

- **Sparkle** — don't refuse the update *check* (guard the relaunch instead); don't collapse the
  three `SparkleUpdaterModel` initializers; don't delete the "unused" `controller`/`delegate`; never
  `MainActor.assumeIsolated` in a KVO handler; don't add a second observer on `.standard`; keep the
  `@objc` selector pin.
- **Watchdog** — don't rewrite `withStallWatchdog` as a `TaskGroup`; keep the clock suspending;
  latch the verdict before draining; **don't tighten `modelDownloadIdleTimeout`**.
- **Removal** — `deletion` must be set before the first suspension; clear settings through
  `UserDefaults`, never by deleting the plist; keep `performRemoval`'s `removal` `@MainActor`.
- **Cross-target** — `TranscriptionManager.uiTestingLaunchArgument` and the literal in
  `Speech2TextUITests.launchApp()` must match; only a UI-test run catches a mismatch.
- **Tests** — never construct a real `SPUUpdater`; don't "fix" the selector assertion to
  `#selector`; widen the watchdog flake budget rather than deleting the test it protects.
- **CI** — never re-add a Sparkle tarball download; re-check the concurrency key before enabling a
  `pull_request:` trigger; `SUFeedURL` is permanent.

## Distribution: the parts that are yours

Speech2Text ships one channel — a Developer ID-signed, notarized direct download that self-updates
via Sparkle. The whole argument is in [docs/distribution.md](docs/distribution.md); these are the
steps you perform:

- **Version lockstep.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live at project level in
  `project.yml` and are always bumped **together to the same `X.Y.Z`**. The publish workflow
  hard-fails when the pushed tag doesn't equal them. `0.x.y` is the pre-release series; `1.0.0` and
  above are reserved for the first genuinely user-facing release.
- **Release runbook.** Bump both versions → `/precommit` → PR → merge to `main` →
  `git tag vX.Y.Z && git push origin vX.Y.Z` → `publish-release.yml` runs → spot-check
  `curl -sL https://github.com/popavel/speech2text/releases/latest/download/appcast.xml`.
- **Never leave a release draft or prerelease.** The `latest` redirect skips both, so installed
  apps silently stop seeing updates.

## Verifying a WhisperKit bump

`loadModel(named:)` reassembles what `WhisperKit(model:downloadBase:)` does internally, and nothing
in the default test run constructs a WhisperKit. The drift job and `integration-whisperkit.yml` both
un-gate the end-to-end suite, so a pushed bump does get real evidence — but nothing asserts the
WhisperKit *internals* the watchdog is built on, so re-check
[docs/concurrency.md](docs/concurrency.md#upstream-facts-whisperkit-1x) on any bump. To run the
suite locally, note the gate needs the `TEST_RUNNER_`-prefixed variable as a real environment
variable — passing it as an `xcodebuild` build setting silently skips the suite:

```bash
TEST_RUNNER_RUN_WHISPERKIT_TESTS=1 xcodebuild -project Speech2Text.xcodeproj \
  -scheme Speech2Text -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test -only-testing:Speech2TextIntegrationTests/TranscriptionPipelineIntegrationTests | xcbeautify
```

## Platform constraints

- Swift 6 strict concurrency is on. `TranscriptionManager` is `@MainActor`; WhisperKit and Sparkle are imported `@preconcurrency`. New async code crossing the actor boundary needs to respect this — see [docs/concurrency.md](docs/concurrency.md).
- **Apple Silicon only.** `ARCHS: arm64` is pinned at project level, deliberately and before 1.0.0 shipped — see [docs/build.md](docs/build.md#arm64-only) for why reversing it gets hard once there is an installed base.
- Deployment target is **macOS 26 (Tahoe)** — a product decision rather than an API floor (the newest APIs used are available earlier). Don't lower without updating `project.yml`, regenerating, and auditing what stops compiling.
- CI pins Xcode **26.4.1** on `macos-26` runners.
