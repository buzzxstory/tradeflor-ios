import XCTest

/// Guards against the touch and scrolling regressions the owner hit ("the list does not move under my finger"). It reads
/// the app's Swift sources (next to this file on the build Mac; a simulator run can read them) and fails when a pattern
/// that froze or stole a scroll comes back. Skipped when the sources are not reachable (a run on a device).
final class TouchGuardTests: XCTestCase {
    private struct Source {
        let name: String
        let text: String
    }

    private func sources() throws -> [Source] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TradeflorTests
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("Tradeflor", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("the app sources are not reachable from this run")
        }
        var out: [Source] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            out.append(Source(name: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8)))
        }
        if out.isEmpty { throw XCTSkip("no Swift sources found under \(root.path)") }
        return out
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// A list that fits on the screen must still follow the finger and spring back (WhatsApp); `.basedOnSize` froze the
    /// Chats and Groups lists when every row fitted.
    func testNoScrollViewRefusesToBounce() throws {
        for s in try sources() {
            XCTAssertEqual(count("scrollBounceBehavior(.basedOnSize", in: s.text), 0,
                           "\(s.name): a vertical list must bounce (.always or the default). If this is a small horizontal strip, add it to this test on purpose.")
            XCTAssertEqual(count(".scrollDisabled(", in: s.text), 0, "\(s.name): a scroll view is switched off")
        }
    }

    func testListNoBounceStillBounces() throws {
        let chrome = try sources().first { $0.name == "ListChrome.swift" }
        let text = try XCTUnwrap(chrome?.text, "ListChrome.swift not found")
        XCTAssertTrue(text.contains("struct ListNoBounce"))
        XCTAssertTrue(text.contains("scrollBounceBehavior(.always)"), "ListNoBounce must keep .always on the Chats and Groups lists")
    }

    /// A drag that wins over everything else (high priority) or starts at 0 pt takes a vertical pan away from the scroll
    /// view under it. The ones that exist are full-screen surfaces with no scroll behind them (pattern pad, mic hold, crop,
    /// status hold, video scrubber); a new one must be looked at before it is added here.
    func testNoNewDragThatStealsAScroll() throws {
        let allowedZeroDistance: [String: Int] = [
            "AppLockViews.swift": 1,        // the pattern pad (App Lock), no scroll view
            "ChatView.swift": 1,            // hold-to-record mic in the composer, outside the message list
            "MediaEditorPanels.swift": 1,   // crop frame in the media editor
            "MediaViewer.swift": 1,         // the video scrubber
            "StatusViewerScreen.swift": 1,  // press-and-hold pauses a status
            "OfficialAndCalendar.swift": 1, // the same hold in the Official viewer
            "PulseMeetup.swift": 1,         // Pulse walkie-talkie hold, in the bottom bar outside the panel's list
        ]
        for s in try sources() {
            XCTAssertEqual(count("highPriorityGesture(DragGesture", in: s.text), 0,
                           "\(s.name): a high-priority drag blocks the scroll under it; use simultaneousGesture with a horizontal-only check")
            let zero = count("DragGesture(minimumDistance: 0", in: s.text)
            XCTAssertLessThanOrEqual(zero, allowedZeroDistance[s.name] ?? 0,
                                     "\(s.name): a drag from 0 pt claims every touch; inside a list it stops the list from scrolling")
        }
    }

    /// Only taps (and the reviewed long press on chat bubbles) may take priority over a row's own gestures.
    func testHighPriorityGesturesAreTapsOrTheBubbleHold() throws {
        for s in try sources() {
            var rest = Substring(s.text)
            while let r = rest.range(of: "highPriorityGesture(") {
                let after = rest[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(after.hasPrefix("TapGesture") || after.hasPrefix("LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)"),
                              "\(s.name): unexpected high-priority gesture: \(after.prefix(60))")
                rest = rest[r.upperBound...]
            }
        }
    }
}
