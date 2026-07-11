import Foundation
import Testing
import ViewInspector

@testable import Speech2Text

// View-render tests for the in-app About panel (AboutView). Like the ContentView and HelpView
// suites, all inspection is static: each assertion builds a fresh view and reads its rendered
// body, so no ViewHosting / XCTest machinery is needed and the suite stays pure Swift Testing.
// AboutView is a plain VStack (not a NavigationSplitView), so ViewInspector can traverse it
// directly.
//
// These tests pin the About panel's *content* — the fixed copy the panel presents (app name,
// privacy description, copyright, license, open-source acknowledgements, and the repository
// link). They intentionally do NOT assert the app version string: AboutView reads it from
// `Bundle.main` at runtime, which resolves to the test host's bundle rather than the app's, so
// any version assertion would be environment-dependent and flaky. The version is left to
// manual/visual verification of the real app instead — this is the one deliberate gap.
@MainActor
@Suite("AboutView")
struct AboutViewTests {

    @Test("Renders the app name and the privacy-focused description")
    func rendersIdentityAndDescription() throws {
        let view = AboutView()
        // The app name stands on its own as the panel's identity.
        #expect(throws: Never.self) {
            try view.inspect().find(text: "Speech2Text")
        }
        // A distinctive phrase from the description, matched as a substring so surrounding prose
        // (which may be reworded) doesn't have to match exactly.
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("entirely on your Mac")
            })
        }
    }

    @Test("Renders the copyright line and the license")
    func rendersCopyrightAndLicense() throws {
        let view = AboutView()
        // The copyright is an exact standalone string.
        #expect(throws: Never.self) {
            try view.inspect().find(text: "© 2026 Pavel Pozdnyakov")
        }
        // The license is matched as a substring (it may sit inside a longer sentence).
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("MIT License")
            })
        }
    }

    @Test("Renders the open-source acknowledgements")
    func rendersAcknowledgements() throws {
        let view = AboutView()
        // Distinctive substrings of the credited open-source projects.
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("swift-transformers")
            })
        }
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("argmax")
            })
        }
        #expect(throws: Never.self) {
            try view.inspect().find(text: "OpenAI Whisper")
        }
    }

    @Test("Renders the GitHub repository link with its identifier and visible label")
    func rendersRepoLink() throws {
        let view = AboutView()
        // The link is addressable by its accessibility identifier so it can be driven/queried.
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "aboutRepoLink")
        }
        // …and its visible label renders the repository URL.
        #expect(throws: Never.self) {
            try view.inspect().find(text: "github.com/popavel/speech2text")
        }
    }
}
