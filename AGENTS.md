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

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`) — not XCTest. Keep new tests in that style. **One exception:** `Speech2TextUITests` is an XCUITest target, and `XCUIApplication` lives only in XCTest, so those tests are `XCTestCase` subclasses. Don't "fix" them to Swift Testing — there is no Swift Testing equivalent for UI automation.

> **Subsetting tests is limited — `-only-testing` only resolves to the suite, not a single test.** With Swift Testing under `xcodebuild` here, `-only-testing:<Target>/<SuiteStruct>` works, but the single-test form `-only-testing:<Target>/<SuiteStruct>/<testFunc>` silently runs **0 tests** — even with a correct function name (verified against real functions in both `Speech2TextTests` and `Speech2TextIntegrationTests`). To focus on one test, run its whole suite, or run the full suite and `grep` the output. Relatedly, `xcbeautify` swallows parameterized `@Test(arguments:)` cases (they don't show individually and can look like the test never ran); pipe raw `xcodebuild` output through `grep` to confirm they executed.

### UI testing

There are two layers, deliberately split:

- **View-render tests (`Speech2TextTests/ContentViewTests.swift`)** — use [ViewInspector](https://github.com/nalexn/ViewInspector) (a **test-only** SwiftPM dependency, linked into `Speech2TextTests` only, **never** the app target) to assert the SwiftUI hierarchy reflects the injected `TranscriptionManager` state (button enabled/disabled, file chips, status/warning text). They are Swift Testing `@Suite`s, run in-process with **no signing/launch**, so they ride the normal `Speech2Text` scheme test run (including CI). `ContentView` has a single `init(manager:)` initializer — the app (`Speech2TextApp`), the `#Preview`, and this suite all inject the manager through it (there is no zero-arg `init()`). Inspect statically (build a fresh view per assertion) — don't reach for `ViewHosting`, which drags in XCTest machinery. Keep view *behavior* (clearFiles, removeFile) tested on the manager directly; ViewInspector covers render only.
- **XCUITest automation (`Speech2TextUITests`, `bundle.ui-testing`)** — launches the real app and queries controls by `.accessibilityIdentifier(...)`. Run via its **own** scheme, which is kept out of the `Speech2Text` scheme's test action so its flakiness can't gate every build:

  ```bash
  # NOTE: no CODE_SIGNING_ALLOWED=NO here — see below.
  xcodebuild -project Speech2Text.xcodeproj -scheme Speech2TextUITests \
    -destination 'platform=macOS' test | xcbeautify
  ```

  Three things to know:
  1. **Signing is required.** Unlike every other command in this repo, UI tests must **not** pass `CODE_SIGNING_ALLOWED=NO` — an unsigned test runner is killed before it can attach (`Test crashed with signal kill before establishing connection`). Let Xcode apply its default (ad-hoc) signature.
  2. **Never tap Transcribe.** It calls `startTranscription()` → loads WhisperKit (network, model download). UI tests seed state instead via a `#if DEBUG` launch seam on `TranscriptionManager` (`applyUITestSeamIfPresent`, called from `Speech2TextApp.init()`): launch with `-uiTesting`, then `UITEST_PRELOAD_FILES` (newline-joined paths — extension-filtered, never stat'd, so synthetic `/tmp/x.mp3` works) preloads the queue and `UITEST_STUB_RESULT` stubs a completed transcription so the result UI is reachable without a model. The seam is compiled out of Release.
  3. **Runs in CI as a gated job.** [.github/workflows/ui-tests.yml](.github/workflows/ui-tests.yml) is now a reusable (`workflow_call`) workflow called by the feature/main/release pipelines with `needs: build-and-test` — a signed `macos-26` runner only spins up once the cheap build+test job is green. (It stays `workflow_dispatch`-able for manual runs.) This was held back as manual-only until a green dispatch run proved XCUITest works on `macos-26`; that run passed, so it was wired in. Note the signed runner means a flaky UI run can turn the whole pipeline red — see the scheme isolation note above for why UI tests are still kept out of the `Speech2Text` scheme's own test action.

  The app's [Info.plist](Info.plist) carries an explicit `CFBundleIdentifier` (`$(PRODUCT_BUNDLE_IDENTIFIER)`) — XCUITest needs it to identify the target app, and the manual `INFOPLIST_FILE` (no `GENERATE_INFOPLIST_FILE`) wouldn't otherwise inject one.

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
- **Dependency drift check** — [.github/workflows/dependency-drift.yml](.github/workflows/dependency-drift.yml)
  runs weekly: drops `Package.resolved` and re-resolves the whole SwiftPM graph (WhisperKit,
  ViewInspector, and transitives like swift-argument-parser) to the latest release each `from:`
  allows, builds + tests, and opens a PR (listing which pins moved) if still green or files an
  issue (mentioning `@claude`) if upstream drift broke the build. (A new *major* of any dependency
  isn't picked up by `from:` — that needs a manual bump.) Because both are raised with the Actions
  `GITHUB_TOKEN`, the PR carries no status checks of its own (the build/test ran in the drift job)
  and the issue's `@claude` mention isn't auto-triggered. **A `workflow_dispatch` does not reliably
  attach to the PR head** — unblock the checks by pushing one *human* commit to the branch
  (`--allow-empty` is enough), which fires `feature.yml`'s push trigger on the new head SHA; and
  re-invoke `@claude` by hand on the issue.

## Architecture

A handful of Swift files do all the real work; the UI is intentionally thin.

- [Speech2Text/TranscriptionManager.swift](Speech2Text/TranscriptionManager.swift) — the brain. `@MainActor @Observable` class holding all app state. Owns the `WhisperKit` instance, lazily (re)loads it when `selectedModel` changes, and drives a `TranscriptionStatus` state machine (`idle → loadingModel → transcribing(progress) → completed | error`). For video files it routes through `extractAudio(...)` which uses `AVAssetExportSession` to write a temp `.m4a` before handing the path to WhisperKit. Supported extensions are declared as `nonisolated static` sets on this type — the UI reads from these, so changes propagate everywhere.
- [Speech2Text/ContentView.swift](Speech2Text/ContentView.swift) — SwiftUI view that reads/writes `TranscriptionManager` state. No business logic; drag-and-drop, file picker, language/model pickers, and the result `TextEditor` all bind directly to the manager.
- [Speech2Text/Speech2TextApp.swift](Speech2Text/Speech2TextApp.swift) — app entry point.
- [Speech2Text/Updater.swift](Speech2Text/Updater.swift) — the Sparkle auto-update seam (see "Distribution & updates" below). Views depend on the `UpdaterModel` protocol, never on Sparkle.
- [Speech2Text/ModelDownloadWatchdog.swift](Speech2Text/ModelDownloadWatchdog.swift) — `withStallWatchdog`, which bounds the two phases of model loading so a wedged download can't pin `isProcessing` forever (`loadModel(named:)` is its only caller). Small but concurrency-heavy: it deliberately abandons rather than awaits a stalled operation, so read its doc comment before changing it — a structured `TaskGroup` rewrite reintroduces the exact hang it prevents. Why it must exist at all is in "Distribution & updates" below.

**State flow** is one-way: UI mutates `selectedLanguage`/`selectedModel`/`droppedFileURLs`, calls `startTranscription()`, then renders from `status` + `transcriptionResult`. Don't add parallel state in views.

**WhisperKit models** are downloaded on first use (not bundled); first run with a given model can be slow, and `*.bin`/`*.mlmodelc` are gitignored. The download location is overridden via WhisperKit's `downloadBase:` to the app-owned `~/Library/Application Support/com.speech2text.app/models` (see `TranscriptionManager.modelCacheDirectory`) — *not* WhisperKit's default `~/Documents/huggingface`, which would dump gigabytes into the user's Documents. `TranscriptionManager` exposes `currentCacheSize()`/`deleteAllModels()` (the heavy filesystem walk runs off the `@MainActor`), and the `Settings` scene (`SettingsView` in `ContentView.swift`) lets users delete that cache — the in-app half of a graceful uninstall.

**WhisperKit dependency** in `project.yml` tracks the latest release via `from: "1.0.0"` (SwiftPM up-to-next-major — newest `1.x` release, never a breaking `2.0`). Major bumps are manual; the weekly drift check covers `1.x` drift. Be aware when debugging upstream API drift.

> **`loadModel(named:)` reassembles what `WhisperKit(model:downloadBase:)` does internally** (download → `modelFolder` → `loadModels()`), and *nothing in the default test run constructs a WhisperKit* — that path lives only in the opt-in `Speech2TextIntegrationTests`. A 1.x release that changed those semantics would compile cleanly and fail on first model load for every user. Two jobs close that gap: the weekly drift job un-gates the suite itself (`TEST_RUNNER_RUN_WHISPERKIT_TESTS=1`), and `integration-whisperkit.yml` runs it on every feature/main/release pipeline — so a manual bump pushed to a branch gets the same end-to-end evidence a drift PR does. What no job does is *propose* a major bump (`from:` never crosses a major), and nothing asserts the WhisperKit internals `withStallWatchdog` is built on. On any bump, re-check those (docs/concurrency.md, "Upstream facts") and run the suite yourself if you want it locally — note the gate needs the `TEST_RUNNER_`-prefixed variable as a real environment variable, since passing it as an `xcodebuild` build setting silently skips the suite:
>
> ```bash
> TEST_RUNNER_RUN_WHISPERKIT_TESTS=1 xcodebuild -project Speech2Text.xcodeproj \
>   -scheme Speech2Text -destination 'platform=macOS' \
>   CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
>   test -only-testing:Speech2TextIntegrationTests/TranscriptionPipelineIntegrationTests | xcbeautify
> ```

## Distribution & updates

Speech2Text ships through **one channel**: a direct download from
[GitHub Releases](https://github.com/popavel/speech2text/releases) and the project website,
Developer ID-signed, hardened-runtime, notarized and stapled, self-updating via **Sparkle 2**
against an EdDSA-signed appcast. There is deliberately no Mac App Store build, and therefore no
second app target, no sandboxing (`Speech2Text.entitlements` sets `com.apple.security.app-sandbox`
to `<false/>`; the publish workflow reads that key off the product and fails only on an explicit
`true`), and no `SPARKLE_ENABLED` compile condition — Sparkle
compiles unconditionally because nothing has to be built without it. (An earlier, unmerged
experiment carried a dual-channel setup; going App-Store-free is what makes all that scaffolding
unnecessary. Don't reintroduce it without a channel that needs it.)

Things that keep this sane — don't undo them:

- **[Updater.swift](Speech2Text/Updater.swift) seam.** Views depend on the `UpdaterModel`
  protocol, never on Sparkle. `SparkleUpdaterModel` has **three initializers** on purpose: the
  production `init(startingUpdater:)` is the only one that *constructs* a Sparkle object; the test
  door `init(updater:)` names no Sparkle type at all, so it structurally cannot bring an
  `SPUUpdater`/`SUHost` into existence; and one private designated init holds everything
  downstream of "which driver do I have", so the injected path and the shipping path execute the
  same lines. Don't collapse them — the guarantee then moves from the compiler to branch ordering.
- **Never construct a real `SPUUpdater` in tests** — started or not. It binds an `SUHost` to the
  app's `.standard` defaults domain, which the in-process test host shares with the developer's
  real installed app. Unit tests run *inside* the app here (test host = the app, so
  `Speech2TextApp.init` executes on every test run).
- **Only Release builds update.** `SparkleUpdaterModel.shouldStartUpdater()` returns false for
  **any Debug build** — a `⌘R` run is not a shipped app, and starting Sparkle there writes
  `SULastCheckTime` and friends into the real `com.speech2text.app` defaults domain; worse, a
  working tree's `CURRENT_PROJECT_VERSION` trails the published feed head, so Sparkle would
  eventually offer to replace the DerivedData build with a download. The `-uiTesting` and XCTest
  marker checks sit behind that as belt-and-braces for a suite run against Release. `isDebugBuild`
  is an injectable parameter rather than a `#if` in the body, so
  [UpdaterTests.swift](Speech2TextTests/UpdaterTests.swift) can test **both** answers from a test
  run that is itself always Debug — including the one combination that ships.
- **`automaticallyChecksForUpdates` is explicit storage + write-through, NOT a `didSet` mirror** —
  under `@Observable`, init-time assignment runs the setter, which would write
  `SUEnableAutomaticChecks` into the shared domain during the test host's app init. A KVO
  observation mirrors Sparkle-side writes back so the Settings toggle can't go stale — scoped to
  writes *through the property* (Sparkle's own permission UI). An external `defaults write` of the
  underlying `SUEnableAutomaticChecks` key converges on that same property KVO through Sparkle
  itself (since 2.8.0: `SUHost` observes the defaults domain → `SPUUpdaterSettings` posts an
  explicit change → `keyPathsForValuesAffecting…` propagates it), so never add a second observer on
  the shared defaults domain to "close" it. That leg is upstream implementation, untested here.
- **Both KVO mirrors seed by direct read and re-read on change — never `MainActor.assumeIsolated`.**
  Of the `SPUUpdater` properties this model touches, `canCheckForUpdates` is the one Sparkle's
  header does *not* document as main-thread-only (`automaticallyChecksForUpdates`,
  `automaticallyDownloadsUpdates` and `updateCheckInterval` all say "must be called on the main
  thread"; it doesn't). `assumeIsolated` on an off-main delivery would **trap and kill the shipped
  app**, and no test could catch it because a fake only ever mutates on the main actor. So both
  observations hop with `Task { @MainActor }` and re-read the live value on arrival — which also
  means an out-of-order hop can't apply a stale value.
- **The update RELAUNCH is postponed while the app is busy — not the check.** `UpdaterDelegate`
  implements `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`, deferring the
  install until `isProcessing`/`isRemovingData` clears, because relaunching mid-run destroys an
  in-memory transcript and relaunching mid-wipe leaves a half-deleted cache. **Don't "improve"
  this by refusing the check** (`updater(_:mayPerform:)`) instead: Sparkle records a refused check
  as a completed one (`abortUpdateDriver` calls `updateLastUpdateCheckDate`, rescheduling with
  `usingCurrentDate:NO`), so a user who happens to be transcribing at check time has updates
  pushed a further ~24h out every time — and it still wouldn't cover the real hazard, an alert
  raised while idle and accepted seconds after work starts. Note the selector's Swift label is
  `untilInvokingBlock:`; `untilInvoking:` compiles cleanly, only "nearly matches" the optional
  requirement, and is never called. The delegate is held strongly by the model
  (`SPUStandardUpdaterController` keeps it weakly).

  **It is a mitigation, not a guarantee.** Sparkle's own header says the hook is skipped when the
  user declined to relaunch on a previous update (it restarts immediately) and may be skipped when
  the app isn't going to relaunch at all. A user in either state who accepts an update
  mid-transcription still loses the in-memory transcript. The real fix is to stop treating the
  transcript as unrecoverable — persist it, or warn before discarding it — which would also cover
  the plain quit case that already loses it today. Not done here.

  **The postpone loop's liveness rests on the busy flag being bounded.** If `isBusy()` never
  cleared, `installHandler()` would never fire — and Sparkle installs nothing at termination, so
  the update would be lost *and* the still-open session would hold `canCheckForUpdates` false for
  the life of the process (no manual retry either). That is why both halves of model loading are
  bounded: `TranscriptionManager.modelDownloadIdleTimeout` fails a *download* that reports no
  progress for half an hour (a stall watchdog, not a deadline — a slow-but-progressing download is
  never killed, so don't "simplify" it into a wall clock, and **don't tighten the window**: Hub
  reports progress only per 10 MB chunk, so the window is a throughput floor, and a link below it
  is not just failed but permanently stuck — read the constant's comment before touching it), and
  `modelLoadCeiling` puts a half-hour ceiling on `loadModels()`, which reports nothing to watch but
  is **not** purely local: it fetches the tokenizer from the Hub on first run, so it can wedge on
  the network too.

  **Only model loading is bounded.** `isProcessing` is also true while transcribing, and that path
  is unwatched: `extractAudio` awaits `AVAssetExportSession` on the user's file, which is ordinarily
  local compute but is not immune — an input on a network or removable volume that goes away
  mid-export can hang, and a hang there strands an update exactly as described above. Bounding it
  needs a different mechanism (export publishes progress, and the legitimate duration is the length
  of the user's audio), so it is knowingly left open rather than papered over.
- **Sparkle owns its preferences** (`SUEnableAutomaticChecks`, `SULastCheckTime`, …) in the app's
  defaults domain, deliberately **outside** `TranscriptionManager.Keys.all` — so "Remove All App
  Data" and "Restore Default Settings" leave them alone.
- **Every channel fact is checked on the ARTIFACT, not only the source.** A source guard proves
  what the repo says; only a product-level one proves what ships. `publish-release.yml` re-reads
  the built bundle's versions, hardened-runtime flag, sandbox state, embedded `Sparkle.framework`,
  and `SUFeedURL`/`SUPublicEDKey` — because a build that silently lost its feed URL launches
  clean, never updates, and becomes the permanent feed head.
- **Version lockstep.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live at **project level**
  in [project.yml](project.yml) and are always bumped **together to the same `X.Y.Z`** (Sparkle
  orders by `CFBundleVersion`; `AboutView` collapses the display when build == short). The publish
  workflow hard-fails when the pushed tag doesn't equal them. **`0.x.y` is the pre-release series;
  `1.0.0` and above are reserved for the first genuinely user-facing release.**
- **Sparkle version skew is impossible by construction**: `publish-release.yml` runs
  `generate_appcast` straight out of the resolved SwiftPM package store
  (`DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`) — Sparkle ships its CLI tools
  inside the same zip the framework comes from, which SwiftPM fetches for a
  `binaryTarget(checksum:)` and rejects on a SHA-256 mismatch. So the tool that receives the EdDSA
  private key is the exact artifact the app embeds, integrity-checked. **Never re-download it** —
  Sparkle's release tarballs are ad-hoc signed, so a download can't be verified and would hand a
  signing secret to unauthenticated code.
- **The ZIP and the DMG live in separate directories.** `generate_appcast` treats *every archive
  in its input directory* as an update entry, so `artifacts/` holds only the Sparkle zip (and the
  appcast); the DMG goes to `dist/` and the dSYMs to `dsyms/`.

**Release runbook:** bump both versions in `project.yml` → `/precommit` → PR → merge to `main` →
`git tag vX.Y.Z && git push origin vX.Y.Z` → `publish-release.yml` runs (build+test gate as a
separate `needs:` job first, then preflight, xcodegen, cert import, Release build, verify product,
notarize, staple, zip, DMG, dSYMs, appcast, draft release, publish) →
spot-check `curl -sL https://github.com/popavel/speech2text/releases/latest/download/appcast.xml`.
The workflow uploads assets onto a *draft* release and flips it to published only once complete
(so the `latest` feed never sees a half-uploaded release) — but **never leave a release
draft/prerelease**: the `latest` redirect skips those and installed apps silently stop seeing
updates. A late step guarded by `always() && steps.create_draft.outcome != 'skipped'` alarms if that happens.

**One-time secrets** (all already set on the repo): `SPARKLE_ED_PRIVATE_KEY` (from Sparkle's
`generate_keys -x`; the public half is `SUPublicEDKey` in [Info.plist](Info.plist) — losing the
private key strands every installed copy, keep the Keychain + secret copies),
`DEVID_CERT_P12_BASE64`/`DEVID_CERT_PASSWORD` (Developer ID Application cert), `APPLE_TEAM_ID`,
and `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_API_KEY_P8` (App Store Connect API key — still needed with
no App Store channel, because `notarytool` authenticates with it).

## Platform constraints

- Swift 6 strict concurrency is on. `TranscriptionManager` is `@MainActor`; WhisperKit and Sparkle are imported `@preconcurrency`. New async code crossing the actor boundary needs to respect this.
- **Apple Silicon only.** `ARCHS: arm64` is pinned at project level in [project.yml](project.yml) rather than left to Xcode's `ARCHS_STANDARD` (which would add an x86_64 slice). macOS 26 is the last release supporting Intel and reaches only a handful of 2019–20 models, none with a Neural Engine — and this app *is* local Whisper inference. Chosen before 1.0.0 shipped on purpose: once a universal build has an installed base, Sparkle's appcast has no clean way to stop offering an arm64-only update to an Intel user.
- **Signing settings live on the `xcodebuild` command line, not in `project.yml`.** `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM` and `ENABLE_HARDENED_RUNTIME` are injected by `publish-release.yml` alone, so local development and every `CODE_SIGNING_ALLOWED=NO` CI build stay untouched by the release configuration.
- Deployment target is **macOS 26 (Tahoe)** — APIs like `AVAssetExportSession.export(to:as:)` and the `@Observable` macro require this. Don't lower without updating `project.yml` and regenerating.
- CI pins Xcode **26.4.1** on `macos-26` runners ([.github/workflows/](.github/workflows/) — `main.yml`, `feature.yml`, `release.yml` are near-identical, gated by branch pattern).
