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

# Run a single SUITE — the finest granularity that works here (see caveat below).
# The path uses the struct name (TranscriptionLanguageTests), NOT the @Suite display name.
xcodebuild ... test -only-testing:Speech2TextTests/TranscriptionLanguageTests
```

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`) — not XCTest. Keep new tests in that style.

> **Subsetting tests is limited — `-only-testing` only resolves to the suite, not a single test.** With Swift Testing under `xcodebuild` here, `-only-testing:<Target>/<SuiteStruct>` works, but the single-test form `-only-testing:<Target>/<SuiteStruct>/<testFunc>` silently runs **0 tests** — even with a correct function name (verified against real functions in both `Speech2TextTests` and `Speech2TextIntegrationTests`). To focus on one test, run its whole suite, or run the full suite and `grep` the output. Relatedly, `xcbeautify` swallows parameterized `@Test(arguments:)` cases (they don't show individually and can look like the test never ran); pipe raw `xcodebuild` output through `grep` to confirm they executed.

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
   review marker, and commits. A direct `git commit` by the agent is blocked until
   that review has passed; on `main` it is blocked outright. **Commits you type in
   your own terminal are never intercepted** — hooks only see commands the agent runs.

Hooks in [.claude/settings.json](.claude/settings.json) enforce the branch and commit rules; the rest is on you. If a hook denies an action, the message tells you what to do next.

The commit guard ([.claude/hooks/commit-guard.sh](.claude/hooks/commit-guard.sh)) is a guardrail, not an adversarial sandbox. It reads the Bash command from the hook's stdin and acts only on a real `git commit` at a *command position* — the start of a line (matched per line, so newline-separated commands count) or right after a separator (`;`, `&`, `|`, `(`, or command substitution) — while leaving `git commit-tree`, `git committed`, quoted/echoed mentions of the words "git commit", and unrelated commands alone. For a matched agent commit it denies on `main`/`master`; refuses working-tree staging flags (`git commit -a`/`--all`/`--patch`/`--include`, which would record changes outside the reviewed index); and on a feature branch denies unless a review marker (`<git-dir>/precommit-review.ok`) equals the SHA-256 of the staged tree (`git diff --cached HEAD`). `/precommit` writes that marker after a clean final review, so the marker is invalidated by any later change to the staged tree — forcing a re-review. It is a guardrail because the marker attests *a review ran on this exact code*, not that the review was thorough. Known gaps: global options *between* `git` and `commit` (`git -c user.name=x commit`, `git -C <dir> commit`) and command wrappers (`time git commit`, `{ git commit; }`) aren't matched (would need full shell tokenization — env-var prefixes like `GIT_DIR=… git commit` *are* caught); brand-new files aren't part of the hash until staged; and a literal ` -a ` inside a commit message is conservatively refused.

## Automation helpers

Beyond the guard hooks, this repo carries optional automation. The local pieces
need no API key or subscription beyond your normal Claude Code session; the GitHub
pieces run on GitHub's runners.

- **Auto-regen hook** — a `PostToolUse` hook in [.claude/settings.json](.claude/settings.json)
  runs `xcodegen generate` automatically whenever `project.yml` is edited (workflow step 4).
- **`/check` command** — [.claude/commands/check.md](.claude/commands/check.md) builds then
  tests with the exact CI incantation (Debug, signing off). Pass `-only-testing:...` to scope it.
- **`/precommit` command** — [.claude/commands/precommit.md](.claude/commands/precommit.md) is the
  gated path for agent commits: it loops build+test → `code-review` → fix until clean (review
  effort defaults to `high`; `ultra` is intentionally excluded — it's a billed cloud review), then
  stages, marks, and commits. Enforced by [commit-guard.sh](.claude/hooks/commit-guard.sh).
- **`/fix-pr` command** — [.claude/commands/fix-pr.md](.claude/commands/fix-pr.md) addresses a PR's
  review findings **locally** (the on-your-Mac alternative to the `@claude fix` workflow): checks out
  the PR, reads its review comments, fixes them, then verifies + commits via `/precommit` and pushes.
- **Subagents** — [build-verifier](.claude/agents/build-verifier.md) owns the build→test→fix
  loop in its own context (keeps `xcodebuild` logs out of the main thread); [test-author](.claude/agents/test-author.md)
  writes the failing Swift Testing test first.
- **`@claude` bot** — [.github/workflows/claude.yml](.github/workflows/claude.yml) responds to
  `@claude` mentions on issues/PRs (excluding `@claude fix`, which the fixer handles). A cheap
  ubuntu **gate job** does the word-boundary match (so `@claude fixate`/negated mentions don't
  trigger) before the macOS job runs.
- **PR review + fix loop (human-in-the-loop)** — [claude-code-review.yml](.github/workflows/claude-code-review.yml)
  runs `/code-review --comment` (inline PR comments via the `github_inline_comment` MCP tool,
  which must stay in the step's `--allowedTools`) on every PR push; a new push cancels the stale
  in-flight review (`concurrency`). A **human maintainer** then comments `@claude fix` to invoke
  [claude-fix.yml](.github/workflows/claude-fix.yml), which in one macOS run applies the findings,
  builds + tests them (green gate — a broken fix is not pushed), pushes, and re-runs the review.
  It skips build/commit/re-review entirely when Claude made no edits, gates on the same boundary
  match as the bot, and accepts `@claude fix` from issue comments, inline review comments, or a
  review summary. The review bot itself can't trigger the fixer (`author_association` + GitHub's
  `GITHUB_TOKEN` loop-prevention block that by design). Build/test/re-review run inline, so no PAT
  is needed. The fixer commits via a workflow step, not a Claude tool call, so the local commit
  guard doesn't apply in CI.
- All bot workflows authenticate the model via the `CLAUDE_CODE_OAUTH_TOKEN` repo secret
  (subscription auth, not a pay-as-you-go API key — generate with `claude setup-token`).
- **WhisperKit drift check** — [.github/workflows/whisperkit-drift.yml](.github/workflows/whisperkit-drift.yml)
  runs weekly: re-resolves to the latest WhisperKit release within the pinned major, builds +
  tests, and opens a PR if still green or files an issue (mentioning `@claude`) if upstream drift
  broke the build. (A new major isn't picked up by `from:` — that needs a manual bump.) Because
  both are raised with the Actions `GITHUB_TOKEN`, the PR carries no status checks of its own (the
  build/test ran in the drift job) and the issue's `@claude` mention isn't auto-triggered — a
  maintainer re-runs CI / re-invokes `@claude`.

## Architecture

Three Swift files do all the real work; the UI is intentionally thin.

- [Speech2Text/TranscriptionManager.swift](Speech2Text/TranscriptionManager.swift) — the brain. `@MainActor @Observable` class holding all app state. Owns the `WhisperKit` instance, lazily (re)loads it when `selectedModel` changes, and drives a `TranscriptionStatus` state machine (`idle → loadingModel → transcribing(progress) → completed | error`). For video files it routes through `extractAudio(...)` which uses `AVAssetExportSession` to write a temp `.m4a` before handing the path to WhisperKit. Supported extensions are declared as `nonisolated static` sets on this type — the UI reads from these, so changes propagate everywhere.
- [Speech2Text/ContentView.swift](Speech2Text/ContentView.swift) — SwiftUI view that reads/writes `TranscriptionManager` state. No business logic; drag-and-drop, file picker, language/model pickers, and the result `TextEditor` all bind directly to the manager.
- [Speech2Text/Speech2TextApp.swift](Speech2Text/Speech2TextApp.swift) — app entry point.

**State flow** is one-way: UI mutates `selectedLanguage`/`selectedModel`/`droppedFileURLs`, calls `startTranscription()`, then renders from `status` + `transcriptionResult`. Don't add parallel state in views.

**WhisperKit models** are downloaded on first use into a per-user cache (not bundled). First run with a given model can be slow. `*.bin` and `*.mlmodelc` are gitignored.

**WhisperKit dependency** in `project.yml` tracks the latest release via `from: "1.0.0"` (SwiftPM up-to-next-major — newest `1.x` release, never a breaking `2.0`). Major bumps are manual; the weekly drift check covers `1.x` drift. Be aware when debugging upstream API drift.

## Platform constraints

- Swift 6 strict concurrency is on. `TranscriptionManager` is `@MainActor`; WhisperKit is imported `@preconcurrency`. New async code crossing the actor boundary needs to respect this.
- Deployment target is **macOS 26 (Tahoe)** — APIs like `AVAssetExportSession.export(to:as:)` and the `@Observable` macro require this. Don't lower without updating `project.yml` and regenerating.
- CI pins Xcode **26.4.1** on `macos-26` runners ([.github/workflows/](.github/workflows/) — `main.yml`, `feature.yml`, `release.yml` are near-identical, gated by branch pattern).
