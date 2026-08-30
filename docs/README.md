# Speech2Text documentation

Deep rationale for the code lives here rather than in the source files. Code carries a
one-sentence summary and a pointer; this folder carries the argument.

Linked from the root [README.md](../README.md#documentation).

> **Migration in progress.** This folder was written first, from the comments it consolidates, so
> the prose could be reviewed against its source side by side. `Speech2Text/` has since been
> trimmed, as have the heaviest files in the three test targets, the shared fixtures,
> `.github/workflows/`, `.claude/`, `project.yml` and `Info.plist`; the two folder READMEs are now
> stubs pointing here. Still to come: `SettingsPersistenceTests`, `DecodingParametersTests`,
> `TranscriptionManagerTests`, `AudioExtractionIntegrationTests` and `MediaFixtures` (all already
> under 16% and carrying no essays), and slimming `AGENTS.md`.

[AGENTS.md](../AGENTS.md) is the *contract* — the commands, the workflow, and the prohibitions an
agent must follow before it acts. This folder is the *reference* — what a maintainer reads when
they reach the relevant code and want to know why it is shaped that way.

## Map

| Doc | Owns | Backs |
| --- | --- | --- |
| [architecture.md](architecture.md) | One-way state flow, the model cache, persisted settings, the app's scenes and menu commands, the Settings scene, the help book's derived facts | `TranscriptionManager.swift`, `ContentView.swift`, `Speech2TextApp.swift`, `HelpView.swift`, `AboutView.swift` |
| [concurrency.md](concurrency.md) | The stall watchdog, the two model-loading bounds, the cache-walk ownership scheme, the Swift 6 actor-hop hazards | `ModelDownloadWatchdog.swift`, `TranscriptionManager.swift` (`loadModel`), `ContentView.swift` (`refreshSize`), `StallWatchdogTests.swift` |
| [distribution.md](distribution.md) | The Sparkle seam and the release pipeline — one topic, one file | `Updater.swift`, `UpdaterTests.swift`, `Info.plist`, `publish-release.yml` |
| [testing.md](testing.md) | Test conventions, the XCUITest exception, hermetic DI, the cross-target contract, per-suite charters | the three test targets and `Speech2TextTestSupport/` |
| [automation.md](automation.md) | CI workflows, the Claude bot loops, the commit guard, and their known limitations | `.github/workflows/`, `.claude/` |
| [build.md](build.md) | XcodeGen decisions, platform constraints, `Info.plist` keys | `project.yml`, `Info.plist` |

## The comment convention

This is what keeps the prose from growing back into the code. It is stated once, here, so reviews
have something to judge against.

### The 4-line threshold

A rationale block of **3 lines or fewer stays in the code**. A block of **4 lines or more moves to
a doc** and leaves a pointer. That is the whole decision procedure. Small local notes are not the
problem; essays are.

### What a doc comment looks like after the pass

```swift
/// <one sentence, ends with a period>
/// Why: docs/<file>.md#<anchor>
/// - Parameters:
///   - x: <one line — contract only, no rationale>
```

- **One summary sentence.** If it needs a second paragraph, it needs a doc anchor.
- **Parameter docs stay** — they are API contract — trimmed to one line each.
- The pointer sits **inside** the `///` block on a declaration, so it shows in Quick Help.

### The pointer form

```
/// Why: docs/concurrency.md#stall-watchdog      ← declarations
// Why: docs/concurrency.md#stall-watchdog       ← file headers, statement level
# Why: docs/automation.md#the-commit-guard           ← YAML, shell
<!-- Why: docs/build.md#infoplist-keys -->      ← Info.plist
```

Fixed prefix `Why: ` when it justifies, `See: ` when it merely informs. **Plain text,
repo-root-relative, no Markdown link syntax** — a relative link from a Swift file has no base URL
in Quick Help or on GitHub, and plain text is greppable with one regex from any directory.

One pointer per *idea*: a summary carries one, and each tripwire carries its own. A single summary
needing two anchors means the doc structure is wrong — but one statement may legitimately carry two
tripwires (the auto-checks KVO registration does), and then each keeps its own pointer.

### Anchors are API

Every pointer targets a `##`/`###` heading slug. **Renaming a heading is a breaking change** and
must sweep the pointers with it.

Each `##` topic section that governs specific code opens with a `**Backs:**` line naming those
files, so the mapping can be verified in both directions; its `###` subsections inherit that line.
Sections that back no single file — this index, the release runbook, the secrets table, the
upstream-fact lists, and notes about tooling behaviour rather than repo code — carry none.

### Tripwires

A warning **stays in the code** if and only if removing it would let a plausible edit **build
green and test green** while breaking behavior at runtime. Anything the compiler catches gets no
tripwire.

```swift
// DO NOT <the prohibited edit> — <the consequence, one clause>.
// Why: docs/<file>.md#<anchor>
<the tempting line>
```

- Starts with `DO NOT`, `NEVER`, or `MUST`, so `grep -rn 'DO NOT\|NEVER\|MUST '` finds every one.
- **Two lines of prose maximum**, plus the `Why:` line — prohibition and consequence, nothing more.
  The reasoning belongs at the anchor.
- Placed **immediately above the tempting token**, not in the enclosing type's doc comment.

## Tripwire index

Every site that must keep an imperative warning in the code, the prohibition it carries, and where
its argument lives. This doubles as the acceptance criterion for the migration: nothing load-bearing
has been lost if every row is present at its site and its anchor holds the full reasoning.

Every one is findable with a keyword sweep over the code — that keyword set is the convention,
so a warning phrased any other way is invisible to the sweep and does not count. **Rows marked
_(pending)_ are not in the tree yet**: their file has not been trimmed. Drop the marker as each
lands. The raw sweep returns slightly more hits than there are unmarked rows, and the difference is
exactly accountable:

- unmarked rows in the table below — **40**
- plus 1: the "both KVO handlers" row covers two sites in the updater
- plus 1: the main/release workflow row covers two sites
- plus 1: an incidental "MUST be" in review-workflow prose, not a tripwire
- **sweep total — 43**

The sweep is over code, not prose:

```bash
grep -rn 'DO NOT\|NEVER \|MUST ' \
  --include='*.swift' --include='*.yml' --include='*.sh' --include='*.plist' . \
  | grep -v DerivedData
```

Markdown is excluded deliberately — this page states the keywords several times itself, and would
otherwise inflate its own count.

If those numbers stop reconciling, either a tripwire was added without an index row or one was
deleted from the tree.

| Site | Prohibition | Anchor |
| --- | --- | --- |
| `Updater.swift` — `@objc(updater:shouldPostpone…)` | Don't rename the Swift label or drop the pin | [distribution.md#the-objc-selector-pin](distribution.md#the-objc-selector-pin) |
| `Updater.swift` — `UpdaterDelegate` | Don't guard the check instead of the relaunch | [distribution.md#relaunch-not-check](distribution.md#relaunch-not-check) |
| `Updater.swift` — the three initializers | Don't collapse them | [distribution.md#three-initializers](distribution.md#three-initializers) |
| `Updater.swift` — `controller` | Don't delete the "unused" property | [distribution.md#controller-is-ownership-only](distribution.md#controller-is-ownership-only) |
| `Updater.swift` — `delegate` | Don't delete it either; the controller holds it weakly | [distribution.md#controller-is-ownership-only](distribution.md#controller-is-ownership-only) |
| `Updater.swift` — `autoChecksStorage` | Don't collapse into a `didSet` mirror | [distribution.md#kvo-mirrors](distribution.md#kvo-mirrors) |
| `Updater.swift` — auto-checks KVO | Don't add a second observer on `.standard` | [distribution.md#scope-of-the-auto-checks-mirror](distribution.md#scope-of-the-auto-checks-mirror) |
| `Updater.swift` — both KVO handlers | Never `MainActor.assumeIsolated` | [distribution.md#never-mainactorassumeisolated](distribution.md#never-mainactorassumeisolated) |
| `Updater.swift` — the postpone loop's sleep | Not `try?` — it swallows cancellation | [distribution.md#relaunch-not-check](distribution.md#relaunch-not-check) |
| `ModelDownloadWatchdog.swift` — `withStallWatchdog` | Don't rewrite as a `TaskGroup` | [concurrency.md#abandon-not-await](concurrency.md#abandon-not-await) |
| `ModelDownloadWatchdog.swift` — the clock | Suspending, not continuous | [concurrency.md#suspending-clock](concurrency.md#suspending-clock) |
| `ModelDownloadWatchdog.swift` — `isTimingOut` | Latch the verdict before draining | [concurrency.md#abandon-not-await](concurrency.md#abandon-not-await) |
| `TranscriptionManager.swift` — `loadModel` | Release the old engine before loading the new one | [concurrency.md#engine-release-ordering](concurrency.md#engine-release-ordering) |
| `TranscriptionManager.swift` — `wipeDirectory` | `deletion` must be set before the first suspension | [concurrency.md#the-removal-contract](concurrency.md#the-removal-contract) |
| `ContentView.swift` — `refreshSize` | Don't drop `measureGeneration` ownership | [concurrency.md#cache-walk-ownership](concurrency.md#cache-walk-ownership) |
| `ContentView.swift` — `performRemoval`'s `isMeasuring = false` | Don't drop it as redundant | [concurrency.md#cache-walk-ownership](concurrency.md#cache-walk-ownership) |
| `ContentView.swift` — `LanguagePicker.onSubmit` | A blank query must not select `filtered.first` | [architecture.md#the-language-picker](architecture.md#the-language-picker) |
| `TranscriptionManager.swift` — `removeAllAppData` | Clear via `UserDefaults`, never delete the plist | [concurrency.md#remove-all-app-data](concurrency.md#remove-all-app-data) |
| `Speech2TextApp.swift` — the main scene | `Window`, not `WindowGroup` | [architecture.md#window-not-windowgroup](architecture.md#window-not-windowgroup) |
| `Speech2TextApp.swift` — `HelpMenuCommand` | Never bind ⌘? — macOS reserves it | [architecture.md#menu-commands](architecture.md#menu-commands) |
| `AboutView.swift` — the credits block | Don't drop `.fixedSize` | [architecture.md#the-about-panel](architecture.md#the-about-panel) |
| `TranscriptionManager.swift` — `modelDownloadIdleTimeout` | Don't tighten the window | [concurrency.md#idle-timeout-arithmetic](concurrency.md#idle-timeout-arithmetic) |
| `TranscriptionManager.swift` — `uiTestingLaunchArgument` | Changing the value obliges a UI-test edit | [testing.md#the-cross-target-contract](testing.md#the-cross-target-contract) |
| `TranscriptionManager.swift` — the UI-test stub | Audit it if another `.completed` invariant is added | [testing.md#the-seam-itself](testing.md#the-seam-itself) |
| `feature.yml` — the `on:` block | Don't add a `pull_request:` trigger | [automation.md#push-only-deliberately-no-pull_request-trigger](automation.md#push-only-deliberately-no-pull_request-trigger) |
| `ContentView.swift` — `performRemoval`'s `removal` | Must stay `@MainActor` | [concurrency.md#se-0338-and-the-actor-hops](concurrency.md#se-0338-and-the-actor-hops) |
| `Speech2TextUITests.swift` — `launchApp()` | The literal must equal the app-side constant | [testing.md#the-cross-target-contract](testing.md#the-cross-target-contract) |
| `UpdaterTests.swift` — `postponeHookSelectorIsWired` | Don't "fix" it to `#selector` | [testing.md#selector-tripwire](testing.md#selector-tripwire) |
| `UpdaterTests.swift` — file header | Never construct a real `SPUUpdater` | [testing.md#never-construct-spuupdater](testing.md#never-construct-spuupdater) |
| `StallWatchdogTests.swift` — timing margins | Widen the budget, never delete the test | [testing.md#the-flake-budget](testing.md#the-flake-budget) |
| `project.yml` — the Sparkle package | Never re-add a tarball download | [distribution.md#the-appcast](distribution.md#the-appcast) |
| `publish-release.yml` — `generate_appcast` | Never re-add a tarball download | [distribution.md#the-appcast](distribution.md#the-appcast) |
| `publish-release.yml` — the keypair check | Capture then match, never pipe to `grep -q` | [distribution.md#the-keypair-check](distribution.md#the-keypair-check) |
| `publish-release.yml` — the `--latest` query | Don't add `|| true` | [distribution.md#claiming---latest](distribution.md#claiming---latest) |
| `publish-release.yml` — `concurrency` | Keep it keyed per tag | [distribution.md#concurrency-is-keyed-per-tag](distribution.md#concurrency-is-keyed-per-tag) |
| `claude-code-review.yml` — the trigger | Never switch to `pull_request_target` | [automation.md#review-and-fix-loop](automation.md#review-and-fix-loop) |
| `commit-guard.sh` — the `jq` check | Must fail closed | [automation.md#the-commit-guard](automation.md#the-commit-guard) |
| `precommit-hash.sh` — the empty-tree case | Must emit nothing | [automation.md#the-commit-guard](automation.md#the-commit-guard) |
| `main.yml` / `release.yml` — the commented `pull_request:` block | Re-check the concurrency key before enabling | [automation.md#push-only-deliberately-no-pull_request-trigger](automation.md#push-only-deliberately-no-pull_request-trigger) |
| `Info.plist` — `SUFeedURL` | Permanent; changing it strands installed copies | [distribution.md#sufeedurl-is-permanent](distribution.md#sufeedurl-is-permanent) |
