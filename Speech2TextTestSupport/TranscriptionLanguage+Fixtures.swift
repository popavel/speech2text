import WhisperKit

@testable import Speech2Text

// Test-only fixtures shared across the unit-test targets. This file is compiled into
// both `Speech2TextTests` and `Speech2TextIntegrationTests` (see project.yml), so the
// fixture lives in one place rather than on the shipped `TranscriptionLanguage` surface.
extension TranscriptionLanguage {
    /// A known non-auto language for tests: WhisperKit's own default ("English"),
    /// derived the same way the picker derives its entries.
    static let english = allCases.first { $0.code == Constants.defaultLanguageCode } ?? .auto
}
