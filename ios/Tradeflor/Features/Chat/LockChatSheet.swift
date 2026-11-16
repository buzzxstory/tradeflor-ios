import SwiftUI

/// "Lock this chat" / "Unlock this chat" (website ChatLock.tsx). Locking needs a fresh unlock (Lock PIN or Face ID)
/// first; with no Lock PIN yet the "Set a Lock PIN" form comes first.
struct LockChatSheet: View {
    let conversationID: String
    let name: String
    let locked: Bool
    var isGroup = false
    let onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var hide = false
    @State private var busy = false
    @State private var problem: String?
    @State private var needUnlock = false
    @State private var needPIN = false

    private var token: String { store.session?.token ?? "" }
    private var what: String { NSLocalizedString(isGroup ? "lockc.group" : "lockc.chat", comment: "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                        .frame(width: 60, height: 60).background(Theme.card, in: Circle())
                        .overlay(Circle().stroke(Theme.borderActive, lineWidth: 1.5))
                        .frame(maxWidth: .infinity)
                    Text(String(format: NSLocalizedString(locked ? "lockc.unlock.title" : "lockc.lock.title", comment: ""), what))
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity)
                    if locked {
                        Text(String(format: NSLocalizedString("lockc.unlock.note", comment: ""), name))
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    } else {
                        Text(String(format: NSLocalizedString("lockc.lock.note", comment: ""), name))
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        VStack(alignment: .leading, spacing: 8) {
                            bullet("lockc.p1")
                            bullet("lockc.p2")
                            bullet("lockc.p3")
                        }
                        Toggle(isOn: $hide) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("lockc.hide").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("lockc.hide.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(12)
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Button { Task { await go() } } label: {
                        Text(busy ? NSLocalizedString("lockc.moment", comment: "")
                             : String(format: NSLocalizedString(locked ? "lockc.unlock.btn" : "lockc.lock.btn", comment: ""), what))
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 48).background(Theme.accent, in: Capsule())
                    }
                    .disabled(busy)
                    Button("mute.cancel") { dismiss() }.foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .background(Theme.panelGradient.ignoresSafeArea())
        }
        .sheet(isPresented: $needUnlock) {
            UnlockSheet(token: token) { Task { await finish() } }
        }
        .sheet(isPresented: $needPIN) {
            SetLockPINView { Task { await go() } }
        }
    }

    private func bullet(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 7)
            Text(LocalizedStringKey(key)).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }

    private func go() async {
        problem = nil
        if APIClient.shared.unlockToken != nil {
            await finish()
            return
        }
        if let st = try? await APIClient.shared.ctLockState(token: token), !st.has_pin {
            needPIN = true
            return
        }
        needUnlock = true
    }

    private func finish() async {
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.ctSetLocked(token: token, conversationID: conversationID, locked: !locked, hidePreviews: hide)
            onDone()
            dismiss()
        } catch APIError.locked {
            needUnlock = true
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("lockc.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("lockc.failed", comment: "")
        }
    }
}

/// "Set a Lock PIN": the account password confirms it is you; 6 to 10 digits, typed twice.
struct SetLockPINView: View {
    var onSaved: () -> Void = {}
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var pin = ""
    @State private var repeatPIN = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("lockc.setpin.hint")) {
                    SecureField("lockc.password", text: $password).textContentType(.password)
                    SecureField("lockc.newpin", text: $pin).keyboardType(.numberPad)
                        .onChange(of: pin) { v in pin = String(v.filter(\.isNumber).prefix(10)) }
                    SecureField("lockc.repeat", text: $repeatPIN).keyboardType(.numberPad)
                        .onChange(of: repeatPIN) { v in repeatPIN = String(v.filter(\.isNumber).prefix(10)) }
                }
                .listRowBackground(Theme.surface)
                if let problem { Section { Text(problem).foregroundStyle(Theme.danger).font(.footnote) }.listRowBackground(Theme.surface) }
                if saved { Section { Text("lockc.saved").foregroundStyle(Theme.accent) }.listRowBackground(Theme.surface) }
                Section {
                    Button { Task { await save() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("lockc.setpin.save").bold() }; Spacer() }
                    }
                    .disabled(busy || password.isEmpty || pin.count < 6)
                }
                .listRowBackground(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("lockc.setpin.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
    }

    private func save() async {
        problem = nil
        guard pin == repeatPIN else { problem = NSLocalizedString("lockc.mismatch", comment: ""); return }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared.ctSetLockPIN(token: store.session?.token ?? "", password: password, pin: pin)
            saved = true
            BiometricPIN.delete()
            onSaved()
            dismiss()
        } catch APIError.refused(let why) {
            problem = why.contains("password") ? NSLocalizedString("lockc.badpassword", comment: "")
                : (why.isEmpty ? NSLocalizedString("lockc.failed", comment: "") : why)
        } catch {
            problem = NSLocalizedString("lockc.failed", comment: "")
        }
    }
}
