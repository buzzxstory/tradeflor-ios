import SwiftUI

/// Sign-up as on the website: name, username, email, phone, password -> a 6-digit code by email -> signed in;
/// the chosen username (and with it the TRADEFLOR PIN) is claimed right after (IdentitySetupView).
struct SignUpView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""
    @State private var username = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var confirmPassword = "" // checked on this screen only; never sent
    @State private var phoneNote: (ok: Bool, text: String)?
    @State private var showForgot = false
    @State private var usernameNote: String?
    @State private var busy = false
    @State private var error: String?
    @State private var pendingUserID: String?

    private var cleanUsername: String {
        username.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
    }
    private var ready: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty && cleanUsername.count >= 3 && email.contains("@")
            && password.count >= 8 && confirmPassword == password && usernameNote == nil && (phoneNote?.ok ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("signup.footer")) {
                    TextField("signup.name", text: $fullName).textContentType(.name)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("signup.username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: username) { _ in Task { await checkUsername() } }
                        if let usernameNote { Text(usernameNote).font(.caption).foregroundStyle(.red) }
                    }
                    TextField("signup.email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("signup.phone.optional", text: $phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                            .onChange(of: phone) { _ in Task { await checkPhone() } }
                        Text(phoneNote.map { $0.ok ? String(format: NSLocalizedString("signup.phone.saved", comment: ""), $0.text) : $0.text }
                             ?? NSLocalizedString("signup.phone.help", comment: ""))
                            .font(.caption).foregroundStyle(phoneNote.map { $0.ok ? Color.green : Color.red } ?? .secondary)
                    }
                    SecureField("signup.password", text: $password).textContentType(.newPassword)
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("signup.password.confirm", text: $confirmPassword).textContentType(.newPassword)
                        if !confirmPassword.isEmpty && confirmPassword != password {
                            Text("signup.password.mismatch").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                if let error {
                    Section {
                        if error.lowercased().contains("already registered") {
                            Text("signup.taken").foregroundStyle(.red).font(.footnote)
                            Button("signup.taken.signin") { dismiss() }
                            Button("signup.taken.forgot") { showForgot = true }
                        } else {
                            Text(error).foregroundStyle(.red).font(.footnote)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("signup.create").bold() }; Spacer() }
                    }
                    .disabled(!ready || busy)
                }
                .listRowBackground(Theme.accent.opacity(ready ? 1 : 0.4))
                .foregroundStyle(Theme.onAccent)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("signup.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .sheet(isPresented: $showForgot) { ForgotPasswordView() }
            .navigationDestination(isPresented: Binding(get: { pendingUserID != nil }, set: { if !$0 { pendingUserID = nil } })) {
                if let id = pendingUserID {
                    VerifyEmailView(userID: id, username: cleanUsername, displayName: fullName.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }

    private func checkUsername() async {
        let u = cleanUsername
        guard u.count >= 3 else { usernameNote = nil; return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard u == cleanUsername else { return }
        let r = await APIClient.shared.usernameAvailableSignup(u)
        usernameNote = r.available ? nil : (r.reason ?? NSLocalizedString("signup.username.taken", comment: ""))
    }

    /// POST /auth/phone-check (no sign-in): the number as it will be saved, or why it is not valid.
    private func checkPhone() async {
        let p = phone.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { phoneNote = nil; return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard p == phone.trimmingCharacters(in: .whitespaces) else { return }
        let api = APIClient.shared
        guard let (data, http) = try? await api.send(api.request("auth/phone-check", method: "POST", token: nil, body: ["Phone": p])) else {
            phoneNote = nil
            return
        }
        if http.statusCode == 200 {
            let f = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["formatted"] as? String ?? p
            phoneNote = (true, f)
        } else if http.statusCode == 400 {
            let why = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            phoneNote = (false, why.isEmpty ? NSLocalizedString("signup.phone.bad", comment: "") : why)
        } else {
            phoneNote = nil
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            UserDefaults.standard.set(cleanUsername, forKey: "tf.chosenUsername")
            pendingUserID = try await APIClient.shared.register(
                fullName: fullName.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces),
                phone: phone.trimmingCharacters(in: .whitespaces), password: password)
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch APIError.rateLimited {
            error = NSLocalizedString("login.error.rate", comment: "")
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// The 6-digit code from the email. Also reached from sign-in when the account's email is not verified yet.
struct VerifyEmailView: View {
    let userID: String
    let username: String
    let displayName: String
    @EnvironmentObject private var store: SessionStore
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var wait = 60

    var body: some View {
        Form {
            Section(footer: Text("verify.footer")) {
                TextField("verify.code", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .onChange(of: code) { v in code = String(v.filter(\.isNumber).prefix(6)) }
            }
            .listRowBackground(Theme.surface)
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
            if let info { Section { Text(info).foregroundStyle(Theme.accent).font(.footnote) }.listRowBackground(Theme.surface) }
            Section {
                Button { Task { await verify() } } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("verify.confirm").bold() }; Spacer() }
                }
                .disabled(code.count != 6 || busy)
                .listRowBackground(Theme.accent.opacity(code.count == 6 ? 1 : 0.4))
                .foregroundStyle(Theme.onAccent)
                Button { Task { await resend() } } label: {
                    Text(wait > 0 ? String(format: NSLocalizedString("verify.resend.wait", comment: ""), wait)
                                  : NSLocalizedString("verify.resend", comment: ""))
                }
                .disabled(wait > 0)
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(Text("verify.title"))
        .task {
            while wait > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                wait -= 1
            }
        }
    }

    private func verify() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let s = try await APIClient.shared.verifyEmail(userID: userID, code: code, username: username)
            if !displayName.isEmpty { UserDefaults.standard.set(displayName, forKey: "tf.chosenDisplayName") }
            store.adopt(s)
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("verify.wrong", comment: "") : why
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }

    private func resend() async {
        do {
            try await APIClient.shared.resendCode(userID: userID, purpose: "register")
            info = NSLocalizedString("verify.sent", comment: "")
        } catch {
            self.error = NSLocalizedString("verify.resend.failed", comment: "")
        }
        wait = 60
        Task {
            while wait > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                wait -= 1
            }
        }
    }
}

/// Forgot password: a code to the email, then a new password.
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var sent = false
    @State private var done = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(LocalizedStringKey(sent ? "forgot.footer.code" : "forgot.footer"))) {
                    TextField("signup.email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(sent)
                    if sent {
                        TextField("verify.code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        SecureField("forgot.new", text: $newPassword).textContentType(.newPassword)
                    }
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
                if done { Section { Text("forgot.done").foregroundStyle(Theme.accent) }.listRowBackground(Theme.surface) }
                Section {
                    Button { Task { await go() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text(LocalizedStringKey(sent ? "forgot.reset" : "forgot.send")).bold() }; Spacer() }
                    }
                    .disabled(busy || done || !email.contains("@") || (sent && (code.count < 6 || newPassword.count < 8)))
                }
                .listRowBackground(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("forgot.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
    }

    private func go() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if !sent {
                try await APIClient.shared.forgotPassword(email: email.trimmingCharacters(in: .whitespaces))
                sent = true
            } else {
                try await APIClient.shared.resetPassword(email: email.trimmingCharacters(in: .whitespaces), code: code,
                                                         newPassword: newPassword)
                done = true
            }
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// A new account picks its @username (which also gives it its TRADEFLOR PIN). Uses the name chosen at sign-up when
/// there was one, so most people never see this screen.
struct IdentitySetupView: View {
    let onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var username = UserDefaults.standard.string(forKey: "tf.chosenUsername") ?? ""
    @State private var displayName = UserDefaults.standard.string(forKey: "tf.chosenDisplayName") ?? ""
    @State private var busy = false
    @State private var error: String?
    @State private var triedSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("setup.footer")) {
                    TextField("signup.username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("signup.name", text: $displayName)
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
                Section {
                    Button { Task { await save() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("settings.save").bold() }; Spacer() }
                    }
                    .disabled(busy || username.count < 3)
                }
                .listRowBackground(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("setup.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chats.signout") { Task { await store.signOut() } } }
            }
        }
        .task {
            // the username chosen at sign-up: claim it without asking again
            guard !triedSaved, !username.isEmpty else { return }
            triedSaved = true
            await save()
        }
    }

    private func save() async {
        guard let token = store.session?.token else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let u = username.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
            _ = try await APIClient.shared.setupIdentity(token: token, username: u, displayName: displayName)
            UserDefaults.standard.removeObject(forKey: "tf.chosenUsername")
            UserDefaults.standard.removeObject(forKey: "tf.chosenDisplayName")
            onDone()
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }
}
