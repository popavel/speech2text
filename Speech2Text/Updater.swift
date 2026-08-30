import Foundation
import SwiftUI

// Binary ObjC framework without full Sendable annotations — same treatment as WhisperKit.
@preconcurrency import Sparkle

// The in-app update mechanism: direct distribution, self-updating via Sparkle against the appcast
// at `SUFeedURL` in Info.plist.
// Why: docs/distribution.md#the-seam

/// What the views need from an updater. Views depend on this protocol, never on Sparkle, so unit
/// tests can inject a `FakeUpdater`.
/// Why: docs/distribution.md#the-seam
@MainActor
protocol UpdaterModel: AnyObject, Observable {
    /// Whether this model drives a real updater at all — false in gated processes (any Debug
    /// build, a test host, `-uiTesting`). Constant for the model's lifetime, unlike
    /// `canCheckForUpdates`, which also goes false mid-check.
    /// Why: docs/distribution.md#the-launch-gate
    var isActive: Bool { get }

    /// Whether a manual check can start now (false while the updater is off or mid-session).
    var canCheckForUpdates: Bool { get }
    /// The user's "check automatically" preference (Settings toggle). The Sparkle-backed model
    /// persists this via Sparkle itself (`SUEnableAutomaticChecks` in the app's defaults domain).
    var automaticallyChecksForUpdates: Bool { get set }
    /// Kick off a user-initiated update check (shows Sparkle's UI, including errors).
    func checkForUpdates()
}

/// The slice of `SPUUpdater` that `SparkleUpdaterModel` actually drives, so the model's LIVE branch
/// can run under test with no Sparkle object in the process at all.
/// Why: docs/distribution.md#the-seam
@MainActor
protocol SparkleUpdating: AnyObject {
    /// Whether Sparkle can start a check right now. Readable, not just observable, so the model can
    /// seed from it and re-read the live value after hopping to the main actor.
    var canCheckForUpdates: Bool { get }

    /// Sparkle's persisted "check automatically" preference (`SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool { get set }

    /// Start a user-initiated check (Sparkle shows its own UI, including errors).
    func checkForUpdates()

    /// KVO over `canCheckForUpdates`. Neither `options` nor the change struct is load-bearing —
    /// the model seeds by direct read and re-reads on arrival. Symmetric with the vendor below.
    /// Why: docs/distribution.md#kvo-mirrors
    func observeCanCheckForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation

    /// KVO over `automaticallyChecksForUpdates`. Same shape as the vendor above, for the same
    /// reason.
    func observeAutomaticallyChecksForUpdates(
        changeHandler: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation
}

/// `SPUUpdater` already satisfies the value half of `SparkleUpdating`, so only the two observation
/// vendors are added here. Kept irreducibly thin on purpose — this is the one piece of the live
/// path a test cannot execute.
/// Why: docs/distribution.md#the-seam
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

/// Sparkle's delegate. One job: never relaunch over work in progress. Retained by
/// `SparkleUpdaterModel`, since `SPUStandardUpdaterController` holds its delegate weakly. Internal
/// rather than private so the selector test can construct one — safe, since `init(isBusy:)` names
/// no Sparkle type.
// DO NOT guard the check (`updater(_:mayPerform:)`) instead — Sparkle counts a refused check as a
// completed one and pushes updates a further ~24h out, without covering the real hazard.
// Why: docs/distribution.md#relaunch-not-check
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let isBusy: @MainActor () -> Bool

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
        super.init()
    }

    /// Returning `true` defers the install and relaunch until `installHandler` is invoked, which
    /// happens as soon as the app goes idle. A mitigation, not a guarantee — and if the app never
    /// goes idle, nothing installs.
    /// Why: docs/distribution.md#relaunch-not-check
    // DO NOT rename the Swift label or drop this pin — the ObjC runtime dispatches on the selector,
    // and a mismatched label is a warning only, leaving the hook silently dead.
    // Why: docs/distribution.md#the-objc-selector-pin
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !SparkleUpdaterModel.mayRelaunchForUpdate(isBusy: isBusy()) else { return false }

        Task { @MainActor [isBusy] in
            while isBusy() {
                // NEVER `try?` here — it swallows cancellation, and a cancelled task would spin
                // this loop on the main actor and freeze the UI.
                // Why: docs/distribution.md#relaunch-not-check
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            installHandler()
        }
        return true
    }
}

/// The Sparkle-backed `UpdaterModel`, owning the app's one `SPUStandardUpdaterController` and the
/// `UpdaterDelegate` that postpones an install over work in progress.
/// Why: docs/distribution.md#the-seam
@MainActor
@Observable
final class SparkleUpdaterModel: UpdaterModel {
    // DO NOT delete this "unused" property — it is the sole strong reference keeping the
    // controller, and the Sparkle UI it owns, alive past `init(startingUpdater:)`.
    // Why: docs/distribution.md#controller-is-ownership-only
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// What this model actually drives: `controller?.updater` on a live model, an injected fake on
    /// a test model, nil on a gated one. Nil-ness (not `controller`'s) is what the write paths and
    /// the init branch key off, so the gated and injected shapes share one code path — and so the
    /// branch a test exercises is the branch that ships, not a copy of it.
    @ObservationIgnored private let updater: (any SparkleUpdating)?
    // DO NOT delete this either — the controller holds its delegate weakly, so without it the
    // postpone guard deallocates and an update can relaunch mid-transcription.
    // Why: docs/distribution.md#controller-is-ownership-only
    @ObservationIgnored private let delegate: UpdaterDelegate?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var autoChecksObservation: NSKeyValueObservation?

    /// Mirror of `SPUUpdater.canCheckForUpdates`, so the menu item's disabled state tracks it.
    /// Stays false when there is no live updater.
    private(set) var canCheckForUpdates = false

    /// See `UpdaterModel.isActive`. Keyed off `updater`, like every other branch in this type.
    var isActive: Bool { updater != nil }

    // DO NOT collapse this into a `didSet` mirror — under `@Observable` the init-time assignment
    // runs the setter, writing `SUEnableAutomaticChecks` into the developer's real defaults domain.
    // Why: docs/distribution.md#kvo-mirrors
    private var autoChecksStorage: Bool
    var automaticallyChecksForUpdates: Bool {
        get { autoChecksStorage }
        set {
            autoChecksStorage = newValue
            // A gated model has no updater, so the write stays in memory — see `updater`.
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    /// The production front door, and the ONLY initializer that constructs a Sparkle object.
    // DO NOT collapse the three initializers into one — the test door names no Sparkle type, which
    // is a compiler guarantee that a branch ordering cannot replace.
    // Why: docs/distribution.md#three-initializers
    /// - Parameter isBusy: whether the app is mid-transcription or mid-removal, consulted by
    ///   `UpdaterDelegate` to postpone an update's install-and-relaunch.
    convenience init(
        startingUpdater: Bool = SparkleUpdaterModel.shouldStartUpdater(),
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) {
        guard startingUpdater else {
            // Gated: construct NO Sparkle objects — even an unstarted `SPUUpdater` binds an
            // `SUHost` to the shared defaults domain.
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

    /// Whether an update may install and relaunch right now — false while a transcription or a
    /// removal is in flight. A pure function of its input, deliberately, since the delegate method
    /// that consults it takes types no test may construct.
    /// Why: docs/distribution.md#relaunch-not-check
    nonisolated static func mayRelaunchForUpdate(isBusy: Bool) -> Bool { !isBusy }

    /// Test-only front door: runs the model's LIVE wiring against an injected driver. Names no
    /// Sparkle type at all, so it structurally cannot construct one.
    /// Why: docs/distribution.md#three-initializers
    convenience init(updater: any SparkleUpdating) {
        self.init(controller: nil, updater: updater, delegate: nil)
    }

    /// The one designated initializer: everything downstream of "which driver do I have", so the
    /// injected path and the shipping path execute the SAME lines.
    /// Why: docs/distribution.md#three-initializers
    private init(
        controller: SPUStandardUpdaterController?,
        updater: (any SparkleUpdating)?,
        delegate: UpdaterDelegate?
    ) {
        self.controller = controller
        self.updater = updater
        self.delegate = delegate

        guard let updater else {
            // Seed from the shipped Info.plist default, not Sparkle's SUHost resolution, so the
            // initial value can't depend on the developer's real app settings.
            autoChecksStorage =
                Bundle.main.object(forInfoDictionaryKey: Self.autoChecksDefaultsKey) as? Bool
                ?? true
            return
        }

        // Live models seed by direct read; both mirrors below re-read on change, so no captured
        // payload can be applied out of order.
        autoChecksStorage = updater.automaticallyChecksForUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        // NEVER `MainActor.assumeIsolated` here — `canCheckForUpdates` is the one property Sparkle
        // does not document as main-thread-only, and an off-main delivery would trap and kill the
        // shipped app where no test could catch it.
        // Why: docs/distribution.md#never-mainactorassumeisolated
        observation = updater.observeCanCheckForUpdates { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let updater = self.updater else { return }
                self.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        // Mirror Sparkle-side writes back into the stored property so the Settings toggle can't go
        // stale when something other than our setter changes it.
        // DO NOT add a second observation on `UserDefaults.standard` to "close the gap" — since
        // 2.8.0 Sparkle already propagates external writes through this same property.
        // Why: docs/distribution.md#scope-of-the-auto-checks-mirror
        // NEVER `MainActor.assumeIsolated` in this handler either — KVO is delivered on the
        // mutating thread, so a trap here would kill the shipped app and no fake could catch it.
        // Why: docs/distribution.md#never-mainactorassumeisolated
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

    /// The Sparkle defaults/Info.plist key behind `automaticallyChecksForUpdates`. Named so the
    /// gated seed and the gate suite share one spelling and can't drift.
    nonisolated static let autoChecksDefaultsKey = "SUEnableAutomaticChecks"

    /// XCTest environment markers that identify a test-hosted process. Named so the gate below and
    /// the gating test's parameterized cases share one list and can't drift.
    nonisolated static let testEnvironmentMarkers = [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
    ]

    /// Whether the running build is a Debug build. A stored flag rather than a `#if` inside
    /// `shouldStartUpdater`, so both answers are testable from a run that is always Debug.
    nonisolated static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Whether this launch should start a live updater. Debug builds never do; the `-uiTesting`
    /// and XCTest checks sit behind that as belt-and-braces for a suite run against Release. All
    /// three inputs are injectable so the gating tests can exercise every branch.
    /// Why: docs/distribution.md#the-launch-gate
    static func shouldStartUpdater(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = SparkleUpdaterModel.isDebugBuild
    ) -> Bool {
        if isDebugBuild { return false }
        if arguments.contains(TranscriptionManager.uiTestingLaunchArgument) { return false }
        if Self.testEnvironmentMarkers.contains(where: { environment[$0] != nil }) { return false }
        return true
    }
}

/// The app-menu item that triggers a manual update check. A dedicated command `View` — Sparkle's
/// documented pattern — so SwiftUI Observation keeps its disabled state fresh. Internal, unlike its
/// About/Help siblings, so render tests can drive it against a `FakeUpdater`.
/// Why: docs/distribution.md#the-launch-gate
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
