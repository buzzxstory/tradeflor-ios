import Foundation

// Settings > Linked Devices V2 (server aa69255): the account's sessions, signing one or all others out, and naming one.
// Mirrors listDevices / revokeDevice / revokeOtherDevices / renameDevice in desktop/src/shared/api/api.ts.

extension APIClient {
    /// Every session of my account, the current one first. A failure is thrown (never shown as an empty list).
    func linkedDevices(token: String) async throws -> [LinkedDevice] {
        let data = try await getJSON("auth/sessions", token: token)
        if data.isEmpty || data == Data("null".utf8) { return [] }
        return try decode([LinkedDevice].self, data)
    }

    /// Signs that session out. Returns false when the server no longer knows it (404: already signed out or expired).
    func signOutDevice(token: String, id: String) async throws -> Bool {
        let (data, http) = try await send(request("auth/sessions/revoke", method: "POST", token: token, body: ["id": id]))
        if http.statusCode == 404 { return false }
        try check(http, data)
        return true
    }

    /// Signs out every session but this one; returns how many were ended.
    func signOutOtherDevices(token: String) async throws -> Int {
        let (data, http) = try await send(request("auth/sessions/revoke-others", method: "POST", token: token, body: [:]))
        try check(http, data)
        struct Out: Decodable { let revoked: Int? }
        return (try? JSONDecoder().decode(Out.self, from: data))?.revoked ?? 0
    }

    /// Names a session (at most 40 characters; "" goes back to the automatic name). Too long is `.server(status: 400)`.
    func renameDevice(token: String, id: String, label: String) async throws {
        let (data, http) = try await send(request("auth/sessions/rename", method: "POST", token: token, body: ["id": id, "label": label]))
        try check(http, data)
    }
}
