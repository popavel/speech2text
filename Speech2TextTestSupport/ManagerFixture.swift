import Foundation

@testable import Speech2Text

// Test-only helper shared across the unit-test targets. This file is compiled into both
// `Speech2TextTests` and `Speech2TextIntegrationTests` (see project.yml), so both targets
// build their managers the same hermetic way.

/// Vends a `TranscriptionManager` backed by a throwaway `UserDefaults` domain and removes that
/// domain when the fixture is released (in `deinit`). Keeps settings-persistence tests hermetic —
/// the app-hosted test process resolves `.standard` to the app's real `com.speech2text.app` domain,
/// so persisting there would read/clobber the developer's actual settings. Hold the fixture for as
/// long as any manager built from it is in use: a per-test fixture is released after its test and
/// leaves no orphan `s2t.test.*` plist, whereas one kept for the whole process (a `static let`) is
/// released only at exit and so may leave a single ephemeral domain — still never `.standard`.
///
/// `@unchecked Sendable`: storage is immutable (`let`) and `UserDefaults` is thread-safe, so a
/// single fixture can be shared safely (e.g. a `static let` across a serialized suite). It stays
/// nonisolated — not `@MainActor` — so `deinit` may touch the non-`Sendable` store; only
/// `makeManager()` needs the main actor, to satisfy `TranscriptionManager`'s `@MainActor` init.
final class ManagerFixture: @unchecked Sendable {
    /// The isolated store. Exposed so a test can seed a raw/invalid value before building a manager.
    let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "s2t.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A manager persisting into this fixture's store. Managers from the same fixture share the
    /// store — which is how the round-trip-across-instances tests exercise persistence.
    @MainActor func makeManager() -> TranscriptionManager {
        TranscriptionManager(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
