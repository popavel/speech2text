import Foundation
import Testing
import ViewInspector
import WhisperKit

@testable import Speech2Text

// View-render tests for the in-app help book (HelpView / HelpDetailView). Like the ContentView
// suite, all inspection is static: each assertion builds a fresh view and reads its rendered body,
// so no ViewHosting / XCTest machinery is needed and the suite stays pure Swift Testing.
//
// The point of these tests is wiring protection: the help copy DERIVES its factual claims from
// TranscriptionManager's canonical `static` declarations (supported formats, model display names +
// default, task labels, the storage/uninstall paths, the batch-run header, the language count), and
// each assertion recomputes the expected string from that same source. Because both sides derive
// from one source, a content change (a new format, a re-worded size) propagates to the copy AND the
// expectation together, so these can't catch a wording change — nor do they need to. What they
// pin is that the help copy stays *wired to* the canonical source: if a topic were changed to
// hard-code a literal instead of interpolating the derived value, the rendered text would stop
// matching the recomputed expectation and the test would fail. (Keyboard shortcuts and the exact
// Settings button labels are deliberately illustrative prose, not derived — see HelpView's doc
// comment; their drift is guarded separately by `labelsAppearInBothUIAndHelp` below.)
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
        // Exact-match the full rendered line to pin that the copy stays wired to the canonical sets:
        // the help interpolates the same `sorted().joined(", ")` we recompute here, so a change to a
        // supported set propagates to both sides at once (this can't catch a wording change) — but if
        // the topic were switched to a hard-coded format list, the rendered line would stop matching.
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

    // MARK: - Detail pane identity (HelpDetailView)

    // The tests above assert `HelpDetailView(topic:)` content; this pins its per-topic scroll
    // identity. The `HelpView` *container* rendering (sidebar rows and which detail pane is shown,
    // plus the nil-selection → Overview `?? .overview` fallback in the detail slot) is NOT
    // inspectable here: ViewInspector 0.10.3 can't unwrap a custom view whose body is a 2-column
    // `NavigationSplitView(sidebar:detail:)` — every traversal (generic `find`, `navigationSplitView()`,
    // `find(NavigationSplitView.self)`) throws "does not have 'content' attribute" because its child
    // extraction expects the 3-column `content` column. Reshaping production purely to satisfy the
    // test isn't worth it, so the sidebar `helpTopic-*` rows and the default `helpDetail-overview`
    // pane stay covered by the XCUITest (`testHelpBookOpensFromMenuAndNavigatesTopics`), which drives
    // the real container.

    @Test("Detail ScrollView is identified per topic so scroll offset resets on switch")
    func detailScrollViewIsIdentifiedPerTopic() throws {
        // `.id(topic)` gives the ScrollView a fresh identity per topic so the reused detail slot
        // resets its scroll offset on a topic switch. Assert the id is wired to the topic so the
        // scroll-reset can't be silently dropped.
        for topic in [HelpTopic.models, .results, .uninstalling] {
            let scroll = try HelpDetailView(topic: topic).inspect().find(ViewType.ScrollView.self)
            #expect(try scroll.id() == AnyHashable(topic))
        }
    }

    // MARK: - Label drift guard (non-derived prose ↔ real controls)

    @Test("Every control label named in the help prose still renders in the real UI")
    func labelsAppearInBothUIAndHelp() throws {
        let fixture = ManagerFixture()
        // Seed so the conditionally-shown controls render: a queued file exposes "Clear All", and a
        // non-empty result exposes the "Copy"/"Export .txt" result section.
        let manager = fixture.makeManager()
        manager.addFiles([URL(fileURLWithPath: "/tmp/sample.mp3")])
        manager.transcriptionResult = "sample transcript"
        let content = try ContentView(manager: manager).inspect()
        let settings = try SettingsView(manager: fixture.makeManager()).inspect()

        // Canonical list of the control labels the help book names in prose (the shortcut glyphs
        // ⌘O/⌘⏎/⌘, aren't derivable from a KeyEquivalent, so they stay best-effort and are out of
        // scope). This table is the guard's single source: each label must render BOTH as a real
        // control (ContentView, or SettingsView when `inSettings`) AND somewhere in the help copy —
        // any 2-of-3 divergence (control renamed, prose renamed, or this table left stale) trips it.
        // ("Storage" is named in prose too, but its control is a `Section` header, which doesn't
        // inspect as a plain Text — so it's covered by the derived Storage-path tests instead.)
        //
        // Caveat: the control-side check is a plain text match, so a label that renders more than
        // once is only partially guarded. "Transcribe" is the one such case — it's both the run
        // button and `DecodingTask.transcribe.displayName` (the Task picker's option) — so a rename
        // of the button alone (leaving the picker option) would still find the text and pass. It's
        // kept in the table for the prose-side and simultaneous-rename coverage it does provide.
        let labels: [(text: String, inSettings: Bool)] = [
            ("Browse Files", false),
            ("Clear All", false),
            ("Task", false),
            ("Advanced", false),
            ("Temperature", false),
            ("Transcribe", false),
            ("Copy", false),
            ("Export .txt", false),
            ("Downloaded models", true),
            ("Delete Downloaded Models", true),
            ("Remove All App Data", true),
            ("Restore Default Settings", true),
        ]

        for (text, inSettings) in labels {
            // Control side: the exact label renders as a control title in the corresponding view.
            let host = inSettings ? settings : content
            let rendersAsControl = (try? host.find(text: text)) != nil
            #expect(
                rendersAsControl,
                "help names \"\(text)\" but it no longer renders in \(inSettings ? "SettingsView" : "ContentView")"
            )
            // Prose side: some help topic still mentions the label.
            let namedInHelp = HelpTopic.allCases.contains { topic in
                (try? HelpDetailView(topic: topic).inspect()
                    .find(textWhere: { prose, _ in prose.contains(text) })) != nil
            }
            #expect(namedInHelp, "control \"\(text)\" is no longer mentioned anywhere in the help book")
        }
    }
}
