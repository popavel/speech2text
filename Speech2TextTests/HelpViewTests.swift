import Foundation
import Testing
import ViewInspector

@testable import Speech2Text

// View-render tests for the in-app help book (HelpView / HelpDetailView). Like the ContentView
// suite, all inspection is static: each assertion builds a fresh view and reads its rendered body,
// so no ViewHosting / XCTest machinery is needed and the suite stays pure Swift Testing.
//
// The point of these tests is drift protection: the help copy is derived from
// TranscriptionManager's canonical `static` declarations (supported formats, model names), so the
// assertions recompute the expected strings from those same sources. If the app's supported
// formats or model list change, the docs must change with them or these fail.
@MainActor
@Suite("HelpView")
struct HelpViewTests {

    @Test("Every topic is well-formed (Overview + Uninstalling present, titles and symbols set)")
    func topicsWellFormed() {
        #expect(HelpTopic.allCases.contains(.overview))
        #expect(HelpTopic.allCases.contains(.uninstalling))
        #expect(HelpTopic.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(HelpTopic.allCases.allSatisfy { !$0.systemImage.isEmpty })
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

    @Test("Overview topic names the app")
    func overviewNamesApp() throws {
        let view = HelpDetailView(topic: .overview)
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in text.contains("Speech2Text") })
        }
    }

    @Test("Uninstalling topic keeps the app-data path and the Open Settings link")
    func uninstallingRetainsPathAndSettingsLink() throws {
        let view = HelpDetailView(topic: .uninstalling)
        // The leftover path is derived from the shared bundle identifier — the same source the
        // manager uses — so a rename can't leave the guide pointing at a stale folder.
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains(TranscriptionManager.bundleIdentifier)
            })
        }
        // The jump into Settings ▸ Storage (where the wipe lives) must survive the migration
        // out of the old standalone UninstallHelpView.
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "openSettingsLink")
        }
    }
}
