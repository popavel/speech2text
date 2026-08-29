import Foundation
import Testing
import ViewInspector

@testable import Speech2Text

// Tests for the Sparkle auto-update seam (Speech2Text/Updater.swift).
//
// THE RULE THESE TESTS EXIST TO ENFORCE: never construct a real `SPUUpdater`, started or not.
// It builds an `SUHost` over the app's `.standard` UserDefaults domain, and unit tests run
// *inside* the app here (test host = the app, so `Speech2TextApp.init` executes on every test
// run) — so a real updater would read and write the developer's own installed-app preferences.
// Two seams keep the model testable without one:
//
//   * `FakeUpdater` fakes the view-facing `UpdaterModel`, and is what render tests inject.
//   * `FakeSparkleUpdater` fakes the Sparkle-facing `SparkleUpdating` protocol — the slice of
//     `SPUUpdater` the model actually drives — and is injected through
//     `SparkleUpdaterModel.init(updater:)`. That initializer names no Sparkle type at all, so it
//     structurally cannot bring an `SPUUpdater`/`SUHost` into existence. This is what gives the
//     model's LIVE branch (seeding, both KVO mirrors, both write paths) real coverage.

/// Fakes the view-facing protocol. Views depend on `UpdaterModel`, never on Sparkle, so this is
/// all a render test needs.
@MainActor
@Observable
final class FakeUpdater: UpdaterModel {
    var isActive: Bool
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    private(set) var checkForUpdatesCallCount = 0

    init(
        isActive: Bool = true,
        canCheckForUpdates: Bool = true,
        automaticallyChecksForUpdates: Bool = true
    ) {
        self.isActive = isActive
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}

/// Fakes the Sparkle-facing protocol. An `NSObject` with `@objc dynamic` storage because the
/// protocol vends real `NSKeyValueObservation`s — which is the whole reason the observations are
/// vended by the conformer rather than registered by the model (KVO needs a concrete `Self` and a
/// key path over an `@objc dynamic` property; an existential can express neither).
@MainActor
final class FakeSparkleUpdater: NSObject, SparkleUpdating {
    @objc dynamic var canCheckForUpdates: Bool
    @objc dynamic var automaticallyChecksForUpdates: Bool
    private(set) var checkForUpdatesCallCount = 0

    init(canCheckForUpdates: Bool = false, automaticallyChecksForUpdates: Bool = false) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

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

/// Yield until `condition` holds or the budget runs out. Both of the model's KVO mirrors apply
/// their update through an unstructured `Task { @MainActor }` hop (KVO is delivered on the
/// mutating thread, which Sparkle does not guarantee is the main one), so these assertions have
/// to wait for a turn of the main actor rather than read straight through.
@MainActor
private func waitUntil(_ condition: () -> Bool, iterations: Int = 100) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
@Suite("SparkleUpdaterModel live wiring")
struct SparkleUpdaterLiveWiringTests {

    @Test("Seeds the auto-check toggle from the injected updater")
    func seedsAutoChecksFromUpdater() {
        let fake = FakeSparkleUpdater(automaticallyChecksForUpdates: true)
        let model = SparkleUpdaterModel(updater: fake)

        #expect(model.automaticallyChecksForUpdates)
    }

    @Test("Seeds canCheckForUpdates from the updater")
    func seedsCanCheckForUpdates() {
        let fake = FakeSparkleUpdater(canCheckForUpdates: true)
        let model = SparkleUpdaterModel(updater: fake)

        #expect(model.canCheckForUpdates)
    }

    @Test("Mirrors later canCheckForUpdates changes")
    func mirrorsCanCheckForUpdatesChanges() async {
        let fake = FakeSparkleUpdater(canCheckForUpdates: false)
        let model = SparkleUpdaterModel(updater: fake)
        #expect(!model.canCheckForUpdates)

        fake.canCheckForUpdates = true

        // Mirrored through a main-actor hop, not `assumeIsolated`: `canCheckForUpdates` is the one
        // SPUUpdater property Sparkle does NOT document as main-thread-only, so the handler must
        // survive an off-main delivery instead of trapping.
        #expect(await waitUntil { model.canCheckForUpdates })
    }

    @Test("Writing the toggle writes through to the updater")
    func toggleWritesThrough() {
        let fake = FakeSparkleUpdater(automaticallyChecksForUpdates: false)
        let model = SparkleUpdaterModel(updater: fake)

        model.automaticallyChecksForUpdates = true

        // Both halves matter: the stored property is what SwiftUI renders, and the write-through
        // is what actually persists. Deleting the write-through left the whole suite green once.
        #expect(model.automaticallyChecksForUpdates)
        #expect(fake.automaticallyChecksForUpdates)
    }

    @Test("Mirrors updater-side auto-check changes back into the model")
    func mirrorsAutoChecksChangesBack() async {
        let fake = FakeSparkleUpdater(automaticallyChecksForUpdates: false)
        let model = SparkleUpdaterModel(updater: fake)
        #expect(!model.automaticallyChecksForUpdates)

        // Simulates a Sparkle-side write through the property — e.g. its own update-permission
        // UI. (An external `defaults write` of `SUEnableAutomaticChecks` converges on this same
        // property KVO via Sparkle's own defaults observation; that leg is upstream's and can't be
        // exercised here without a real `SPUUpdater` — see the observation's comment in
        // Updater.swift.)
        fake.automaticallyChecksForUpdates = true

        #expect(await waitUntil { model.automaticallyChecksForUpdates })
    }

    @Test("An injected model reports itself active")
    func injectedModelIsActive() {
        // isActive keys off the driver, not the controller — so the injected shape reports the
        // same as the shipping one, which is what makes the render tests meaningful.
        #expect(SparkleUpdaterModel(updater: FakeSparkleUpdater()).isActive)
    }

    @Test("Relaunching for an update is postponed while the app is busy")
    func relaunchPostponedWhileBusy() {
        // The in-flight run and the unexported transcript live only in memory, and a data wipe
        // mid-removeItem would leave a half-deleted cache. Relaunching destroys either.
        #expect(!SparkleUpdaterModel.mayRelaunchForUpdate(isBusy: true))
    }

    @Test("Relaunching for an update proceeds when idle")
    func relaunchAllowedWhenIdle() {
        #expect(SparkleUpdaterModel.mayRelaunchForUpdate(isBusy: false))
    }

    @Test("Forwards a manual check to the updater")
    func forwardsManualCheck() {
        let fake = FakeSparkleUpdater()
        let model = SparkleUpdaterModel(updater: fake)

        model.checkForUpdates()

        #expect(fake.checkForUpdatesCallCount == 1)
    }
}

@MainActor
@Suite("SparkleUpdaterModel launch gate")
struct SparkleUpdaterGateTests {

    /// Snapshot/restore of the one defaults key the model can touch. This *changes nothing*
    /// unless the gate has already regressed — which is exactly the point.
    private func withSharedDomainSnapshot(_ body: () -> Void) {
        let key = SparkleUpdaterModel.autoChecksDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        body()
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("A gated model drives no updater and can never check")
    func gatedModelHasNoUpdater() {
        let model = SparkleUpdaterModel(startingUpdater: false)

        #expect(!model.isActive)
        #expect(!model.canCheckForUpdates)
        // No updater to forward to; must not trap.
        model.checkForUpdates()
        #expect(!model.canCheckForUpdates)
    }

    @Test("A gated model's toggle write stays off the shared defaults domain")
    func gatedWriteStaysOffTheSharedDomain() {
        withSharedDomainSnapshot {
            let key = SparkleUpdaterModel.autoChecksDefaultsKey
            let before = UserDefaults.standard.object(forKey: key) as? Bool
            let model = SparkleUpdaterModel(startingUpdater: false)

            model.automaticallyChecksForUpdates.toggle()

            // In-memory only — the developer's real app preferences are untouched.
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == before)
        }
    }

    @Test("An injected model's toggle write also stays off the shared domain")
    func injectedWriteStaysOffTheSharedDomain() {
        // The test door is not a way *around* the gate: it writes to the injected fake, not to
        // `.standard`.
        withSharedDomainSnapshot {
            let key = SparkleUpdaterModel.autoChecksDefaultsKey
            let before = UserDefaults.standard.object(forKey: key) as? Bool
            let model = SparkleUpdaterModel(updater: FakeSparkleUpdater())

            model.automaticallyChecksForUpdates.toggle()

            #expect(UserDefaults.standard.object(forKey: key) as? Bool == before)
        }
    }

    @Test("A Debug build never starts the updater, however it was launched")
    func refusesToStartInDebugBuilds() {
        // A developer's ⌘R run is not a shipped app: a live updater there writes Sparkle's
        // preferences into the real com.speech2text.app domain and, because a working tree's
        // CURRENT_PROJECT_VERSION trails the published feed, would eventually offer to replace
        // the DerivedData build with a download.
        #expect(
            !SparkleUpdaterModel.shouldStartUpdater(
                arguments: ["Speech2Text"],
                environment: [:],
                isDebugBuild: true
            )
        )
    }

    @Test("The updater never starts in a UI-test launch")
    func refusesToStartUnderUITesting() {
        #expect(
            !SparkleUpdaterModel.shouldStartUpdater(
                arguments: ["Speech2Text", "-uiTesting"],
                environment: [:],
                isDebugBuild: false
            )
        )
    }

    @Test("The updater never starts in an XCTest-hosted process", arguments: SparkleUpdaterModel.testEnvironmentMarkers)
    func refusesToStartUnderTestHost(marker: String) {
        #expect(
            !SparkleUpdaterModel.shouldStartUpdater(
                arguments: ["Speech2Text"],
                environment: [marker: "/some/path"],
                isDebugBuild: false
            )
        )
    }

    @Test("A plain Release launch starts the updater")
    func startsOnAPlainReleaseLaunch() {
        // The one combination that ships. Without this the gate could return false everywhere
        // and every other test here would still pass.
        #expect(
            SparkleUpdaterModel.shouldStartUpdater(
                arguments: ["Speech2Text"],
                environment: [:],
                isDebugBuild: false
            )
        )
    }

    @Test("This build is a Debug build")
    func currentBuildIsDebug() {
        // Pins the premise the suite relies on: tests only ever run in Debug here, which is what
        // makes `isDebugBuild` the effective gate for every test-hosted process.
        #expect(SparkleUpdaterModel.isDebugBuild)
    }

    @Test("Self-guarding: this very process does not start an updater")
    func currentProcessDoesNotStartAnUpdater() {
        // If this ever goes red, a real updater would start during `Speech2TextApp.init` on every
        // test run, binding an SUHost to the developer's real app preferences.
        #expect(!SparkleUpdaterModel.shouldStartUpdater())
    }
}

@MainActor
@Suite("CheckForUpdatesCommand")
struct CheckForUpdatesCommandTests {

    @Test("Is enabled when the updater can check")
    func enabledWhenUpdaterCanCheck() throws {
        let view = CheckForUpdatesCommand(updater: FakeUpdater(canCheckForUpdates: true))

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "checkForUpdatesButton")
        #expect(!button.isDisabled())
    }

    @Test("Is disabled while the updater cannot check")
    func disabledWhenUpdaterCannotCheck() throws {
        let view = CheckForUpdatesCommand(updater: FakeUpdater(canCheckForUpdates: false))

        let button = try view.inspect().find(viewWithAccessibilityIdentifier: "checkForUpdatesButton")
        #expect(button.isDisabled())
    }

    @Test("Tapping it asks the updater to check")
    func tapTriggersCheck() throws {
        let updater = FakeUpdater(canCheckForUpdates: true)
        let view = CheckForUpdatesCommand(updater: updater)

        try view.inspect().find(ViewType.Button.self).tap()

        #expect(updater.checkForUpdatesCallCount == 1)
    }
}
