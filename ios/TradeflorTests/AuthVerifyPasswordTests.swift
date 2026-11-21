import XCTest
@testable import Tradeflor

/// BUG-057 (security audit 2026-11-21): the emailed sign-up code is sent with the password typed at sign-up or at the
/// blocked sign-in, so a sign-up started again by someone else with their own password cannot be finished by the owner's code.
final class AuthVerifyPasswordTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testVerifyEmailSendsThePassword() throws {
        let api = try source("Tradeflor/Core/APIClient.swift")
        XCTAssertTrue(api.contains("func verifyEmail(userID: String, code: String, username: String, password: String)"))
        XCTAssertTrue(api.contains("body[\"Password\"] = password"))
    }

    func testBothWaysToTheCodeScreenPassThePassword() throws {
        let flows = try source("Tradeflor/Features/Login/AuthFlows.swift")
        XCTAssertTrue(flows.contains("password: password)"), "sign-up passes the password typed there")
        XCTAssertTrue(flows.contains("verifyEmail(userID: userID, code: code, username: username, password: password)"))
        let login = try source("Tradeflor/Features/Login/LoginView.swift")
        XCTAssertTrue(login.contains("password: unverifiedPassword"), "the blocked sign-in passes the password typed there")
        XCTAssertTrue(login.contains("unverifiedPassword = password"))
    }

    func testThePasswordIsNeverSaved() throws {
        for f in ["Tradeflor/Features/Login/AuthFlows.swift", "Tradeflor/Features/Login/LoginView.swift"] {
            let s = try source(f)
            XCTAssertFalse(s.contains("set(password"), f)
            XCTAssertFalse(s.contains("set(unverifiedPassword"), f)
        }
    }

    /// The server's 409 text ("start again") is a 4xx: shown as it is, not replaced by "wrong code".
    func testThe409TextIsShown() throws {
        let api = try source("Tradeflor/Core/APIClient.swift")
        XCTAssertTrue(api.contains("(400..<500).contains(http.statusCode) && http.statusCode != 429"))
        let flows = try source("Tradeflor/Features/Login/AuthFlows.swift")
        XCTAssertTrue(flows.contains("error = why.isEmpty ? NSLocalizedString(\"verify.wrong\", comment: \"\") : why"))
    }
}
