import Foundation
import Testing
import ViewInspector

@testable import Speech2Text

// View-render tests for the About panel, pinning its fixed copy. Statically inspected; `AboutView`
// is a plain VStack, so ViewInspector traverses it directly.
//
// They deliberately do NOT assert the version string — it resolves to the test host's bundle.
// Why: docs/testing.md#the-about-panel-version-gap
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
        // Sparkle ships inside the binary too, so its credit belongs here — see
        // THIRD-PARTY-LICENSES.md.
        #expect(throws: Never.self) {
            try view.inspect().find(textWhere: { text, _ in
                text.contains("Sparkle")
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
