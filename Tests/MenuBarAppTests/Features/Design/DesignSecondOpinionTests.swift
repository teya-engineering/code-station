import AppKit
import Foundation
import Testing
import WebKit
@testable import MenuBarApp
@testable import CodeStationCore

struct DesignSecondOpinionTests {
    private let codex = SecondOpinion.Reviewer(agent: .codex, model: "gpt-5.6-sol", effort: "high")
    private let copilot = SecondOpinion.Reviewer(agent: .copilot, model: "gpt-5.4")
    private let approved = DesignScreen(id: "approved", title: "Approved", path: "index.html", width: 390, height: 844)

    private func request(_ reading: DesignSecondOpinion.Reading = .init(), conversation: String = "") -> DesignSecondOpinion.Request {
        DesignSecondOpinion.Request(reading: reading, designDirectory: "/designs/1", shotsDirectory: "/tmp/shots",
                                    shots: [.init(screen: approved, light: "/tmp/shots/approved-light.png",
                                                  dark: "/tmp/shots/approved-dark.png")],
                                    asked: "Design the receipt screen.", conversation: conversation,
                                    executable: "/bin/codex")
    }

    @Test func notesAreReadOutOfAWrappedAnswer() throws {
        let answer = """
        Here are my notes.
        {"notes": [
          {"screen": "approved", "selector": "#amt", "box": null, "category": "Accessibility", "severity": "MUST", "text": "The amount is 2.9 to 1 {too low}."},
          {"screen": null, "selector": "", "box": {"x": 10, "y": 20, "width": 0, "height": 5}, "severity": "odd", "text": "No declined screen."},
          {"screen": "approved", "selector": null, "box": {"x": 10, "y": 20, "width": 30, "height": 5}, "category": "Copy", "severity": "look", "text": "Hide the id."},
          {"screen": "approved", "category": "Copy", "text": "  "}
        ]}
        """
        let notes = try #require(DesignSecondOpinion.notes(in: answer))
        #expect(notes.count == 3)
        #expect(notes[0] == .init(screen: "approved", selector: "#amt", box: nil, category: "Accessibility",
                                  severity: .must, text: "The amount is 2.9 to 1 {too low}."))
        // An empty selector or a box with no size points at nothing.
        #expect(notes[1].selector == nil && notes[1].box == nil && notes[1].screen == nil)
        #expect(notes[1].category == "Note" && notes[1].severity == .look)
        #expect(notes[2].box == .init(x: 10, y: 20, width: 30, height: 5))
        #expect(DesignSecondOpinion.notes(in: #"{"notes": []}"#) == [])
        #expect(DesignSecondOpinion.notes(in: "Looks great.") == nil)
    }

    @Test func thePromptShowsEveryPictureAndOnlyWhatThePersonShared() {
        let plain = DesignSecondOpinion.prompt(for: request(conversation: "User: an earlier idea"))
        #expect(plain.contains(#"Screen "approved" (Approved, index.html, 390x844): light /tmp/shots/approved-light.png, dark /tmp/shots/approved-dark.png"#))
        #expect(plain.contains("The HTML, any handoff.md and the theme are in /designs/1"))
        #expect(plain.contains("Design the receipt screen."))
        #expect(!plain.contains("an earlier idea"))

        let shared = DesignSecondOpinion.prompt(for: request(.init(source: false, conversation: true),
                                                             conversation: "User: an earlier idea"))
        #expect(shared.contains("Judge from the pictures alone"))
        #expect(shared.contains("an earlier idea"))
    }

    @Test func codexIsHandedThePicturesAndTheOthersTheirFolder() {
        let codexArguments = DesignSecondOpinion.arguments(for: codex, request: request(), prompt: "p")
        #expect(codexArguments.last == "p")
        #expect(codexArguments.contains(["--image", "/tmp/shots/approved-light.png", "--image", "/tmp/shots/approved-dark.png"]))
        // --image takes any number of files, so only "--" keeps the prompt from being one of them.
        #expect(Array(codexArguments.suffix(4)) == ["--image", "/tmp/shots/approved-dark.png", "--", "p"])
        #expect(codexArguments.contains("read-only"))

        let claude = DesignSecondOpinion.arguments(for: .init(agent: .claudeCode), request: request(), prompt: "p")
        #expect(claude.contains(["--add-dir", "/tmp/shots"]))
        // Without the files the reviewer runs among the pictures, so there is nothing to add.
        let picturesOnly = DesignSecondOpinion.arguments(for: .init(agent: .claudeCode),
                                                         request: request(.init(source: false)), prompt: "p")
        #expect(!picturesOnly.contains("--add-dir"))
    }

    @Test func twoSeatsOnTheSameElementAreOneNote() {
        var opinion = DesignOpinion(request: request(), lanes: [.init(reviewer: codex), .init(reviewer: copilot)])
        opinion.take([.init(screen: "approved", selector: "#newsale", category: "Hierarchy", severity: .should, text: "Make it a button."),
                      .init(screen: "approved", selector: "#amt", category: "Accessibility", severity: .should, text: "Low contrast.")],
                     from: codex)
        opinion.take([.init(screen: "approved", selector: "#amt", category: "Accessibility", severity: .must, text: "2.9 to 1."),
                      .init(screen: nil, selector: nil, category: "Missing states", severity: .should, text: "No declined screen.")],
                     from: copilot)
        #expect(opinion.notes.count == 3)
        #expect(opinion.notes[0].selector == "#amt")
        #expect(opinion.notes[0].severity == .must)
        #expect(opinion.notes[0].voices.map(\.reviewer) == [codex, copilot])
        #expect(opinion.pending.count == 3 && opinion.kept.isEmpty)
    }

    @Test func keptNotesSayWhereTheyAre() {
        let notes = [DesignOpinion.PinnedNote(screen: "approved", selector: "#amt", category: "Accessibility",
                                              severity: .must, voices: [], status: .kept, text: "Raise the contrast."),
                     DesignOpinion.PinnedNote(screen: nil, category: "Missing states", severity: .should,
                                              voices: [], status: .kept, text: "Add a declined screen.")]
        #expect(DesignSecondOpinion.feedback(notes, screens: [approved], names: "Codex and Copilot") == """
            Codex and Copilot looked at the design. Change it for these:
            - Accessibility, on the Approved screen at `#amt`: Raise the contrast.
            - Missing states, on the whole design: Add a declined screen.
            """)
    }

    @MainActor @Test func notesWaitForThePersonAndOnlyKeptOnesAreSent() async throws {
        let store = DesignOpinionStore()
        let screens = [approved]
        store.captureScreens = { screens, _, _ in
            screens.map { .init(screen: $0, light: "/tmp/\($0.id).png") }
        }
        store.askReviewer = { request, reviewer, _, _ in
            guard request.shots.count == 1 else { return .failure(.init(message: "No pictures")) }
            return reviewer.agent == .codex
                ? .success([.init(screen: "approved", selector: "#amt", category: "Accessibility", severity: .must, text: "Contrast."),
                            .init(screen: "approved", selector: "#tid", category: "Copy", severity: .look, text: "Hide the id.")])
                : .failure(.init(message: "Its answer was not a list of notes."))
        }
        let session = UUID()
        var asked = request()
        asked.shots = []
        store.ask(asked, screens: screens, reviewers: [codex, codex, copilot],
                  executables: [.codex: "/bin/codex", .copilot: "/bin/copilot"], in: session)
        #expect(store.opinion(session)?.lanes.count == 2)
        #expect(await waitUntil { store.opinion(session)?.isRunning == false })
        let opinion = try #require(store.opinion(session))
        #expect(opinion.request.shots.count == 1)
        #expect(opinion.lanes.first?.state == .finished("2 notes"))
        #expect(opinion.lanes.last?.state == .failed("Its answer was not a list of notes."))
        #expect(opinion.kept.isEmpty)

        let contrast = try #require(opinion.notes.first { $0.selector == "#amt" })
        let id = try #require(opinion.notes.first { $0.selector == "#tid" })
        store.edit(contrast.id, text: "Raise the amount's contrast to 4.5 to 1.", in: session)
        store.dismiss(id.id, in: session)
        let after = try #require(store.opinion(session))
        #expect(after.notes.count == 1)
        #expect(after.kept.first?.edited == true)
        #expect(after.kept.first?.text == "Raise the amount's contrast to 4.5 to 1.")

        store.markSent(count: 1, in: session)
        #expect(store.opinion(session)?.sent == 1)
        #expect(store.opinion(session)?.notes.isEmpty == true)
        store.dismiss(session)
        #expect(store.opinion(session) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct DesignSecondOpinionWebTests {
    @Test func everyScreenIsPicturedLightAndOnlyDarkWhenItHasADarkStyle() async throws {
        _ = NSApplication.shared
        let scratch = ScratchDirectory(prefix: "design-shots")
        try """
            <!doctype html><html><head><style>
            body { margin: 0; background: #fff; }
            @media (prefers-color-scheme: dark) { body { background: #111; } }
            </style></head><body>Approved</body></html>
            """.write(to: scratch.path("index.html"), atomically: true, encoding: .utf8)
        try """
            <!doctype html><html><body style="margin:0;background:#fff">Printing</body></html>
            """.write(to: scratch.path("printing.html"), atomically: true, encoding: .utf8)
        let screens = [DesignScreen(id: "approved", title: "Approved", path: "index.html", width: 200, height: 120),
                       DesignScreen(id: "printing", title: "Printing", path: "printing.html", width: 200, height: 120)]
        let shots = await DesignSecondOpinion.capture(screens, in: scratch.url,
                                                      to: scratch.url.appendingPathComponent("shots"))
        #expect(shots.map(\.screen.id) == ["approved", "printing"])
        #expect(shots[0].dark != nil)
        #expect(shots[1].dark == nil)
        let light = try #require(NSImage(contentsOfFile: shots[0].light))
        #expect(light.representations.first?.pixelsWide == 200)
    }

    @Test func pinsSitOnTheirElementAreNamedByTheirNoteAndStayOutOfPictures() async throws {
        _ = NSApplication.shared
        let coordinator = DesignWebContent.Coordinator()
        let viewport = DesignWebContent.makeViewport(coordinator: coordinator)
        viewport.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: viewport.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = viewport
        defer {
            DesignWebContent.dismantleNSView(viewport, coordinator: coordinator)
            window.contentView = nil
        }
        let webView = viewport.webView
        webView.loadHTMLString("""
            <!doctype html><html><body style="margin:0">
            <p id="amt" style="position:absolute;left:100px;top:50px;width:120px;height:40px;margin:0">€24.80</p>
            </body></html>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if !webView.isLoading, (try? await webView.evaluateJavaScript(
                "typeof window.__codeStationSetPins === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        coordinator.navigationPending = false
        var clicked: String?
        coordinator.onPin = { clicked = $0 }
        coordinator.setPins([DesignPin(id: "n1", selector: "#amt", severity: "must", number: 1,
                                       label: "Note 1, Accessibility: Contrast."),
                             DesignPin(id: "n2", selector: "#missing", severity: "look", number: 2,
                                       label: "Note 2, Copy: Gone.")],
                            hot: nil, in: webView)
        let pin = try #require(try await webView.evaluateJavaScript("""
            (() => {
              const buttons = document.querySelectorAll('[data-code-station-pins] button');
              const b = buttons[0];
              return {count: buttons.length, label: b.getAttribute('aria-label'),
                      left: parseFloat(b.style.left), top: parseFloat(b.style.top)};
            })()
            """) as? [String: Any])
        // A selector that matches nothing has no pin to draw.
        #expect(pin["count"] as? Int == 1)
        #expect(pin["label"] as? String == "Note 1, Accessibility: Contrast.")
        #expect(pin["left"] as? Double == 209)
        #expect(pin["top"] as? Double == 39)

        _ = try await webView.evaluateJavaScript("document.querySelector('[data-code-station-pins] button').click()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(clicked == "n1")

        _ = try await webView.evaluateJavaScript("window.__codeStationHidePins(true)")
        #expect(try await webView.evaluateJavaScript(
            "document.querySelector('[data-code-station-pins]').style.display") as? String == "none")
    }
}
