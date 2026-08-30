# Build and project generation

## XcodeGen

**Backs:** `project.yml`

The `.xcodeproj` is **generated** from [`project.yml`](../project.yml) by XcodeGen. Most of the
bundle is gitignored, but a few generated files are checked in — `project.pbxproj`, the shared
`xcshareddata/` schemes, `project.xcworkspace/contents.xcworkspacedata`, and `Package.resolved` — so
the project opens and resolves packages without regenerating.

After editing `project.yml`, regenerate before building:

```bash
xcodegen generate
```

**If the project file is missing or out of date, no other command will work — start there.**

An Icon Composer `*.icon` is a *package* (a directory). Without the `fileTypes: icon: file: true`
option, XcodeGen recurses into it and adds its inner files individually, which stops Xcode from
recognizing it as an app icon.

App-wide settings live at **project level** so every target inherits one definition — including
`SWIFT_VERSION`, so a language bump is a one-line edit.

---

## Platform constraints

**Backs:** `project.yml` (project-level `settings:`)

- **Swift 6 strict concurrency is on.** `TranscriptionManager` is `@MainActor`; WhisperKit and
  Sparkle are imported `@preconcurrency` (binary/ObjC frameworks without full `Sendable`
  annotations). New async code crossing the actor boundary must respect this — see
  [concurrency.md](concurrency.md).
- **Deployment target is macOS 26 (Tahoe).** This is a product decision, not an API floor — the
  newest APIs the app uses (`AVAssetExportSession.export(to:as:)`, the `@Observable` macro) are
  available earlier than 26. The binding constraint is the arm64-only argument below. Lowering it
  means updating `project.yml`, regenerating, and auditing what actually stops compiling.
- **CI pins Xcode 26.4.1** on `macos-26` runners.

### arm64 only

`ARCHS: arm64` is pinned at project level rather than left to Xcode's `ARCHS_STANDARD`, which would
add an x86_64 slice.

macOS 26 is the last release supporting Intel and reaches only a handful of 2019–20 models, none of
which have a Neural Engine — and this app **is** local Whisper inference, so the x86_64 slice would
ship a bad experience to a shrinking audience while doubling every compile.

Decided before 1.0.0 shipped, deliberately: **once an arm64+x86_64 build has an installed base,
Sparkle's appcast has no clean way to stop offering an arm64-only update to an Intel user.**

Debug already sets `ONLY_ACTIVE_ARCH`, so this only changes Release (and CI).

---

## Dependencies

**Backs:** `project.yml` (`packages:`)

| Package | Pin | Notes |
| --- | --- | --- |
| WhisperKit | `from: "1.0.0"` | Up-to-next-major: newest `1.x`, never a breaking `2.0`. |
| Sparkle | `from: "2.9.4"` | Binary xcframework; Xcode links and embeds it automatically. |
| ViewInspector | `from: "0.10.3"` | **Test-only** — linked into the unit-test bundle, never the app target. |

Major bumps are manual; the weekly drift check covers `1.x` drift — see
[automation.md#dependency-drift](automation.md#dependency-drift). Be aware of this when debugging
upstream API drift, and read
[testing.md#whisperkit-drift](testing.md#whisperkit-drift) before approving a WhisperKit bump.

The Sparkle zip also carries Sparkle's CLI tools, which is where `publish-release.yml` gets
`generate_appcast`. **Never re-add a tarball download** — see
[distribution.md#the-appcast](distribution.md#the-appcast).

---

## Target layout

**Backs:** `project.yml` (`targets:`, `schemes:`)

- **`Speech2Text`** (application) — also bundles `THIRD-PARTY-LICENSES.md` as a **resource**.
  That file ships *inside* the app bundle, not just in the repo: WhisperKit (MIT), the
  swift-transformers code it vendors (Apache-2.0) and Sparkle (MIT, plus its own vendored
  bsdiff/sais/Ed25519 notices) are all redistributed in the binary, and those licenses require their
  notices to travel with it. The explicit `buildPhase: resources` is needed because a `.md` would
  otherwise be inferred as a non-bundled source file.
- **`Speech2TextTests`** (unit) — sources include `Speech2TextTestSupport`, which holds test-only
  fixtures shared with the integration target so they live in one place rather than on the shipped
  type.
- **`Speech2TextIntegrationTests`** (unit) — `Fixtures/` is excluded from sources and added as
  resources instead. It holds tiny checked-in media samples for formats Apple's stack can decode but
  **not synthesize** (mp3/aac/ogg); everything else is generated at runtime. See
  [testing.md#the-decodability-oracle](testing.md#the-decodability-oracle).
- **`Speech2TextUITests`** (`bundle.ui-testing`) — the one target that uses XCTest rather than the
  repo's Swift Testing convention, and kept out of the main scheme's test action so its TCC/launch
  flakiness can't gate every build.

  `BUNDLE_LOADER: ""` is set explicitly: XcodeGen's test-target preset injects
  `BUNDLE_LOADER = "$(TEST_HOST)"`, which belongs to unit-test bundles, not a ui-testing runner (a
  separate process). `TEST_HOST` is undefined here so it already expands to empty, but suppressing
  it explicitly keeps the generated project from ever implying in-process loading.

A **dedicated, shared scheme** for the UI tests means the default `-scheme Speech2Text test` run
never pulls them in; run them explicitly with `-scheme Speech2TextUITests test`.

### Signing lives on the command line

`CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM` and `ENABLE_HARDENED_RUNTIME` are
**deliberately absent** from `project.yml`. They are injected on the `xcodebuild` command line by
`publish-release.yml` alone, so local development and every `CODE_SIGNING_ALLOWED=NO` CI build stay
untouched by the release configuration.

UI tests are the one exception among *test* jobs to `CODE_SIGNING_ALLOWED=NO` (an unsigned test
runner is killed before it can attach); `publish-release.yml` also builds signed, with a Developer
ID identity — see
[automation.md#integration-and-ui-jobs](automation.md#integration-and-ui-jobs).

---

## Info.plist keys

**Backs:** `Info.plist`

The app uses a manual `INFOPLIST_FILE` with **no** `GENERATE_INFOPLIST_FILE`, so `xcodebuild` does
not auto-populate the usual keys. That is why `CFBundleIdentifier`, `CFBundleExecutable` and
`CFBundlePackageType` are all spelled out: without them the bundle carries no executable or
package-type declaration and `PkgInfo` comes out as `????????`. They use build-setting macros rather
than literals so they track the build settings.

`CFBundleIdentifier` in particular is required by XCUITest to identify the target app.

Version keys map from the build settings — see
[distribution.md#version-lockstep](distribution.md#version-lockstep).

The Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`) are covered in
[distribution.md#the-seam](distribution.md#the-seam).
