# Distribution and updates

Speech2Text ships through **one channel**: a direct download from
[GitHub Releases](https://github.com/popavel/speech2text/releases) and the project website,
Developer ID-signed, hardened-runtime, notarized and stapled, self-updating via **Sparkle 2**
against an EdDSA-signed appcast.

There is deliberately no Mac App Store build, and therefore no second app target, no sandboxing
(`Speech2Text.entitlements` declares `com.apple.security.app-sandbox` as `<false/>`;
`publish-release.yml` reads that key off the signed product and fails only on an explicit `true`,
since an absent key legitimately means "not sandboxed"), and no `SPARKLE_ENABLED` compile
condition — Sparkle compiles unconditionally
because nothing has to be built without it. (An earlier, unmerged experiment carried a
dual-channel setup; going App-Store-free is what makes all that scaffolding unnecessary. Don't
reintroduce it without a channel that needs it.)

The Sparkle seam and the release pipeline are one file on purpose: the same handful of facts were
written out in `Updater.swift`, `AGENTS.md`, `publish-release.yml`, `Info.plist` **and**
`.github/workflows/README.md`, and splitting them re-opens that seam. (`AGENTS.md` still carries its
copy until the migration finishes — see [README.md](README.md).)

---

## The seam

**Backs:** `Speech2Text/Updater.swift` · `Speech2Text/Speech2TextApp.swift` · `Info.plist`

Views depend on the `UpdaterModel` protocol, **never** on Sparkle, so unit tests inject a
`FakeUpdater`. This is not stylistic. A real `SPUUpdater` persists its preferences straight into
the app's `.standard` `UserDefaults` domain — it has no injectable store — and the in-process test
host shares that domain with the developer's real installed app. Unit tests run *inside* the app
here (test host = the app, so `Speech2TextApp.init` executes on every test run). Same hermetic-DI
convention as the manager's injectable `UserDefaults`.

`SparkleUpdating` is the slice of `SPUUpdater` the model actually drives: a **readable**
`canCheckForUpdates` (readable, not merely observable, so the model can seed from it and re-read the
live value after hopping), the settable auto-check preference, a manual check, and the two KVO
streams it mirrors. It exists so the model's **live**
branch — the Sparkle seed, both observations, both write paths — can run under test with **no
Sparkle object in the process at all**.

The observations are *vended by the conformer* rather than registered by the model, because
`observe(_:options:changeHandler:)` needs a concrete `Self` and a `KeyPath<Self, Value>` over an
`@objc dynamic` property, neither of which an existential can express. Each conformer registers KVO
on its own storage and hands back the `NSKeyValueObservation`, whose lifetime the model owns.

`SparkleUpdating` is `@MainActor` because Sparkle annotates `SPUUpdater` as `NS_SWIFT_UI_ACTOR`, so
a nonisolated protocol cannot be conformed to it ("conformance crosses into main actor-isolated
code"). The handlers are `@Sendable` because Foundation's KVO overlay declares its `changeHandler`
that way; they capture only `[weak self]` on a `@MainActor` class, so it costs nothing.

The `extension SPUUpdater: SparkleUpdating` is **kept irreducibly thin on purpose**: it is the one
piece of the live path a test cannot execute (it needs a real `SPUUpdater`), so every decision that
could be wrong — which options, what the handler does with the change — lives on the model's side
of the seam instead.

### `controller` is ownership only

`SparkleUpdaterModel.controller` is never read. It is the **sole strong reference** to
`SPUStandardUpdaterController`, whose `.updater` is what the model actually drives; without it the
controller — and the standard user driver it owns, which puts Sparkle's UI on screen — would
deallocate at the end of `init(startingUpdater:)`. Dead as data, live as a lifetime anchor:
unused-looking and unsafe to delete. `delegate` is held for the same reason —
`SPUStandardUpdaterController` keeps its `updaterDelegate` outlet `__weak`, so without a strong
reference the busy-check guard would deallocate immediately. Checks would still run on schedule
(the delegate never gates those — see [below](#relaunch-not-check)); what would be lost is the
postpone hook, so an update could install and **relaunch mid-transcription**, destroying the
in-memory transcript.

Do not restore reads through `controller`. The write paths and the init branch all key off
`updater`'s nil-ness, which is what keeps the gated, injected and shipping shapes on one code path.

**Nil-ness of `controller` is *not* the hermeticity guarantee** — an injected model has a nil
controller and a live `updater`. The guarantee that matters is structural and belongs to the
initializers (below).

### `SUFeedURL` is permanent

The feed URL in `Info.plist` uses GitHub's stable latest-release-asset redirect. It is baked into
every shipped binary and is effectively permanent: **changing it strands every copy installed
before the change.** `SUPublicEDKey` is the public half of the EdDSA keypair; updates are rejected
unless signed by the matching private key. `SUEnableAutomaticChecks` turns on the ~daily check
without Sparkle's second-launch permission prompt; the Settings "Updates" toggle is the per-user
opt-out.

Sparkle owns its preferences (`SUEnableAutomaticChecks`, `SULastCheckTime`, …) in the app's
defaults domain, deliberately **outside** `TranscriptionManager.Keys.all` — so "Remove All App
Data" and "Restore Default Settings" leave them alone.

---

## Three initializers

**Backs:** `Speech2Text/Updater.swift` (`SparkleUpdaterModel`)

`SparkleUpdaterModel` has three initializers on purpose. **Don't collapse them** — the guarantee
then moves from the compiler to branch ordering.

| Initializer | Role |
| --- | --- |
| `init(startingUpdater:isBusy:)` | The production front door, and the **only** one that *constructs* a Sparkle object. |
| `init(updater:)` | The test door. It names **no Sparkle type at all**, so it structurally cannot bring an `SPUUpdater`/`SUHost` into existence. |
| `private init(controller:updater:delegate:)` | The one designated init, holding everything downstream of "which driver do I have", so the injected path and the shipping path execute the **same lines**. |

Why this shape: `SPUUpdater.init` — started or not — builds an `SUHost` over the shared `.standard`
defaults domain and registers KVO observers on it. A gated model must therefore construct **no
Sparkle object at all**, not merely leave one unstarted. The designated init names
`SPUStandardUpdaterController` in its signature but only stores what it is handed; the test door
names nothing. That last part is the compiler's guarantee rather than a branch ordering's — which
is the entire argument for three initializers instead of one.

A test of the injected path is therefore a test of the shipping path, not of a parallel copy.

A **gated** model seeds its toggle from the shipped `Info.plist` default rather than Sparkle's
`SUHost` resolution (defaults first, Info.plist as fallback), so the initial value can't depend on
the developer's real app settings — deterministic on any machine.

---

## Relaunch, not check

**Backs:** `Speech2Text/Updater.swift` (`UpdaterDelegate`, `mayRelaunchForUpdate`)

`UpdaterDelegate` has one job: **never relaunch over work in progress.** A transcription can run
for minutes and its result lives only in memory, and a data wipe mid-`removeItem` would leave a
half-deleted cache — so installing an update at either moment destroys something the user can't get
back. It implements `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`, deferring the
install until `isProcessing`/`isRemovingData` clears.

### Why not refuse the check

Refusing the check (`updater(_:mayPerform:)`) looks tempting and is worse on both counts.

(That Swift name looks wrong and isn't: the ObjC selector is
`updater:mayPerformUpdateCheck:error:`, but the importer drops `error:` into `throws` and
omit-needless-words shortens `mayPerformUpdateCheck:` to `mayPerform:` because the argument is
already an `SPUUpdateCheck`. Verified by type-check — don't "correct" it.)

1. Sparkle records a refused check as a **completed** one — `abortUpdateDriver` calls
   `updateLastUpdateCheckDate` and reschedules with `usingCurrentDate:NO` — so a user who happens
   to be transcribing when the daily check fires has updates pushed a further **~24h** out, every
   time.
2. It does nothing about the actual hazard, which is the user accepting an alert that appeared
   while they were idle and starting work in the seconds before they click.

### If the app never goes idle, nothing installs

Sparkle's header is explicit that the handler "must be completed", and there is no termination
fallback on the framework side: quitting installs nothing, because the installer was never told to
proceed. Worse, **the update session stays open for the life of the process** — `SPUUpdater` keeps
`_driver` non-nil, which holds `canCheckForUpdates` false, so "Check for Updates…" is dead too and
the user can't even retry by hand. Recovery is the next launch, which re-probes for an in-progress
installer or re-checks the feed.

So this loop's liveness is **not optional**: it rests on `isBusy()` eventually clearing, which is
exactly why both halves of model loading are bounded. See
[concurrency.md#idle-timeout-arithmetic](concurrency.md#idle-timeout-arithmetic). Model loading is
the *reachable* wedge, not the only one — a transcription whose input sits on a network volume that
vanishes mid-export can hang too, and that path is knowingly unbounded.

Polling rather than observing keeps this to one self-contained task with no lifetime coupling to
the manager. The sleep is **not** `try?`: that swallows cancellation, and a cancelled task would
then spin the loop on the main actor and freeze the UI. It bails instead, leaving the update for
the next launch. (Nothing retains the task's handle, so nothing can cancel it — the `catch` is
belt-and-braces rather than a live path.)

### Two things this deliberately does not worry about

Both checked against Sparkle's source so they don't get re-litigated:

- **A second concurrent postpone task is impossible.** `SPUInstallerDriver` sets `_postponedOnce`
  before calling this and never asks again, and `SPUUpdater` refuses to start a second session
  while a driver is alive.
- **A late `installHandler()` cannot cause a surprise relaunch.** The block Sparkle passes captures
  the driver weakly, so once the session is gone, invoking it does nothing.

### It is a mitigation, not a guarantee

Don't document it as one. `SPUUpdaterDelegate.h` says this hook "is not called if the user didn't
relaunch on the previous update, in that case it will immediately restart", and "may also not be
called if the application is not going to relaunch after it terminates". **A user in either state
who accepts an update mid-transcription still loses the in-memory transcript.**

The real fix is to stop treating the transcript as unrecoverable — persist it, or warn before
discarding it — which would also cover the plain quit case that already loses it today. Not done.

### The `@objc` selector pin

The Swift label really is `untilInvokingBlock:`. `untilInvoking:` compiles fine but only "nearly
matches" the optional requirement, so it would **never be called** — and that is a *warning* only,
with nothing here promoting warnings to errors. The typo therefore used to yield a green build and
a green suite with the hook silently dead.

The explicit `@objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` is what keeps it
wired: the ObjC runtime dispatches on the selector, so renaming the Swift label can no longer
detach the method (verified — with the label wrong and the pin in place, Sparkle still finds it).
The pin is of course as typo-able as the label was, which is why
`postponeHookSelectorIsWired` asserts the selector itself — see
[testing.md#selector-tripwire](testing.md#selector-tripwire).

`UpdaterDelegate` is internal rather than private — unlike its `AboutMenuCommand`/`HelpMenuCommand`
siblings, though `CheckForUpdatesCommand` is internal too, for the same testability reason — so that
test can construct one. Constructing it is hermetically safe: `init(isBusy:)` takes only a closure and
names no Sparkle type. `mayRelaunchForUpdate` is a pure function of its input, deliberately,
because the delegate method that consults it takes an `SPUUpdater` and an `SUAppcastItem` — neither
of which a test may construct.

---

## KVO mirrors

**Backs:** `Speech2Text/Updater.swift` (the designated initializer)

`automaticallyChecksForUpdates` is **explicit storage plus write-through, not a `didSet` mirror.**
Under `@Observable`, an init-time assignment runs the setter, which would write
`SUEnableAutomaticChecks` into the shared domain during the test host's app init. Reading the
stored property keeps SwiftUI observation tracking; writes forward to Sparkle, which persists. A
gated model has no updater, so the write stays in memory.

### Never `MainActor.assumeIsolated`

Of the `SPUUpdater` properties this model touches, `canCheckForUpdates` is the **one** Sparkle's
header does *not* document as main-thread-only — `automaticallyChecksForUpdates`,
`automaticallyDownloadsUpdates` and `updateCheckInterval` all say "must be called on the main
thread"; it doesn't, being a readonly property driven by internal session state.

`assumeIsolated` on an off-main delivery would **trap and kill the shipped app**, and no test could
catch it because a fake only ever mutates on the main actor. So **both** observations hop with
`Task { @MainActor }` and re-read the live value on arrival — which also means an out-of-order hop
can't apply a stale value. KVO is delivered on the mutating thread and nothing guarantees that is
the main one; an unstructured hop carries no ordering guarantee, so applying a captured value could
overwrite a newer write, while re-reading always converges on Sparkle's current truth. (The echo of
our own setter's write-through re-applies an identical value — harmless.) Re-deriving `updater`
through `self` on the main actor keeps the non-Sendable Sparkle object from crossing the isolation
boundary and adds no lifetime extension.

Both mirrors seed by **direct read** and re-read on change, so the value always comes from the same
source and no captured payload can be applied out of order.

### Scope of the auto-checks mirror

This is KVO on `SPUUpdater.automaticallyChecksForUpdates`, so it fires for writes **through that
property** — Sparkle's own update-permission UI, and our setter's write-through. It exists so the
Settings toggle can't go stale when something other than our setter changes the preference.

An external `defaults write` of the underlying `SUEnableAutomaticChecks` key while the app runs
lands here **too**, but by way of Sparkle rather than of anything in this file: since **2.8.0**
("Synchronize updater settings with user defaults", #2728), `SUHost.observeChangesFromUserDefaultKeys:`
KVO-observes the defaults domain, `SPUUpdaterSettings.processCurrentAutomaticallyChecksForUpdates`
re-reads and posts an explicit `will`/`didChangeValueForKey:`, and
`+keyPathsForValuesAffectingAutomaticallyChecksForUpdates` propagates that to the updater property
observed here.

**So do NOT add a second observation on `UserDefaults.standard` to "close the gap"** — there is
none, and reaching for the shared domain here is the exact coupling the three initializers exist to
prevent.

That last leg is upstream behaviour neither owned nor tested here (exercising it needs a real
`SPUUpdater`, which no test may construct), and it is Sparkle *implementation* rather than a
promise in its header — verified against the pinned 2.9.4 sources. Treat it as a nicety Sparkle
currently provides, not an invariant of this file.

---

## The launch gate

**Backs:** `Speech2Text/Updater.swift` (`shouldStartUpdater`, `isDebugBuild`,
`testEnvironmentMarkers`, `autoChecksDefaultsKey`)

**Debug builds never start the updater.** A developer's `⌘R` run is not a shipped app: starting
Sparkle there binds an `SUHost` to the real `com.speech2text.app` defaults domain and writes
`SULastCheckTime` and friends into the preferences of whatever copy the developer has installed —
the same cross-talk the three initializers and the fakes exist to prevent. Worse,
`CURRENT_PROJECT_VERSION` in a working tree is routinely *older* than the published feed head, so
Sparkle would eventually offer to replace the DerivedData build with a download. Release is the
only configuration that ships, and the only one that updates.

The `-uiTesting` and XCTest marker checks sit behind that as belt-and-braces — unit tests run *in*
the app, and XCUITest launches the real app with `-uiTesting`. They are unreachable while tests only
ever run in Debug, and are kept so that running a suite against a Release build doesn't silently
start an updater.

**That is the whole of what they buy, and the limit is worth stating.** They do not make a
Release-built test run isolated: `Speech2TextApp.init` reaches `uiTestSettingsStore()` only inside
`#if DEBUG`, so the same launch this gate declines to start an updater for is persisting its
settings to `.standard` — the developer's real preferences. The scopes differ deliberately rather
than by oversight. The seam *injects state* from argv and the environment (a preloaded file queue,
a stubbed transcript), which must not exist in a shipped binary where any process could drive it;
this gate only *declines to act*, so it is safe to keep unconditional and cheap to leave in.
Aligning the two would mean either shipping the injection seam or deleting the one check here that
does anything at all in Release.

`isDebugBuild` is an **injectable parameter** rather than a `#if` in the body, so
`UpdaterTests.swift` can test **both** answers — including the one combination that ships — from a
test run that is itself always Debug. All three inputs are injectable for the same reason.

`testEnvironmentMarkers` is a named constant so the gate and its parameterized tests share one
list; `autoChecksDefaultsKey` is named so the *gated Info.plist seed* in the designated initializer
and the gate suite's snapshot/restore share one spelling. Either fork would leave the tests
exercising a key the model no longer touches, passing vacuously.

`CheckForUpdatesCommand` is a dedicated command `View` (Sparkle's documented menu-item pattern):
SwiftUI Observation re-evaluates its body when the observable `canCheckForUpdates` changes, which is
what keeps the disabled state fresh — Commands have no AppKit-style re-validation on menu open to
fall back on. It is internal, not private, so render tests can drive it against a `FakeUpdater`.

---

## Version lockstep

**Backs:** `project.yml` · `.github/workflows/publish-release.yml` · `Speech2Text/AboutView.swift`

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live at **project level** in `project.yml` and
are always bumped **together to the same `X.Y.Z`**. Sparkle orders releases by `CFBundleVersion`
(its comparator handles dotted triples), and `AboutView` collapses the display to "Version X.Y.Z"
when build == short. The publish workflow hard-fails when the pushed tag doesn't equal them.

**`0.x.y` is the pre-release series; `1.0.0` and above are reserved for the first genuinely
user-facing release.**

---

## The appcast

**Backs:** `.github/workflows/publish-release.yml` · `project.yml` (the Sparkle package)

**Sparkle version skew is impossible by construction.** `publish-release.yml` runs
`generate_appcast` straight out of the resolved SwiftPM package store
(under `DerivedData/SourcePackages/artifacts/`, located with a `find` rather than a hardcoded path,
so a SwiftPM layout change fails loudly instead of silently) — Sparkle ships its CLI tools inside
the same zip the framework comes from, which SwiftPM fetches for a `binaryTarget(checksum:)` and
rejects on a SHA-256 mismatch. So the tool that receives the EdDSA private key is the exact
artifact the app embeds, integrity-checked.

**Never re-download it.** Sparkle's release tarballs are ad-hoc signed, so a download can't be
verified and would hand a signing secret to unauthenticated code.

**The ZIP and the DMG live in separate directories.** `generate_appcast` treats *every archive in
its input directory* as an update entry, so `artifacts/` holds exactly one archive — the Sparkle
zip — alongside the generated appcast and release-notes HTML; the DMG goes to `dist/` and the
dSYMs to `dsyms/`.

### The appcast carries exactly one item

`artifacts/` starts empty each run and the previous feed is never fetched, so every release
publishes a single-entry appcast. Two consequences, neither biting today:

- raising `LSMinimumSystemVersion` in a future release would leave users on the older OS with a
  feed containing nothing they can install, and so no update path;
- Sparkle can't generate delta updates without the prior archives.

Both are fixed the same way — download the previous release's archives into `artifacts/` before
`generate_appcast` runs.

---

## Verify the artifact, not the source

**Backs:** `.github/workflows/publish-release.yml`

**Every channel fact is checked on the ARTIFACT, not only the source.** A source guard proves what
the repo says; only a product-level one proves what ships. `publish-release.yml` re-reads the built
bundle's versions, hardened-runtime flag, sandbox state, embedded `Sparkle.framework`, and
`SUFeedURL`/`SUPublicEDKey` — because a build that silently lost its feed URL launches clean, never
updates, and becomes the permanent feed head.

### Draft first, publish last

The release is created as a **draft** while assets upload, then flipped to published in one final
step. `releases/latest` — the live feed URL baked into every shipped binary — already redirects to
the tag while assets are still uploading, so a non-draft release would 404 for apps polling in that
window.

But **never leave a release draft or prerelease**: the `latest` redirect skips those and installed
apps silently stop seeing updates. A late step guarded by
`always() && steps.create_draft.outcome != 'skipped'` alarms if that happens. (It is not the very
last step — the keychain/secret cleanup runs after it.)

### Concurrency is keyed per tag

Deliberately not repo-wide. GitHub keeps only one *pending* run per group and cancels the
previously pending one — push `v0.0.2`, `v0.0.3`, `v0.0.4` in quick succession and v0.0.3's run is
discarded without executing a step, leaving a tag with nothing published. Concurrent publishes are
instead handled where they actually race: the publish step declines `--latest` when a newer release
already exists, and re-checks afterwards. That check is best-effort, **not atomic** — GitHub offers
no compare-and-set for the latest flag, so two publishes finishing within the same few seconds can
still interleave; the post-flip re-check turns that into a loud warning instead of a silent
regression.

### Why the preflight checks the secrets

GitHub substitutes an **empty string** for a secret that does not exist, so a renamed secret, a
re-created repo, or a `workflow_dispatch` from an environment without them looks identical to a
good run until it fails deep into a long job: `APPLE_TEAM_ID` at codesign (~20 m), the `ASC_*` trio
at notarization (~25 m), `SPARKLE_ED_PRIVATE_KEY` at `generate_appcast` (~45 m, after two
notarization round-trips — and the keypair check cannot catch that one, because an absent key
decodes to 0 bytes and lands in the legacy-format branch that exists to avoid accusing a *valid*
key of not matching). All of them are collected before reporting: one missing secret per re-tag is
a miserable way to configure a repo. Names only, never values.

`DEVID_CERT_PASSWORD` is deliberately **absent** from that list: a `.p12` can legitimately be
exported with an empty password, and `security import -P ""` accepts one — so here, unlike every
other entry, "empty" is a valid configuration rather than a missing secret. It is also consumed
before the build (~2 m in), so it has nothing to gain from an early warning.

The **whitespace** check is scoped to `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` only. A value
pasted out of App Store Connect with a trailing newline is still "present", so the presence loop
waves it through — and it is not a parse error at the consuming site either, because every one of
them double-quotes it: the newline rides along *inside* the argument. `DEVELOPMENT_TEAM="TEAM\n"`
then fails codesign ~20 m in, and a `notarytool --key-id`/`--issuer` carrying one fails auth ~25 m
in with a credentials error that names nothing. An `env:` block does **not** help — an environment
variable preserves a trailing newline exactly.

The other three secrets are legitimately multi-line (`DEVID_CERT_P12_BASE64` and
`SPARKLE_ED_PRIVATE_KEY` are base64, wrapped output is normal and `base64 -d` tolerates it;
`ASC_API_KEY_P8` is a PEM), so whitespace-checking them would reject valid credentials and block
every release. The check is **format-agnostic** on purpose too: asserting a shape (10
alphanumerics, a UUID) would hardcode Apple's current formats and turn a format widening into a
failed release, whereas "contains no whitespace" can never reject a credential that would otherwise
work. Shell-metacharacter injection is closed by the `env:` blocks, not here.

### The keypair check

The preflight also proves `SPARKLE_ED_PRIVATE_KEY` and the `SUPublicEDKey` in `Info.plist` are **one
keypair**. If the private key were rotated without updating the public half (or vice versa),
`generate_appcast` would still happily sign and publish, and every installed copy would then
**reject** the update — silently losing its update path with no way to push a fix. Checked in
seconds rather than after ~45 minutes of building and two notarization round-trips.

Sparkle's exported key is the raw 32-byte ed25519 **seed**, so the public half has to be derived by
scalar multiplication — no shell-only byte slicing can do it. Wrapping the seed in a fixed PKCS#8
prefix lets OpenSSL derive it, and that needs **real OpenSSL 3**: `/usr/bin/openssl` on macOS is
LibreSSL, which doesn't support ed25519 here.

Capture then match, never `… | grep -q`: a SIGPIPE under `pipefail` would leave the variable empty
and silently downgrade the check to a warning. The same pattern guards the hardened-runtime check.

An absent key decodes to 0 bytes and lands in the legacy-format branch — which exists so a *valid*
key is never accused of not matching — so this check cannot substitute for the presence check above.

### Claiming `--latest`

The feed URL is `releases/latest/download/appcast.xml`, and GitHub's `latest` redirect skips drafts
**and** prereleases. So the publish step claims `--latest` only if this really is the newest
release: two tags can be in flight at once, and the run that finishes last must not drag the feed
back to an older build.

**Only version tags take part in the comparison.** A single non-version release tag (say `nightly`)
would otherwise sort above every `vX.Y.Z` and permanently pin the highest, so every future release
would publish with `--latest=false` and the feed would freeze — visible only as a warning on an
otherwise green job. Prereleases are excluded for the mirror-image reason: a published prerelease
must not veto this release's claim.

**No `|| true` on that query, deliberately.** An empty list is indistinguishable from a transient API
error, and guessing "there is nothing newer" is exactly how an older concurrent release would steal
`--latest` and drag the feed backwards. Failing instead leaves an invisible draft — `releases/latest`
keeps serving the previous good release — and the stranded-draft alarm says to re-run.

---

## Release runbook

1. Bump **both** versions in `project.yml` to the same `X.Y.Z`.
2. `/precommit` → PR → merge to `main`.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. `publish-release.yml` runs. The **build+test gate is a separate job** that must finish first
   (`publish: needs: build-and-test`) — a release never ships code that hasn't passed the suite.
   The publish job then runs: preflight → `xcodegen` → cert import → Release build → verify
   product → notarize + staple → Sparkle zip → DMG → dSYMs zip → appcast → draft release →
   publish.
5. Spot-check
   `curl -sL https://github.com/popavel/speech2text/releases/latest/download/appcast.xml`.

Artifacts produced: `Speech2Text-X.Y.Z.zip` (the Sparkle update payload), `Speech2Text-X.Y.Z.dmg`
(the human download), `appcast.xml` (the signed feed), `Speech2Text-X.Y.Z-dSYMs.zip` (symbols).

## Secrets

All already set on the repo.

| Secret | What it is |
| --- | --- |
| `SPARKLE_ED_PRIVATE_KEY` | From Sparkle's `generate_keys -x`. The public half is `SUPublicEDKey` in `Info.plist`. **Losing the private key strands every installed copy** — keep the Keychain and secret copies. |
| `DEVID_CERT_P12_BASE64` / `DEVID_CERT_PASSWORD` | Developer ID Application certificate. |
| `APPLE_TEAM_ID` | Signing team. |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_P8` | App Store Connect API key — still needed with no App Store channel, because `notarytool` authenticates with it. |

---

## Upstream facts (Sparkle 2.9.4)

Re-verify these on a Sparkle bump. They are implementation details read out of the pinned sources,
not promises in Sparkle's headers.

- `SPUUpdater.init` binds an `SUHost` to the `.standard` defaults domain and registers KVO on it —
  **started or not**.
- `abortUpdateDriver` calls `updateLastUpdateCheckDate` and reschedules with `usingCurrentDate:NO`,
  so a refused check counts as a completed one (~24 h deferral).
- `SPUInstallerDriver` sets `_postponedOnce` before calling the postpone hook and never asks again;
  `SPUUpdater` refuses a second session while a driver is alive.
- The install block Sparkle passes to the postpone hook captures the driver **weakly**.
- An open update session keeps `_driver` non-nil, which holds `canCheckForUpdates` false for the
  life of the process.
- `SPUUpdaterDelegate.h`: the postpone hook is skipped if the user declined to relaunch on a
  previous update, and may be skipped if the app is not going to relaunch at all.
- Since **2.8.0** (#2728), `SUHost.observeChangesFromUserDefaultKeys:` propagates external
  `defaults write`s of `SUEnableAutomaticChecks` through to the updater property.
- `SPUStandardUpdaterController` holds `updaterDelegate` **weakly**.
- Of the properties this model touches, only `canCheckForUpdates` is **not** documented
  main-thread-only.
