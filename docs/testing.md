# Testing

Three test targets, deliberately split, plus one shared source folder. The commands themselves live
in [AGENTS.md](../AGENTS.md#common-commands); this file is why they are shaped the way they are.

| Target | Kind | Runs in the `Speech2Text` scheme? |
| --- | --- | --- |
| `Speech2TextTests` | Swift Testing unit + view-render | yes |
| `Speech2TextIntegrationTests` | Swift Testing | yes — the extraction and decodability suites always run; only `TranscriptionPipelineIntegrationTests` is gated off by default |
| `Speech2TextUITests` | XCUITest automation | **no** — its own scheme |

`Speech2TextTestSupport/` is **not** a target: it is a folder of shared test-only fixtures listed in
both unit targets' `sources:`, so both build their managers the same hermetic way. See
[build.md#target-layout](build.md#target-layout).

---

## Swift Testing convention

**Backs:** all of `Speech2TextTests/` and `Speech2TextIntegrationTests/` ·
`Speech2TextUITests/Speech2TextUITests.swift` (the exception below)

Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Keep new tests in that
style.

### The XCTest exception

`Speech2TextUITests` is an XCUITest target, and `XCUIApplication` lives only in XCTest, so those
tests are `XCTestCase` subclasses. **Don't "fix" them to Swift Testing** — there is no Swift Testing
equivalent for UI automation.

`@MainActor` on the class keeps `XCUIApplication`'s main-actor-isolated members reachable, and
values are read into locals before `XCTAssert` so they aren't touched from `XCTAssert`'s
nonisolated autoclosure under Swift 6 strict concurrency.

The `tearDown()` override is `async` **on purpose**: `@MainActor` on the class does **not** reach an
override of a `nonisolated` superclass method — an override inherits the isolation of the
declaration it overrides, and `XCTestCase.tearDown()` is nonisolated. So a plain sync override
cannot touch main-actor-isolated members under Swift 6. The async variant can hop explicitly.
(`tearDown() async throws` runs last in XCTest's teardown sequence rather than first, which is
immaterial — nothing else tears down.)

**The app is terminated after every UI test, pass or fail.** The help book is a second `Window`; if
a test opens it and then fails before closing it (`continueAfterFailure = false` aborts at the first
failed assertion), the window would be left open and could reach the next test, which assumes a
single main window. Terminating kills any such window regardless of the failure path.
`terminate()` is a no-op if nothing is running, and abnormal termination doesn't persist window
state. (The scene itself also sets `.restorationBehavior(.disabled)` — see
[architecture.md#scenes-and-menu-commands](architecture.md#scenes-and-menu-commands) — so
cross-launch restoration is closed off at the source too; the teardown covers the
within-run case.) Suppressing restoration via
`-NSQuitAlwaysKeepsWindows NO` / `-ApplePersistenceIgnoreState` launch args was tried instead, but
those prevent this SwiftUI app's main window from appearing at all.

---

## Test subsetting

**`-only-testing` only resolves to the suite, not a single test.** With Swift Testing under
`xcodebuild` here, `-only-testing:<Target>/<SuiteStruct>` works, but the single-test form
`-only-testing:<Target>/<SuiteStruct>/<testFunc>` silently runs **0 tests** — even with a correct
function name (verified against real functions in both unit targets). To focus on one test, run its
whole suite, or run everything and `grep`.

The path uses the **struct name**, not the `@Suite` display name.

Relatedly, `xcbeautify` swallows parameterized `@Test(arguments:)` cases — they don't show
individually and can look like the test never ran. Pipe raw `xcodebuild` output through `grep` to
confirm they executed.

---

## Hermetic DI

**Backs:** `Speech2TextTestSupport/ManagerFixture.swift` · `Speech2Text/Updater.swift`

Unit tests run **inside the app** (test host = the app), so `.standard` `UserDefaults` resolves to
the developer's real `com.speech2text.app` domain. Everything persistent is therefore injected.

`ManagerFixture` vends a `TranscriptionManager` backed by a throwaway `UserDefaults` suite and
removes that domain in `deinit`. Hold the fixture for as long as any manager built from it is in
use: a per-test fixture is released after its test and leaves no orphan `s2t.test.*` plist, whereas
one kept for the whole process (a `static let`) is released only at exit and so may leave a single
ephemeral domain — still never `.standard`.

It is `@unchecked Sendable` because its storage is immutable (`let`) and `UserDefaults` is
thread-safe, so one fixture can be shared across a serialized suite. It stays **nonisolated** — not
`@MainActor` — so `deinit` may touch the non-`Sendable` store; only `makeManager()` needs the main
actor, to satisfy `TranscriptionManager`'s `@MainActor` init.

`persistedKeys` reads the fixture's domain directly, so a test can assert the persisted set equals
`Keys.all` (and that the wipe empties it) without a hand-maintained key list.

### Never construct SPUUpdater

**Backs:** `Speech2TextTests/UpdaterTests.swift`

**Never construct a real `SPUUpdater`, started or not.** It builds an `SUHost` over the app's
`.standard` domain, so a real updater would read and write the developer's own installed-app
preferences. Two seams keep the model testable without one:

- **`FakeUpdater`** fakes the view-facing `UpdaterModel`, and is what render tests inject.
- **`FakeSparkleUpdater`** fakes the Sparkle-facing `SparkleUpdating` protocol, injected through
  `SparkleUpdaterModel.init(updater:)`. That initializer names no Sparkle type at all, so it
  *structurally* cannot bring an `SPUUpdater`/`SUHost` into existence. This is what gives the
  model's **live** branch — seeding, both KVO mirrors, both write paths — real coverage.

`FakeSparkleUpdater` is an `NSObject` with `@objc dynamic` storage because the model registers real
KVO against it. The fakes only ever mutate on the main actor, which is precisely why they cannot
catch an off-main KVO delivery — see
[distribution.md#kvo-mirrors](distribution.md#kvo-mirrors).

`isDebugBuild` being an injectable parameter is what lets the gate suite test **both** answers,
including the combination that ships, from a run that is itself always Debug. See
[distribution.md#the-launch-gate](distribution.md#the-launch-gate).

### Selector tripwire

`postponeHookSelectorIsWired` asserts the one part of the postpone guard a green build does **not**
prove: Sparkle finds the hook by selector at runtime, and `untilInvoking:` compiles fine while only
"nearly matching" the optional requirement — so the typo yields a green build *and* a green suite
with the hook silently never called.

The selector name is spelled out as a **runtime string on purpose**. Do **not** "fix" it to
`#selector(UpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:))`: that
form is *derived from* the `@objc` pin under test, so it would keep passing after the pin was
deleted or mistyped — the entire failure this test exists to catch. `NSSelectorFromString` rather
than `Selector(_:)` because the latter draws a "use `#selector` instead" warning for exactly the
literal that must be kept.

Constructing the delegate is hermetically safe: `init(isBusy:)` takes only a closure.

---

## Static inspection

**Backs:** `Speech2TextTests/ContentViewTests.swift` · `HelpViewTests.swift` · `AboutViewTests.swift`

View-render tests use [ViewInspector](https://github.com/nalexn/ViewInspector), a **test-only**
SwiftPM dependency linked into `Speech2TextTests` only, **never** the app target. They assert the
SwiftUI hierarchy reflects the injected `TranscriptionManager` state.

**All inspection is static**: each assertion builds a fresh view and reads its rendered body, so no
`ViewHosting` / XCTest machinery is needed and the suite stays pure Swift Testing. Don't reach for
`ViewHosting`. Keep view *behavior* (`clearFiles`, `removeFile`) tested on the manager directly;
ViewInspector covers render only. These tests never tap Transcribe, which would load WhisperKit.

`ContentView` has a single `init(manager:)` initializer — the app, the `#Preview`, and these suites
all inject through it (there is no zero-arg `init()`).

**Assertion-style convention:** use bare `try` when the found view's value is then asserted (the
result is bound and used); use `#expect(throws: Never.self) { … }` for existence-only checks, where
the result is discarded — it documents the "this lookup must succeed" intent and avoids an
unused-result warning.

### ViewInspector limits

The `HelpView` **container** rendering — sidebar rows, which detail pane is shown, and the
nil-selection → Overview `?? .overview` fallback — is **not inspectable**. ViewInspector 0.10.3
can't unwrap a custom view whose body is a 2-column `NavigationSplitView(sidebar:detail:)`: every
traversal (generic `find`, `navigationSplitView()`, `find(NavigationSplitView.self)`) throws "does
not have 'content' attribute", because its child extraction expects the 3-column `content` column.

Reshaping production purely to satisfy the test isn't worth it, so the sidebar `helpTopic-*` rows
and the default `helpDetail-overview` pane stay covered by the XCUITest
(`testHelpBookOpensFromMenuAndNavigatesTopics`), which drives the real container.

`AboutView` is a plain `VStack`, so ViewInspector traverses it directly.

### The About-panel version gap

`AboutViewTests` pins the panel's fixed copy but **deliberately does not assert the version
string**: `AboutView` reads it from `Bundle.main` at runtime, which resolves to the test host's
bundle rather than the app's, so any version assertion would be environment-dependent and flaky.
The version is left to manual/visual verification of the real app. This is the one deliberate gap.

### The help book is wiring-protected, not wording-protected

The help copy **derives** its factual claims from `TranscriptionManager`'s canonical `static`
declarations (supported formats, model display names and default, task labels, the storage and
uninstall paths, the batch-run header, the language count), and each assertion recomputes the
expected string from that same source.

Because both sides derive from one source, a content change propagates to the copy *and* the
expectation together — so these **cannot** catch a wording change, nor do they need to. What they
pin is that the help copy stays *wired to* the canonical source: if a topic hard-coded a literal
instead of interpolating the derived value, the rendered text would stop matching and the test would
fail.

The control labels named in that prose are guarded separately by `labelsAppearInBothUIAndHelp`,
whose 13-row table is the guard's single source: each label must render **both** as a real control
and somewhere in the help copy, so any **2-of-3 divergence** (control renamed, prose renamed, or the
table left stale) trips it.

**The keyboard shortcuts — ⌘O, ⌘⏎, ⌘, — are deliberately out of scope for that guard** and are
therefore checked by nothing: a `KeyEquivalent` isn't recoverable from the rendered hierarchy, so
there is no derivable expectation to compare against. A rebind leaves the help book wrong and every
suite green.

One label is only partially covered, and one is absent. **"Storage"** is named in prose but its control is a
`Section` header, which doesn't inspect as a plain `Text`, so it is absent from the table and
covered by the derived Storage-path tests instead. And the control-side check is a plain text match,
so a label rendering more than once is only partially guarded: **"Transcribe"** is both the run
button and `DecodingTask.transcribe.displayName` (the Task picker option), so renaming the button
alone would still find the text and pass. It is kept for the prose-side and simultaneous-rename
coverage it does provide.

So of the labels the help book names: 12 are fully guarded, "Transcribe" partially, "Storage" by a
different test, and the three shortcuts not at all.

`HelpDetailView`'s `.id(topic)` gives the `ScrollView` a fresh identity per topic so the reused
detail slot resets its scroll offset on a switch; a test pins that so the reset can't be silently
dropped.

---

## Settings and decoding suites

**Backs:** `Speech2TextTests/SettingsPersistenceTests.swift` ·
`Speech2TextTests/DecodingParametersTests.swift` ·
`Speech2TextTests/TranscriptionManagerTests.swift` (`persistedKeysMatchKeysAll`)

None of these use ViewInspector — they exercise the manager directly.

`SettingsPersistenceTests` covers persistence of the four user settings across
`TranscriptionManager` instances that **share a store**, plus `restoreDefaults()`. Every manager
comes from a `ManagerFixture`, so nothing touches `.standard`. Its Spanish helper looks the entry up
by `code` purely so the test doesn't hard-code a display name — **the persisted value is the entry's
`id`**, which is its `displayName`, and `loadPersistedSettings` matches on `$0.id == id`.

`unresolvableLanguageIsPreserved` seeds a **stale** language id — one that resolved under an earlier
WhisperKit and no longer matches any row — and asserts the in-memory value falls back to `.auto`
while the stored id **stays on disk**, so it resolves again if that entry returns. It mirrors the
model path, and would fail before the load path stopped writing `.auto` back over an unresolved
language.

`DecodingParametersTests` covers the user-facing knobs (task, temperature) and the
state → `DecodingOptions` mapping in `makeDecodingOptions()` — the pure logic testable without a
model or the network. The actual `transcribe(...)` call is **not** exercised there. Each manager
comes from a per-test fixture so writes can't leak between tests.

`persistedKeysMatchKeysAll` seeds through the real setters and compares the live store against
`Keys.all`. That catches a stale or extra `Keys.all` entry, a key written under the wrong name, and
forces the seed list to grow whenever `Keys.all` does — an unseeded new key makes the sets differ.
**Residual gap:** a new persisted property added to *neither* `Keys.all` nor the seed list is
invisible to any hand-listed test; closing that fully would need a settings registry.

Both suites are described in [architecture.md#persisted-settings](architecture.md#persisted-settings).

---

## The wall-clock exception

**Backs:** `Speech2TextTests/StallWatchdogTests.swift`

The rest of the suite is deliberately clock-free (bounded `Task.yield()` spins). **A timeout has no
other observable — it *is* elapsed time — so this file is the one justified exception.** The
stalling windows are milliseconds; the two margins that must *not* trip are deliberately seconds
(see below). The assertions are one-directional wherever they can be: that something *did* time
out, or *did* finish.

`stallingOperationIsAbandoned` and `tickingOperationSurvivesPastIdleWindow` are the two halves of
the "slow ≠ wedged" claim and should be read as a pair. The second caller of the helper,
`loadModels()`, has nothing to tick from, so it passes a ticker nobody ticks and the helper
degenerates into a plain ceiling — the behavior `stallingOperationIsAbandoned` already covers.

### The flake budget

One test cannot be one-directional, and it is worth naming rather than hiding.
`tickingOperationSurvivesPastIdleWindow` proves a progressing operation is **not** killed, so it
necessarily depends on its ticks landing inside the idle window — a scheduling hiccup longer than
`tickingIdle` would fail it.

That margin is the flake budget. It is set wide — **a full second, 50× the 20 ms tick interval** —
because Swift Testing runs other `@MainActor` suites in the same process concurrently, so the main
actor this test ticks from is genuinely contended on a loaded runner. **Widen it further rather
than deleting the test**, keeping the operation's total runtime above it or the test stops proving
anything.

The other windows are chosen for the same reasons: `drain` (2 s) is pure flake margin for
operations that honor cancellation and unwind immediately — the drain must not elapse ahead of an
operation merely descheduled behind a contended main actor. `shortDrain` (200 ms) is the opposite
case, for `drainIsBounded` alone: it must be comfortably **shorter** than that test's operation, or
the drain would end early on `didFinish` and the bound would go untested. That operation is a
detached, genuinely uncancellable **10-minute** sleep — effectively never finishing, which is the
only way the test measures the bound rather than a timing difference. A merely *slow* operation
would let `didFinish` end the drain early, so the deadline could be deleted and the test would
still pass. Its `.timeLimit(.minutes(1))` is what turns "hangs forever" into a red run: with the
bound intact the call returns in ~0.3 s, without it never.

---

## The cross-target contract

**Backs:** `Speech2Text/TranscriptionManager.swift` (`uiTestingLaunchArgument`) ·
`Speech2TextUITests/Speech2TextUITests.swift` (`launchApp`) ·
`Speech2TextTests/TranscriptionManagerTests.swift` (`uiTestingLaunchArgumentIsTheCrossTargetContract`)

`Speech2TextUITests` is a separate process that links **no app symbols**, so `launchApp()` hardcodes
`"-uiTesting"` with nothing in the compiler tying it to
`TranscriptionManager.uiTestingLaunchArgument`.

Renaming the *identifier* is safe — an ordinary compiler-checked refactor. **Changing the *value* is
what silently breaks the seam**, and the updater gate with it, on a UI-test launch.

**The guard runs in one direction only.** `uiTestingLaunchArgumentIsTheCrossTargetContract` pins the
app-side constant to the literal XCUITest sends, so an app-side value change fails the unit suite.
The reverse — editing the literal in the UI-test file — is caught by **nothing but running the UI
tests**, and it clobbers real app preferences on the way: with the seam inert, the app persists to
`.standard` rather than the volatile suite. That is why the assertion is deliberately
literal-vs-literal, and why the hazard is spelled out at the UI-test call site too.

The constant lives **outside** the `#if DEBUG` block. Both seam functions there are compiled out of
Release, but `SparkleUpdaterModel.shouldStartUpdater` reads the same sentinel unconditionally — and
that check is reachable *only* in Release (a Debug build is refused a line earlier), so a Debug-only
constant would not compile for its one real caller.

### The seam itself

Launch with `-uiTesting`, then `UITEST_PRELOAD_FILES` (newline-joined paths — extension-filtered,
never stat'd, so a synthetic `/tmp/x.mp3` works) preloads the queue and `UITEST_STUB_RESULT` stubs a
completed transcription, so the result UI is reachable without a model. `applyUITestSeamIfPresent`
is called from `Speech2TextApp.init()`. The seam is compiled out of Release.

**UI tests never tap Transcribe** — it calls `startTranscription()`, which loads WhisperKit and
downloads a model.

`UITEST_STUB_RESULT` jumps straight to the terminal `.completed` state, deliberately skipping most
of the side effects the real path runs en route (setting `whisperKit`, progress ticks). It mirrors
exactly one `.completed` invariant: **clearing `skippedFileNames`.** Without that, a mixed preload
— some supported extensions, some not — would leave the result UI rendered alongside a stale
warning row, a state unreachable in the real app. Both the preload and the stub guard against an
empty value, so a blank stub can't flip the status to `.completed` with nothing to show. **If a
future change adds another `.completed` invariant, audit this shortcut too.**

Under `-uiTesting` the app also persists settings to an isolated, volatile store instead of
`.standard`, so UI tests are deterministic and can't clobber the developer's saved settings.

Menu-item lookups are scoped to the Help menu: a double accessibility path otherwise yields an
`INFINITY`-frame phantom element.

---

## Integration gating

**Backs:** `Speech2TextIntegrationTests/`

`TranscriptionPipelineIntegrationTests` drives `startTranscription()` end-to-end with real
WhisperKit, and is **gated** because the `tiny` model (~75 MB) is downloaded over the network on
first use.

`xcodebuild` forwards env vars prefixed **`TEST_RUNNER_`** to the test process with the prefix
stripped; the plain `RUN_WHISPERKIT_TESTS` form works when running tests directly. **Passing it as
an `xcodebuild` build setting silently skips the suite** — it must be a real environment variable.

The suite is `.serialized`: every test loads a model into the same shared cache, so concurrent
first-run downloads would race on the same files. (`parallelizable="NO"` in the scheme only governs
XCTest's multi-process runner, not Swift Testing's in-process parallelism.)

Its manager is built on a `ManagerFixture`, **not** `TranscriptionManager()`: the target is
app-hosted, so `.standard` is the app's real domain and the `.tiny`/language writes would clobber
the developer's saved settings. The fixture is a process-lifetime `static`, so its store outlives
every write; it is released only at process exit, leaving a single ephemeral `s2t.test.*` domain —
an acceptable residue for an opt-in suite. `modelCachingAcrossRuns` deliberately uses its own fresh
manager, because it asserts first-load-then-reuse.

### The decodability oracle

`AudioFormatDecodabilityTests` proves every audio format the app advertises actually decodes
through the **production read path**, end-to-end and hermetically (no model, no network).
WhisperKit's `AudioProcessor.loadAudio(fromPath:)` opens files with
`AVAudioFile(forReading:commonFormat: .pcmFormatFloat32, interleaved: false)`, and the oracle
mirrors that exact call: if it yields PCM frames, the app can transcribe the format.

This covers a gap the static `SupportedExtensionsTests` **cannot** — `UTType` conformance says a
format *registers* as audio, not that Apple's codecs can decode it. It also gives `wav` a real
decode assertion it previously lacked (the extraction suite only tests wav *routing*).

`mp3`/`aac`/`ogg` use tiny checked-in fixtures rather than runtime synthesis: Apple has no mp3 or
Ogg encoder, and raw ADTS `.aac` isn't reliably writable via `AVAudioFile` — yet `AVAudioFile`
*decodes* all three (verified on macOS 26). **`wma` and `avi` were removed** from the supported
lists because the app's stack can't decode them at all (`AVAudioFile`/`AVURLAsset` reject them
outright); the sweep now asserts every still-advertised format really is decodable, so the
regression can't slip back in.

Each format is checked in its own `do`/`catch` so a throw records an `Issue` for *that* format and
the loop continues. A bare `try` would abort the whole sweep on the first failure and leave every
later advertised format unverified that run.

---

## The partial-removal regression

**Backs:** `Speech2TextTests/TranscriptionManagerTests.swift`

Two tests (`deleteAllModelsDropsEngineOnPartialRemoval`,
`removeAllAppDataDropsEngineOnPartialRemoval`) pin the same fix from both entry points:
`removeItem` recurses depth-first, so it can unlink the weight files yet still throw on the final
node removal — returning `removed == false` while the cache is effectively gutted. Keying the engine
drop off *existence before* the attempt, not off full removal, is what fixes it. See
[concurrency.md#the-removal-contract](concurrency.md#the-removal-contract).

Reproduced deterministically by making the target's **parent** read-only: the child `model.bin`
(writable dir) still gets unlinked, but the final `rmdir` needs write on the parent and fails. Both
`#require(getuid() != 0)` first — root bypasses permissions, so the removal would fully succeed.

---

## WhisperKit drift

**Backs:** `Speech2TextIntegrationTests/TranscriptionPipelineIntegrationTests.swift` ·
`.github/workflows/dependency-drift.yml`

`loadModel(named:)` reassembles what `WhisperKit(model:downloadBase:)` does internally (download →
`modelFolder` → `loadModels()`), and **nothing in the default test run constructs a WhisperKit** —
that path lives only in the opt-in pipeline suite. A 1.x release that changed those semantics would
compile cleanly and fail on first model load for every user.

Two jobs close that gap, and it is worth knowing which covers what:

- **`dependency-drift.yml` un-gates the suite explicitly** (`TEST_RUNNER_RUN_WHISPERKIT_TESTS=1`),
  precisely so a drift check proves WhisperKit still *runs* rather than merely still *compiles*.
- **`integration-whisperkit.yml`** runs it on the feature/main/release pipelines, which the default
  `build-and-test` job does not.

So **both** a drift PR and a manual bump pushed to a `feature/**` or `chore/**` branch carry real
end-to-end evidence — the two paths differ in what they *propose*, not in what CI proves. The
genuine gap is narrower and worth stating precisely:

- `from:` never crosses a major, so **the drift check never proposes a major bump** — that is
  always a hand edit to `project.yml` (see
  [automation.md#dependency-drift](automation.md#dependency-drift)).
- Nothing asserts the WhisperKit *internals* the watchdog is built on. A release that stays green
  while changing the chunk size or the resume strategy passes unnoticed.

So the thing to do on any bump is re-check
[concurrency.md#upstream-facts-whisperkit-1x](concurrency.md#upstream-facts-whisperkit-1x). To run
the suite locally:

```bash
TEST_RUNNER_RUN_WHISPERKIT_TESTS=1 xcodebuild -project Speech2Text.xcodeproj \
  -scheme Speech2Text -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test -only-testing:Speech2TextIntegrationTests/TranscriptionPipelineIntegrationTests | xcbeautify
```
