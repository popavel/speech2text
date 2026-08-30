import Foundation

@testable import Speech2Text

// Test-only helper compiled into both unit-test targets (see project.yml), so both build their
// managers the same hermetic way.

/// Vends a `TranscriptionManager` backed by a throwaway `UserDefaults` domain, removed in `deinit`.
/// Hold the fixture for as long as any manager built from it is in use.
///
/// `@unchecked Sendable` because its storage is immutable and `UserDefaults` is thread-safe;
/// nonisolated so `deinit` may touch the non-`Sendable` store.
/// Why: docs/testing.md#hermetic-di
final class ManagerFixture: @unchecked Sendable {
    /// The isolated store. Exposed so a test can seed a raw/invalid value before building a manager.
    let defaults: UserDefaults
    private let suiteName: String

    /// The keys currently persisted in this fixture's domain — exactly what the manager's `didSet`
    /// writers produced, since the domain starts empty. Lets a test assert the persisted set equals
    /// `Keys.all` without a hand-maintained list.
    var persistedKeys: Set<String> {
        Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys)
    }

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
