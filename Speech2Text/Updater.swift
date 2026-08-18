import Foundation
import SwiftUI

// Binary ObjC framework without full Sendable annotations — same treatment as WhisperKit.
@preconcurrency import Sparkle

// The in-app update mechanism. Speech2Text is distributed directly (Developer ID-signed and
// notarized, from GitHub Releases and the project website) and self-updates via Sparkle against
// the appcast at `SUFeedURL` in Info.plist. See AGENTS.md "Distribution & updates".

/// What the views need from an updater. Views depend on this protocol, not on Sparkle, so unit
/// tests inject a `FakeUpdater` — a real `SPUUpdater` persists its preferences straight into the
/// app's `.standard` UserDefaults domain (it has no injectable store), which the in-process test
/// host shares with the developer's real app. Same hermetic-DI convention as the manager's
/// injectable `UserDefaults`.
@MainActor
protocol UpdaterModel: AnyObject, Observable {
    /// Whether this model drives a real updater at all. False in gated processes (any Debug
    /// build, a test host, `-uiTesting`), where the update controls would otherwise look live but
    /// do nothing — writes are kept in memory and re-seeded from Info.plist on the next launch.
    /// Constant for the model's lifetime, unlike `canCheckForUpdates`, which also goes false
    /// mid-check.
    var isActive: Bool { get }

    /// Whether a manual check can start now (false while the updater is off or mid-session).
    var canCheckForUpdates: Bool { get }
    /// The user's "check automatically" preference (Settings toggle). The Sparkle-backed model
    /// persists this via Sparkle itself (`SUEnableAutomaticChecks` in the app's defaults domain).
    var automaticallyChecksForUpdates: Bool { get set }
    /// Kick off a user-initiated update check (shows Sparkle's UI, including errors).
    func checkForUpdates()
}

/// The slice of `SPUUpdater` that `SparkleUpdaterModel` actually drives: the settable auto-check
/// preference, a manual check, and the two KVO streams it mirrors. Exists so the model's LIVE
/// branch — the Sparkle seed, both observations, both write paths — can run under test against a
/// fake with NO Sparkle object in the process. That matters because a real `SPUUpdater`, started
/// or not, binds an `SUHost` to the app's shared `.standard` defaults domain, which the in-process
/// test host shares with the developer's real app (see `controller` below and AGENTS.md).
///
/// The observations are VENDED by the conformer rather than registered by the model, because
/// `observe(_:options:changeHandler:)` needs a concrete `Self` and a `KeyPath<Self, Value>` over an
/// `@objc dynamic` property — neither of which an existential can express. Each conformer registers
/// KVO on its own storage and hands back the `NSKeyValueObservation`, whose lifetime the model owns.
///
/// `@MainActor` because Sparkle annotates `SPUUpdater` as `NS_SWIFT_UI_ACTOR`, so a nonisolated
/// protocol cannot be conformed to it ("conformance crosses into main actor-isolated code"). That
/// matches the model, which is `@MainActor` too. The handlers are `@Sendable` because Foundation's
/// KVO overlay declares its `changeHandler` that way; they capture only `[weak self]` on a
/// `@MainActor` (hence implicitly `Sendable`) class, so the requirement costs nothing.
@MainActor
protocol SparkleUpdating: AnyObject {
    /// Whether Sparkle can start a check right now. Readable (not just observable) so the model
    /// can seed from it and re-read the live value after hopping to the main actor, rather than
    /// applying a possibly-stale value captured in a KVO change payload.
    var canCheckForUpdates: Bool { get }

    /// Sparkle's persisted "check automatically" preference (`SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool { get set }

    /// Start a user-initiated check (Sparkle shows its own UI, including errors).
    func checkForUpdates()

    /// KVO over `canCheckForUpdates`. The model neither seeds from this nor reads the change
    /// payload — it seeds by direct read and re-reads the live value on the main actor (see the
    /// handler) — so no `options` and no change struct are load-bearing. Symmetric with the
    /// auto-checks vendor below, deliberately: one delivery shape for both mirrors.
    func observeCanCheckForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation

    /// KVO over `automaticallyChecksForUpdates`. Same shape as the vendor above, for the same
    /// reason: the model seeds by direct read and re-reads the live value after hopping to the
    /// main actor, so neither `options` nor the change struct is load-bearing here either.
    func observeAutomaticallyChecksForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation
}

/// `SPUUpdater` already satisfies the value half of `SparkleUpdating` — `checkForUpdates()` and the
/// settable `automaticallyChecksForUpdates` are its own API — so only the two observation vendors
/// are added here, each a one-line forward to Foundation's KVO overlay over Sparkle's `@objc
/// dynamic` properties. Kept irreducibly thin ON PURPOSE: this extension is the one piece of the
/// live path a test cannot execute (it needs a real `SPUUpdater`), so every decision that could be
/// wrong — which options, what the handler does with the change — lives on the model's side of the
/// seam instead.
extension SPUUpdater: SparkleUpdating {
    func observeCanCheckForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation {
        observe(\.canCheckForUpdates, options: []) { _, _ in changeHandler() }
    }

    func observeAutomaticallyChecksForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation {
        observe(\.automaticallyChecksForUpdates, options: []) { _, _ in changeHandler() }
    }
}

/// Sparkle's delegate. One job: never relaunch over work in progress. A transcription can run for
/// minutes and its result lives only in memory (`TranscriptionManager.transcriptionResult`), and a
/// data wipe mid-`removeItem` would leave a half-deleted cache — so installing an update at either
/// moment destroys something the user can't get back.
///
/// It guards the RELAUNCH, deliberately not the check. Refusing the check
/// (`updater(_:mayPerform:)`) looks tempting but is worse on both counts: Sparkle records a
/// refused check as a completed one — `abortUpdateDriver` calls `updateLastUpdateCheckDate` and
/// reschedules with `usingCurrentDate:NO` — so a user who happens to be transcribing when the
/// daily check fires has updates pushed a further ~24h out, every time; and it does nothing about
/// the actual hazard, which is the user accepting an alert that appeared while they were idle and
/// starting work in the seconds before they click.
///
/// Retained by `SparkleUpdaterModel` — `SPUStandardUpdaterController` holds its delegate weakly.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let isBusy: @MainActor () -> Bool

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
    }

    /// Returning `true` defers the install and relaunch until `installHandler` is invoked. We
    /// invoke it as soon as the app goes idle; if it never does, the update simply installs on the
    /// next launch, which is Sparkle's normal fallback. Polling (rather than observing) keeps this
    /// to one self-contained task with no lifetime coupling to the manager.
    ///
    /// NOT a complete guarantee, and don't document it as one. `SPUUpdaterDelegate.h` says this
    /// hook "is not called if the user didn't relaunch on the previous update, in that case it
    /// will immediately restart", and "may also not be called if the application is not going to
    /// relaunch after it terminates". A user in either state who accepts an update mid-run still
    /// loses the in-memory transcript. Closing that hole properly means persisting the transcript
    /// (or warning before it is discarded), which is a separate change — see the "Distribution &
    /// updates" note in AGENTS.md.
    /// The label really is `untilInvokingBlock:` — `untilInvoking:` compiles fine but only
    /// "nearly matches" the optional requirement, so it would never be called.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !SparkleUpdaterModel.mayRelaunchForUpdate(isBusy: isBusy()) else { return false }

        Task { @MainActor [isBusy] in
            while isBusy() {
                // NOT `try?`: that swallows cancellation, and a cancelled task would then spin
                // this loop on the main actor and freeze the UI. Bail instead — the update
                // installs on the next launch, Sparkle's normal fallback.
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            installHandler()
        }
        return true
    }
}

/// The Sparkle-backed `UpdaterModel`, owning the app's one `SPUStandardUpdaterController`
/// (standard Sparkle UI, no delegates). `@MainActor` like the rest of the app's state; Sparkle
/// drives its own UI on the main thread.
@MainActor
@Observable
final class SparkleUpdaterModel: UpdaterModel {
    /// OWNERSHIP ONLY — never read. This is the sole strong reference to the controller, whose
    /// `.updater` is what `updater` below actually drives; without it the controller (and the
    /// standard user driver it owns, which puts Sparkle's UI on screen) would deallocate at the
    /// end of `init(startingUpdater:)`. So it is dead as data and live as a lifetime anchor:
    /// unused-looking and unsafe to delete. Do not restore reads through it — the write paths and
    /// the init branch all key off `updater`'s nil-ness, which is what keeps the gated, injected
    /// and shipping shapes on one code path.
    ///
    /// Non-nil only on the production path (`init(startingUpdater:)` with the gate open); the
    /// gated path and the test door both pass nil. That is why nil-ness HERE is not the
    /// hermeticity guarantee — an injected model has a nil controller and a live `updater`. The
    /// guarantee that matters is structural and belongs to the initializers: `SPUUpdater.init` —
    /// started or not — builds an `SUHost` over the shared `.standard` defaults domain and
    /// registers KVO observers on it, so a gated model must construct no Sparkle object at all,
    /// not merely leave it unstarted. `init(startingUpdater:)` is the only initializer that
    /// CONSTRUCTS one — the designated init below names `SPUStandardUpdaterController` in its
    /// signature but only stores what it is handed, and the test door names no Sparkle type at
    /// all, so it cannot bring one into existence even by accident. That last part is the
    /// compiler's guarantee rather than a branch ordering's.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// What this model actually drives: `controller?.updater` on a live model, an injected fake on
    /// a test model, nil on a gated one. Nil-ness (not `controller`'s) is what the write paths and
    /// the init branch key off, so the gated and injected shapes share one code path — and so the
    /// branch a test exercises is the branch that ships, not a copy of it.
    @ObservationIgnored private let updater: (any SparkleUpdating)?
    /// OWNERSHIP ONLY, like `controller`: `SPUStandardUpdaterController` holds its updater
    /// delegate weakly, so without this strong reference the busy-check guard would deallocate
    /// immediately and scheduled checks would resume interrupting transcriptions.
    @ObservationIgnored private let delegate: UpdaterDelegate?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var autoChecksObservation: NSKeyValueObservation?

    /// Mirror of `SPUUpdater.canCheckForUpdates` (KVO → `@Observable` stored property, so the
    /// menu item's disabled state tracks it). Stays false when there is no live updater.
    private(set) var canCheckForUpdates = false

    /// See `UpdaterModel.isActive`. Keyed off `updater`, like every other branch in this type, so
    /// the gated and injected shapes stay on one code path.
    var isActive: Bool { updater != nil }

    /// Explicit storage + write-through — deliberately NOT a `didSet` mirror: under `@Observable`,
    /// an init-time assignment runs the setter, which would write `SUEnableAutomaticChecks` into
    /// the shared `.standard` domain during the test host's `Speech2TextApp.init`. Reading the
    /// stored property keeps SwiftUI observation tracking; writes forward to Sparkle, which
    /// persists.
    private var autoChecksStorage: Bool
    var automaticallyChecksForUpdates: Bool {
        get { autoChecksStorage }
        set {
            autoChecksStorage = newValue
            // A gated model has no updater, so the write stays in memory — see `updater`.
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    /// The production front door, and the ONLY initializer that CONSTRUCTS a Sparkle object. The
    /// designated init below names `SPUStandardUpdaterController` in its signature but merely
    /// stores it; the test door names no Sparkle type at all, so it cannot construct one even by
    /// accident. That guarantee is the compiler's rather than a branch ordering's, which is why
    /// this is three initializers and not one.
    /// - Parameter isBusy: whether the app is mid-transcription or mid-removal. Consulted by
    ///   `UpdaterDelegate` to postpone an update's install-and-RELAUNCH — never to skip the check
    ///   itself, which would defer updates by a further ~24h each time (see that type).
    convenience init(
        startingUpdater: Bool = SparkleUpdaterModel.shouldStartUpdater(),
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) {
        guard startingUpdater else {
            // Gated: construct NO Sparkle objects (see `controller` — even an unstarted
            // `SPUUpdater` binds an `SUHost` to the shared defaults domain).
            self.init(controller: nil, updater: nil, delegate: nil)
            return
        }

        let delegate = UpdaterDelegate(isBusy: isBusy)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.init(controller: controller, updater: controller.updater, delegate: delegate)
    }

    /// Whether an update may install and relaunch the app right now — false while a transcription
    /// or a data removal is in flight, because relaunching would destroy an in-memory transcript
    /// or leave a half-deleted cache. See `UpdaterDelegate` for why this guards the relaunch
    /// rather than the check.
    ///
    /// A pure function of its input, deliberately: the delegate method that consults it takes an
    /// `SPUUpdater` and an `SUAppcastItem`, neither of which a test may construct.
    nonisolated static func mayRelaunchForUpdate(isBusy: Bool) -> Bool { !isBusy }

    /// Test-only front door: runs the model's LIVE wiring against an injected driver. It names no
    /// Sparkle type at all, so it CANNOT bring an `SPUUpdater`/`SUHost` over the shared defaults
    /// domain into existence — the same hermetic-DI convention as `ManagerFixture`'s injectable
    /// `UserDefaults` and `shouldStartUpdater(arguments:environment:)`.
    convenience init(updater: any SparkleUpdating) {
        self.init(controller: nil, updater: updater, delegate: nil)
    }

    /// The one designated initializer: everything downstream of "which driver do I have", so the
    /// injected path and the shipping path execute the SAME lines and a test of the former is a
    /// test of the latter rather than of a parallel copy.
    private init(
        controller: SPUStandardUpdaterController?,
        updater: (any SparkleUpdating)?,
        delegate: UpdaterDelegate?
    ) {
        self.controller = controller
        self.updater = updater
        self.delegate = delegate

        guard let updater else {
            // Seed the toggle from the shipped Info.plist default rather than Sparkle's SUHost
            // resolution (defaults first, Info.plist as fallback), so the initial value can't
            // depend on the developer's real app settings — deterministic on any machine.
            autoChecksStorage =
                Bundle.main.object(forInfoDictionaryKey: Self.autoChecksDefaultsKey) as? Bool
                ?? true
            return
        }

        // Live models seed from Sparkle (the persisted preference / current state). Both mirrors
        // below seed by direct read and then re-read on change, so the value always comes from
        // the same source and no captured payload can be applied out of order.
        autoChecksStorage = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        // Deliberately NOT `MainActor.assumeIsolated`: of the SPUUpdater properties this model
        // touches, `canCheckForUpdates` is the ONE that Sparkle's header does *not* document as
        // main-thread-only (`automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates` and
        // `updateCheckInterval` all say "must be called on the main thread"; it doesn't — it is a
        // readonly property driven by internal session state). An off-main delivery would make
        // `assumeIsolated` trap and kill the shipped app, and no test could catch it because a
        // fake only ever mutates on the main actor. So hop like the auto-checks mirror below and
        // re-read the live value there.
        observation = updater.observeCanCheckForUpdates { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let updater = self.updater else { return }
                self.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        // Mirror Sparkle-side writes to the auto-check preference back into the stored property so
        // the Settings toggle can't go stale when something other than our setter changes it —
        // Sparkle's own update-permission UI, for instance.
        //
        // SCOPE, precisely: this is KVO on `SPUUpdater.automaticallyChecksForUpdates`, so it fires
        // for writes THROUGH that property, not for arbitrary changes to the underlying
        // `SUEnableAutomaticChecks` defaults key. An external `defaults write` while the app is
        // running does change Sparkle's behaviour (its getter reads live through `SUHost`) but
        // emits no KVO notification, so the toggle would still read stale until the next launch.
        // That edge case is knowingly unhandled — closing it would mean observing the defaults
        // domain directly.
        //
        // Same main-actor hop and live re-read as the mirror above, for the same two reasons: KVO
        // is delivered on the mutating thread and nothing here guarantees that is the main one,
        // and an unstructured hop carries no ordering guarantee — so applying a captured value
        // could overwrite a newer write, while re-reading always converges on Sparkle's current
        // truth. (The echo of our own setter's write-through re-applies an identical value —
        // harmless.) Re-deriving `updater` through self on the main actor keeps the non-Sendable
        // Sparkle object from crossing the isolation boundary and adds no lifetime extension.
        // (A gated model never reaches this code — it returned above with no observations, so it
        // stays hermetic by construction.)
        autoChecksObservation = updater.observeAutomaticallyChecksForUpdates { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let updater = self.updater else { return }
                self.autoChecksStorage = updater.automaticallyChecksForUpdates
            }
        }
    }

    func checkForUpdates() {
        // nil only in gated processes, where the menu command is disabled anyway
        // (`canCheckForUpdates` never leaves false without a live updater).
        updater?.checkForUpdates()
    }

    /// The Sparkle defaults/Info.plist key behind `automaticallyChecksForUpdates`. Named (like
    /// `testEnvironmentMarkers` below) so the gated seed above and the gate suite's
    /// snapshot/restore share one spelling and can't drift — a fork would leave the tests
    /// snapshotting a key the model no longer touches, passing vacuously.
    nonisolated static let autoChecksDefaultsKey = "SUEnableAutomaticChecks"

    /// XCTest environment markers that identify a test-hosted process. Named so the gate below and
    /// the gating test's parameterized cases share one list and can't drift.
    nonisolated static let testEnvironmentMarkers = [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
    ]

    /// Whether the running build is a Debug build. A stored flag rather than a `#if` inside
    /// `shouldStartUpdater` so the policy below is a plain function of its inputs and can be
    /// tested for BOTH answers from a test run that is itself always Debug.
    nonisolated static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Whether this launch should start a live updater.
    ///
    /// **Debug builds never do.** A developer's `⌘R` run is not a shipped app: starting Sparkle
    /// there binds an `SUHost` to the real `com.speech2text.app` defaults domain and writes
    /// `SULastCheckTime` and friends into the preferences of whatever copy the developer has
    /// installed — the same cross-talk the three initializers and the fakes exist to prevent.
    /// Worse, `CURRENT_PROJECT_VERSION` in a working tree is routinely *older* than the published
    /// feed head, so Sparkle would eventually offer to replace the DerivedData build with a
    /// download. Release is the only configuration that ships, and the only one that updates.
    ///
    /// The `-uiTesting` and XCTest checks are then belt-and-braces for the same reason they were
    /// written — unit tests run IN the app (test host = the app, so `Speech2TextApp.init`
    /// executes on every unit-test run) and XCUITest launches the real app with `-uiTesting`.
    /// They are unreachable while tests only ever run in Debug, and are kept so that running a
    /// suite against a Release build doesn't silently start an updater.
    ///
    /// All three inputs are injectable so the gating tests can exercise every branch.
    static func shouldStartUpdater(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = SparkleUpdaterModel.isDebugBuild
    ) -> Bool {
        if isDebugBuild { return false }
        // Same literal as `TranscriptionManager.applyUITestSeamIfPresent`; there is no shared
        // constant for it in this target yet.
        if arguments.contains("-uiTesting") { return false }
        if Self.testEnvironmentMarkers.contains(where: { environment[$0] != nil }) { return false }
        return true
    }
}

/// The app-menu item that triggers a manual update check — a dedicated command `View` like
/// `AboutMenuCommand`/`HelpMenuCommand` (its siblings in the app menu). Internal (not private,
/// unlike those two) so the render tests can drive it against a `FakeUpdater`. The dedicated view
/// is Sparkle's documented menu-item pattern: SwiftUI Observation re-evaluates this body when the
/// observable `canCheckForUpdates` changes, which is what keeps the disabled state fresh —
/// Commands have no AppKit-style re-validation on menu open to fall back on.
struct CheckForUpdatesCommand: View {
    let updater: any UpdaterModel

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        .accessibilityIdentifier("checkForUpdatesButton")
    }
}
