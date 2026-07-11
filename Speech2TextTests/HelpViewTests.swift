import Foundation
import Testing
import ViewInspector
import WhisperKit

@testable import Speech2Text

// View-render tests for the in-app help book (HelpView / HelpDetailView). Like the ContentView
// suite, all inspection is static: each assertion builds a fresh view and reads its rendered body,
// so no ViewHosting / XCTest machinery is needed and the suite stays pure Swift Testing.
//
// The point of these tests is drift protection: the help copy derives its factual claims from
// TranscriptionManager's canonical `static` declarations (supported formats, model display names +
// default, task labels, the storage/uninstall paths, the batch-run header, the language count), so
// the assertions recompute the expected strings from those same sources. If any of those change,
// the docs must change with them or these fail. (Keyboard shortcuts and the exact Settings button
// labels are deliberately illustrative prose, not derived — see HelpView's doc comment — so they
// are not asserted here.)
@MainActor
@Suite("HelpView")
struct HelpViewTests {

    @Test("Every topic has a unique, non-empty title and symbol")
    func topicsWellFormed() {
        let topics = HelpTopic.allCases
        #expect(topics.allSatisfy { !$0.title.isEmpty })
        #expect(topics.allSatisfy { !$0.systemImage.isEmpty })
        // Titles are the sidebar labels and detail headings; symbols are the sidebar icons. A
        // copy-paste slip giving two topics the same title or SF Symbol wouldn't surface in the
        // XCUITest (which hooks rows by rawValue), so guard uniqueness here.
        #expect(Set(topics.map(\.title)).count == topics.count)
        #expect(Set(topics.map(\.systemImage)).count == topics.count)
    }

    @Test("Adding-files topic lists the canonical audio and video extensions")
    func addingFilesListsFormats() throws {
        let view = HelpDetailView(topic: .addingFiles)
        let audio = TranscriptionManager.supportedAudioExtensions.sorted().joined(separator: ", ")
        let video = TranscriptionManager.supportedVideoExtensions.sorted().joined(separator: ", ")
        // Exact-match the full rendered line so a format added to the manager but not documented
        // (or vice versa) trips this test rather than silently drifting.
        #expect(throws: Never.self) {
            try view.inspect().find(text: "Supported audio: \(audio)")
        }
        #expect(throws: Never.self) {
            try view.inspect().find(text: "Supported video: \(video)")
        }
    }

    @Test("Models topic renders every model's display name")
    func modelsListsDisplayNames() throws {
        let view = HelpDetailView(topic: .models)
        for model in WhisperModel.allCases {
            #expect(throws: Never.self) {
                try view.inspect().find(text: model.displayName)
            }
        }
    }

    @Test("Overview topic describes what the app does")
    func overviewDescribesApp() throws {
        let view = HelpDetailView(topic: .overview)
        // A distinctive phrase, not just the bare app name (which could match any stray mention).
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("transcribes audio and video to text entirely on your Mac")
            })
        }
    }

    @Test("Models topic recommends the canonical default model by name")
    func modelsNamesDefault() throws {
        let view = HelpDetailView(topic: .models)
        let shortName = TranscriptionManager.Defaults.model.shortName
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("\(shortName) is a good default")
            })
        }
    }

    @Test("Languages topic states the derived language count")
    func languagesStatesCount() throws {
        let view = HelpDetailView(topic: .languages)
        // Assert the view renders the type's canonical count; the exclude-Auto / dedupe-aliases
        // semantics of `spokenLanguageCount` are pinned separately in TranscriptionLanguageTests, so
        // this is real drift protection rather than re-deriving the same formula the view uses.
        let count = TranscriptionLanguage.spokenLanguageCount
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("around \(count) languages")
            })
        }
    }

    @Test("Languages topic names the default language derived from canonical source")
    func languagesNamesDerivedDefault() throws {
        let view = HelpDetailView(topic: .languages)
        // The prose must derive the default-language name from the canonical source (like the
        // Models topic derives `Defaults.model.shortName`), not restate a literal — so a rename of
        // `TranscriptionLanguage.auto`'s displayName updates the help copy instead of leaving it
        // stale. Recompute from the same source the view reads so this stays in lockstep.
        let name = TranscriptionManager.Defaults.language.displayName
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("defaults to \(name)")
            })
        }
    }

    @Test("Transcribing topic lists every task and documents the canonical batch header")
    func transcribingListsTasksAndHeader() throws {
        let view = HelpDetailView(topic: .transcribing)
        for task in DecodingTask.allCases {
            #expect(throws: Never.self) {
                try view.inspect().find(text: task.displayName)
            }
        }
        // The multi-file header is derived from the same helper the transcription loop emits.
        let header = TranscriptionManager.batchHeader(forFileNamed: "filename")
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in text.contains(header) })
        }
    }

    @Test("Results topic explains the editable box and export")
    func resultsDescribesOutput() throws {
        let view = HelpDetailView(topic: .results)
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("Copy places the full text on the clipboard")
            })
        }
    }

    @Test("Storage topic shows the derived model cache path in a copy-selectable row")
    func storageShowsModelPath() throws {
        let view = HelpDetailView(topic: .storage)
        // Recomputed from the same URL WhisperKit downloads into, so a cache-location change trips
        // this rather than silently leaving the help pointing at a stale folder.
        let modelsPath =
            (TranscriptionManager.modelCacheDirectory.path as NSString).abbreviatingWithTildeInPath
        // Assert the path renders as its own identified `pathRow` (the monospaced,
        // `.textSelection(.enabled)` helper), not as plain prose — so the models location is
        // copyable like every other path in the book. Matching the row's exact text (not a
        // `contains` over surrounding prose) also proves the path stands alone in that row.
        let row = try view.inspect().find(viewWithAccessibilityIdentifier: "modelsPathRow")
        #expect(try row.text().string() == modelsPath)
    }

    @Test("Uninstalling topic keeps the app-data path and the Open Settings link")
    func uninstallingRetainsPathAndSettingsLink() throws {
        let view = HelpDetailView(topic: .uninstalling)
        // Match the app-data path row specifically — the one fact tying the guide to what "Remove
        // All App Data" actually wipes — recomputed from the same appSupportDirectory HelpView
        // derives it from. Address it by its own `appDataPathRow` identifier (exact match, like
        // storageShowsModelPath) rather than a substring scan: the four systemPaths rows embed the
        // same bundle id, so a `contains` check couldn't prove THIS row survived. The abbreviated
        // path still ends in bundleIdentifier, so rename-protection is retained.
        let appDataPath =
            (TranscriptionManager.appSupportDirectory.path as NSString).abbreviatingWithTildeInPath
        let row = try view.inspect().find(viewWithAccessibilityIdentifier: "appDataPathRow")
        #expect(try row.text().string() == appDataPath)
        // The jump into Settings ▸ Storage (where the wipe lives) must survive the migration
        // out of the old standalone UninstallHelpView.
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "openSettingsLink")
        }
    }
}
