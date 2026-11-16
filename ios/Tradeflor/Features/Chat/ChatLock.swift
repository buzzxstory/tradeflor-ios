import SwiftUI
import LocalAuthentication
import Security

/// Chat Lock, same rules as the website: the server only opens locked chats for a device session that proved the
/// account's Lock PIN; it then gives a short-lived unlock grant that travels in the X-Tradeflor-Unlock header.
/// Face ID here is a convenience on top: after the PIN is typed once, it can be kept in this iPhone's Keychain,
/// readable only after Face ID (or Touch ID) and only on this device. The PIN never goes anywhere but the server.
enum BiometricPIN {
    private static let service = "com.tradeflor.ios.lockpin"
    private static let account = "pin"

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    static var isSaved: Bool {
        let c = LAContext()
        c.interactionNotAllowed = true
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: c,
        ]
        let st = SecItemCopyMatching(q as CFDictionary, nil)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    static func save(_ pin: String) {
        delete()
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                       .biometryCurrentSet, nil) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: ac,
            kSecValueData as String: Data(pin.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    /// Shows Face ID; nil if cancelled, failed, or the enrolled faces changed since it was saved.
    static func read(reason: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let c = LAContext()
            c.localizedReason = reason
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: c,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }.value
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Asks for the Lock PIN (or Face ID when it was saved) and opens locked chats on this device.
struct UnlockSheet: View {
    let token: String
    let onUnlocked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var remember = true
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.accent).padding(.top, 30)
                Text("lock.title").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("lock.subtitle").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SecureField("lock.pin", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: pin) { v in pin = String(v.filter(\.isNumber).prefix(10)) }
                    .accessibilityIdentifier("lock.pin")
                if BiometricPIN.biometryAvailable {
                    Toggle(isOn: $remember) {
                        Text(String(format: NSLocalizedString("lock.remember", comment: ""), BiometricPIN.biometryName))
                    }
                    .tint(Theme.accent)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55)).multilineTextAlignment(.center)
                }
                Button {
                    Task { await unlock(with: pin, typed: true) }
                } label: {
                    ZStack {
                        if busy { ProgressView().tint(Theme.onAccent) } else { Text("lock.unlock").bold() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .disabled(busy || pin.count < 6)
                .opacity(pin.count < 6 ? 0.6 : 1)
                Text("lock.forgot").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.horizontal, 24)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
            }
        }
        .task {
            if BiometricPIN.isSaved {
                let reason = NSLocalizedString("lock.biometry.reason", comment: "")
                if let saved = await BiometricPIN.read(reason: reason) {
                    await unlock(with: saved, typed: false)
                    return
                }
            }
            focused = true
        }
    }

    private func unlock(with value: String, typed: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await APIClient.shared.unlockChats(token: token, pin: value)
            if typed {
                if remember && BiometricPIN.biometryAvailable { BiometricPIN.save(value) } else { BiometricPIN.delete() }
            }
            onUnlocked()
            dismiss()
        } catch APIError.refused(_) {
            if !typed { BiometricPIN.delete() } // the PIN was changed on another device
            error = NSLocalizedString("lock.wrong", comment: "")
            pin = ""
            focused = true
        } catch APIError.rateLimited {
            error = NSLocalizedString("lock.slow", comment: "")
        } catch APIError.server(let status) where status == 409 {
            error = NSLocalizedString("lock.nopin", comment: "")
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
            focused = true
        }
    }
}
