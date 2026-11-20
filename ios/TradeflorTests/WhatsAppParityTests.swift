import XCTest
import UIKit
@testable import Tradeflor

/// Home Screen quick actions and the notification extension (owner, 2026-11-20: "same as WhatsApp").
final class WhatsAppParityTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sources not reachable") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testQuickActionTypesMatchTheInfoPlist() throws {
        let yml = try source("project.yml")
        for a in [QuickActions.Action.search, .newChat, .camera, .myQR] {
            XCTAssertTrue(yml.contains("UIApplicationShortcutItemType: \(a.rawValue)"), "\(a.rawValue) is not declared")
        }
    }

    @MainActor
    func testQuickActionIsTaken() {
        let q = QuickActions.shared
        q.pending = nil
        XCTAssertTrue(q.handle(UIApplicationShortcutItem(type: QuickActions.Action.newChat.rawValue, localizedTitle: "New Chat")))
        XCTAssertEqual(q.pending, .newChat)
        XCTAssertFalse(q.handle(UIApplicationShortcutItem(type: "other", localizedTitle: "x")))
        q.pending = nil
    }

    func testExtensionIsEmbeddedAndSharesTheKeys() throws {
        let yml = try source("project.yml")
        XCTAssertTrue(yml.contains("- target: TradeflorNotify"))
        XCTAssertTrue(yml.contains("NSExtensionPointIdentifier: com.apple.usernotifications.service"))
        let app = try source("Entitlements/Tradeflor.entitlements")
        let ext = try source("Entitlements/TradeflorNotify.entitlements")
        XCTAssertTrue(app.contains("$(AppIdentifierPrefix)com.tradeflor.ios.shared"))
        XCTAssertTrue(ext.contains("$(AppIdentifierPrefix)com.tradeflor.ios.shared"))
        // the app's own group stays first: the saved session must stay readable after the update
        let own = try XCTUnwrap(app.range(of: "<string>$(AppIdentifierPrefix)com.tradeflor.ios</string>"))
        let shared = try XCTUnwrap(app.range(of: "<string>$(AppIdentifierPrefix)com.tradeflor.ios.shared</string>"))
        XCTAssertLessThan(own.lowerBound, shared.lowerBound)
        let push = try source("Tradeflor/Core/PushManager.swift")
        XCTAssertTrue(push.contains("PushKeys.mirrorShared()"))
    }

    /// The floating dock never covers the last row or the last line of a page (owner, 2026-11-20: the last chat and the
    /// end of Settings > Notifications stayed under the dock). The room sits on each scroll view itself.
    func testEveryTabScrollViewKeepsRoomForTheDock() throws {
        for f in ["Tradeflor/Features/Chats/ChatListView.swift", "Tradeflor/Features/Groups/GroupsListView.swift",
                  "Tradeflor/Features/Status/CalendarView.swift", "Tradeflor/Features/Status/TradeFlorView.swift",
                  "Tradeflor/Features/Settings/LinkedDevicesView.swift"] {
            XCTAssertTrue(try source(f).contains(".modifier(DockSpace())"), "\(f) has no room for the dock")
        }
        let settings = try source("Tradeflor/Features/Settings/SettingsView.swift")
        XCTAssertGreaterThanOrEqual(settings.components(separatedBy: ".modifier(DockSpace())").count - 1, 3,
                                    "Settings and both SettingsPage looks need room for the dock")
    }
}
