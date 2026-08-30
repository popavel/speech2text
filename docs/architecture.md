# Architecture

A handful of Swift files do all the real work; the UI is intentionally thin.

| File | Role |
| --- | --- |
| `Speech2Text/TranscriptionManager.swift` | The brain. `@MainActor @Observable` class holding all app state, owning the `WhisperKit` instance and driving the status machine. |
| `Speech2Text/ContentView.swift` | SwiftUI view over that state, plus `SettingsView`. No business logic. |
| `Speech2Text/Speech2TextApp.swift` | App entry point — scenes and menu commands. |
| `Speech2Text/Updater.swift` | The Sparkle auto-update seam. See [distribution.md](distribution.md). |
| `Speech2Text/ModelDownloadWatchdog.swift` | `withStallWatchdog`. See [concurrency.md](concurrency.md). |
| `Speech2Text/HelpView.swift` | The in-app help book, including the uninstall guide. |
| `Speech2Text/AboutView.swift` | The About panel. |

---

## State flow

**Backs:** `Speech2Text/TranscriptionManager.swift` · `Speech2Text/ContentView.swift`

State flow is **one-way**: the UI mutates `selectedLanguage` / `selectedModel` / `droppedFileURLs`,
calls `startTranscription()`, then renders from `status` + `transcriptionResult`. **Don't add
parallel state in views.**

`TranscriptionManager` drives a `TranscriptionStatus` state machine:
`idle → loadingModel → transcribing(progress) → completed | error`. It lazily (re)loads WhisperKit
when `selectedModel` changes. For video files it routes through `extractAudio(...)`, which uses
`AVAssetExportSession` to write a temp `.m4a` before handing the path to WhisperKit.

Supported extensions are declared as `nonisolated static` sets on `TranscriptionManager` — the UI
reads from these, so changes propagate everywhere. Which formats macOS actually decodes (as opposed
to merely registering as audio) is pinned by
[testing.md#the-decodability-oracle](testing.md#the-decodability-oracle).

`ContentView` takes the manager as `@Bindable`, not `@State`: the manager's lifetime belongs to
`Speech2TextApp`, which holds it in `@State` and hands the same instance to both the main window and
the Settings scene. `@Bindable` observes that instance and still exposes the `$manager.…` bindings
the pickers and editor need, without re-wrapping it in the view's own state — so the view can never
pin a stale manager if the app later supplies a new one.

There is a single `init(manager:)`; the app, the ViewInspector suite, and `#Preview` all inject
through it. There is no zero-arg `init()`.

---

## Model cache directory

**Backs:** `Speech2Text/TranscriptionManager.swift` (`bundleIdentifier`, `appSupportDirectory`,
`modelCacheDirectory`)

**WhisperKit models are downloaded on first use, not bundled.** First run with a given model can be
slow, and `*.bin` / `*.mlmodelc` are gitignored.

The download location is overridden via WhisperKit's `downloadBase:` to the app-owned
`~/Library/Application Support/com.speech2text.app/models` — *not* WhisperKit's default
`~/Documents/huggingface`, which would dump gigabytes into the user's Documents.

The path derivation is a single chain so nothing can drift:

- `bundleIdentifier` is **hard-coded** (mirroring `PRODUCT_BUNDLE_IDENTIFIER`) rather than read from
  `Bundle.main`, so the path is identical under the test host, which runs in a different bundle. It
  is also what the uninstall guide's leftover-path list reads.
- `appSupportDirectory` is the one home for everything the app writes there; the complete-uninstall
  wipe removes this whole folder. It passes `create: false` — reading a path shouldn't have the side
  effect of creating the folder, and WhisperKit/Hub creates the tree on demand when it actually
  downloads.
- `modelCacheDirectory` derives from it, so the download path and both cleanup paths can't drift
  apart.

`TranscriptionManager` exposes `currentCacheSize()` / `deleteAllModels()` (the heavy filesystem walk
runs off the `@MainActor`), and the `Settings` scene lets users delete that cache — the in-app half
of a graceful uninstall. macOS has no uninstaller hook and the app isn't sandboxed, so nothing is
reaped when it is trashed.

The removal contract itself — the busy-flag ordering, the three-valued return, why the engine is
dropped on *existence* rather than full success — is in
[concurrency.md#the-removal-contract](concurrency.md#the-removal-contract).

---

## Persisted settings

**Backs:** `Speech2Text/TranscriptionManager.swift` (`Keys`, `Defaults`, `loadPersistedSettings`,
`restoreDefaults`, `makeDecodingOptions`)

Four user settings persist across launches — task, language, model, temperature — written by each
property's `didSet` into an **injectable** `UserDefaults` (see
[testing.md#hermetic-di](testing.md#hermetic-di) for why it is injectable).

`loadPersistedSettings()` overlays stored values onto the declared defaults, and its failure mode is
deliberate: **an absent or invalid value leaves both the in-memory default and the stored value
untouched.** A model id no longer offered after an app update, or a language WhisperKit has dropped,
stays on disk so it resolves again if that entry returns — rather than being erased to `.auto` on a
mere launch. It is called once from `init`, and each *successful* assignment is idempotent with the
property's `didSet`, which writes back the value just read.

The language is stored by its **`id`**, and `loadPersistedSettings` resolves it with the same
predicate the tests use, so a persisted value round-trips to the same entry regardless of alias
ordering.

`restoreDefaults()` resets all four (Transcribe, Base, temperature 0, Auto-detect). Each
assignment's `didSet` re-persists, so the store reflects the reset too. It deliberately **does not
touch the loaded engine** — the model only (re)loads on the next `startTranscription()`, so
restoring `.base` never triggers a download from here. It is also *not* called by
`removeAllAppData`, for the opposite reason — see
[concurrency.md#remove-all-app-data](concurrency.md#remove-all-app-data).

`makeDecodingOptions()` maps that state to WhisperKit's `DecodingOptions`. It is the pure logic that
is testable without loading a model or touching the network.

Sparkle's own preferences live in the same defaults domain but **outside** `Keys.all`, so neither
wipe touches them — see [distribution.md#the-seam](distribution.md#the-seam).

---

## Scenes and menu commands

**Backs:** `Speech2Text/Speech2TextApp.swift`

One `TranscriptionManager` is shared by both scenes (main window + Settings), so storage cleanup in
Settings resets the same live engine the main window uses. It is created — and seeded for XCUITest —
in `Speech2TextApp.init()` rather than inside `ContentView`.

The updater is likewise constructed in `init()` rather than lazily in a view, because Sparkle's
scheduled check has to start at launch and because it needs the manager for its busy check.
Capturing the manager is cycle-free: it holds no reference back to the updater. The busy check
covers **both** `isProcessing` and `isRemovingData`, matching every other busy gate in the app —
mid-transcription the run and the unexported transcript live only in memory, and mid-removal a
relaunch would leave a half-deleted cache with the defaults cleanup skipped, so "cleared" settings
would survive. See
[distribution.md#relaunch-not-check](distribution.md#relaunch-not-check).

### Window, not WindowGroup

The main scene is a single-instance `Window`, not a `WindowGroup`. The app owns one shared manager,
so a second main window would mirror all state — files, progress, result — between windows. `Window`
is inherently single and drops the File ▸ New Window / New Tab commands.

The **About** and **Help** scenes are single-instance `Window`s too, so re-choosing the menu item
brings the same panel forward rather than spawning a second. Both set
`.restorationBehavior(.disabled)` so they open only on demand — an auxiliary panel left open at quit
shouldn't reappear by itself on the next launch (no native About panel does). About also uses
`.contentSize` resizability, giving it the tight, non-resizable feel of the stock panel. Help is a
standalone window so it can stay open alongside the main window; its Uninstalling topic links into
Settings.

### Menu commands

- **About** replaces the standard `.appInfo` item, whose stock panel shows almost nothing (the
  shipped bundle carried no version string).
- **"Check for Updates…"** sits directly after About, where macOS apps conventionally put it,
  disabled whenever the updater can't check — including every gated (test) launch.
- **Help** replaces the default, help-book-less and therefore broken "Speech2Text Help" item.

`AboutMenuCommand` and `HelpMenuCommand` are dedicated `View`s rather than bare closures, so they can
pull `openWindow` from the environment — a bare closure in `.commands` can't.

**No `.keyboardShortcut("?")` on Help:** macOS reserves ⌘? for the Help-menu search field it
auto-inserts, which wins the key equivalent, so a custom binding there is a dead key.

---

## The language picker

**Backs:** `Speech2Text/ContentView.swift` (`LanguagePicker`)

The full WhisperKit language set (~100 entries) is too long for a plain menu, so the picker presents
the current selection as a button opening a popover with a search field and a filtered, scrollable
list.

`List` + `.searchable(text:)` was **considered and rejected**: `.searchable()` is only reliable
inside a `NavigationStack`, and in a bare `.popover` it has known rough edges around search-field
placement and content-driven sizing. Hence the hand-rolled `TextField` + `ScrollView`.

Type-to-filter is the navigation model. Arrow-key row cycling is intentionally not reimplemented,
but Return selects the top match via `.onSubmit` — and a blank query must **not** select
`filtered.first`, since there is no meaningful "top match" to commit to.

---

## The Settings scene

**Backs:** `Speech2Text/ContentView.swift` (`SettingsView`)

`SettingsView` takes the same shared manager as the main window, so a storage wipe there resets the
live engine. It re-measures the model cache on `controlActiveState` rather than on a global
did-become-key notification, so the walk is scoped to this window becoming key rather than to any
window in the app. The coalescing and ownership scheme that makes that safe — and the delete path
that races it — are in
[concurrency.md#cache-walk-ownership](concurrency.md#cache-walk-ownership) and
[concurrency.md#the-removal-contract](concurrency.md#the-removal-contract).

---

## The help book's derived facts

**Backs:** `Speech2Text/HelpView.swift` · `Speech2TextTests/HelpViewTests.swift`

`HelpView` is a `NavigationSplitView` whose sidebar lists the `HelpTopic`s and whose detail renders
the selected one. It replaced a former standalone "Uninstalling Speech2Text…" window — uninstalling
is now this book's final topic.

**Facts that can drift from the code are derived** from `TranscriptionManager`'s canonical `static`
declarations and are covered by `HelpViewTests`: supported formats, model display names and the
default model, the default language name, task labels, the storage/uninstall paths, the batch-run
header, and the language count.

**The rest of the copy is illustrative prose that is NOT derived**, so a rebind or a control rename
has to be mirrored here by hand. That non-derived surface is:

- every keyboard shortcut — ⌘O, ⌘⏎, ⌘,
- every control label named in the text — the Settings labels ("Downloaded models", "Delete
  Downloaded Models", "Remove All App Data", "Restore Default Settings", "Check for updates
  automatically"), the main-window controls ("Browse Files", "Clear All", "Task", "Advanced",
  "Temperature", "Transcribe", "Copy", "Export .txt") and the "Storage" section.

**Renaming any of these in `ContentView` builds green and passes tests while leaving the help book
misdescribing the UI.** The partial guard against that, and its two known holes, is described in
[testing.md#the-help-book-is-wiring-protected-not-wording-protected](testing.md#the-help-book-is-wiring-protected-not-wording-protected).

---

## The About panel

**Backs:** `Speech2Text/AboutView.swift`

Static content — it takes no `TranscriptionManager`, unlike `ContentView`/`SettingsView`: app
identity, version, author, license, source link, and the open-source acknowledgements for what
actually ships in the binary.

`versionString` is read **once** from the bundle's `Info.plist`, which maps
`CFBundleShortVersionString`/`CFBundleVersion` from the `MARKETING_VERSION`/
`CURRENT_PROJECT_VERSION` build settings — so it shows the real shipped version instead of a
duplicated literal, and can't drift from `project.yml`. It is a `static let` because the bundle
version is fixed for the process lifetime, avoiding an `Info.plist` read on every `body` render
(mirroring how `HelpView` hoists its derived strings). It is `nil` when the bundle carries no
version — only under a stripped test host — so the line is simply omitted rather than showing a
placeholder. It renders `"Version X (Y)"` only when the build differs from the short version;
because [version lockstep](distribution.md#version-lockstep) keeps them equal, the shipped panel
always shows `"Version X.Y.Z"`. See that section for why they are always equal, and
[testing.md#the-about-panel-version-gap](testing.md#the-about-panel-version-gap) for why no test
asserts it.

The acknowledgements credit the open-source components that ship **inside the app binary**
(WhisperKit and its vendored swift-transformers, Sparkle); OpenAI's Whisper is the underlying model.
The full license texts live in `THIRD-PARTY-LICENSES.md`, which ships inside the app bundle as well
as at the repo root — see [build.md#target-layout](build.md#target-layout).

`.fixedSize(horizontal: false, vertical: true)` on the credits block is load-bearing: without it the
longest credit line — currently Sparkle's — exceeds the panel's fixed 380 pt width
and truncates with "…" instead of wrapping to a second line.
