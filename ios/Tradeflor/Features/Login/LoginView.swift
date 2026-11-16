import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showSignUp = false
    @State private var showForgot = false
    @State private var unverifiedUserID: String?

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.top, 64)
                        .accessibilityHidden(true)

                    Text("login.title")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        TextField("login.username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .fieldStyle()
                            .accessibilityIdentifier("login.username")
                        SecureField("login.password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                            .fieldStyle()
                            .accessibilityIdentifier("login.password")
                    }

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("login.error")
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        ZStack {
                            if busy {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Text("login.submit").bold()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(busy || username.isEmpty || password.isEmpty)
                    .opacity(username.isEmpty || password.isEmpty ? 0.6 : 1)
                    .accessibilityIdentifier("login.submit")

                    Button("login.forgot") { showForgot = true }
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                    HStack(spacing: 4) {
                        Text("login.noaccount").foregroundStyle(.secondary)
                        Button("login.signup") { showSignUp = true }.foregroundStyle(Theme.accent).bold()
                    }
                    .font(.footnote)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await ciAutoLogin() }
        .sheet(isPresented: $showSignUp) { SignUpView() }
        .sheet(isPresented: $showForgot) { ForgotPasswordView() }
        .sheet(isPresented: Binding(get: { unverifiedUserID != nil }, set: { if !$0 { unverifiedUserID = nil } })) {
            if let id = unverifiedUserID {
                NavigationStack { VerifyEmailView(userID: id, username: username, displayName: "") }
            }
        }
    }

    private func submit() async {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await store.signIn(username: username, password: password)
        } catch let e as APIError {
            error = Self.message(for: e)
            if case let .emailNotVerified(uid) = e, !uid.isEmpty {
                unverifiedUserID = uid
                try? await APIClient.shared.resendCode(userID: uid, purpose: "register")
            }
        } catch {
            self.error = Self.message(for: .network)
        }
    }

    static func message(for e: APIError) -> String {
        switch e {
        case .badCredentials: return NSLocalizedString("login.error.credentials", comment: "")
        case .emailNotVerified: return NSLocalizedString("login.error.unverified", comment: "")
        case .rateLimited: return NSLocalizedString("login.error.rate", comment: "")
        case .suspended: return NSLocalizedString("login.error.suspended", comment: "")
        case .network: return NSLocalizedString("login.error.network", comment: "")
        case .server(let status): return String(format: NSLocalizedString("login.error.server", comment: ""), status)
        case .decoding: return String(format: NSLocalizedString("login.error.server", comment: ""), 200)
        case .locked: return NSLocalizedString("chat.locked", comment: "")
        case .refused(let why): return why.isEmpty ? NSLocalizedString("chat.refused", comment: "") : why
        }
    }

    /// CI only (Debug simulator builds): the workflow passes a test account from the repo's GitHub secrets
    /// through the launch environment, so the screenshots can show the signed-in app. This code is not
    /// compiled into the Release build that gets sideloaded.
    private func ciAutoLogin() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let u = env["TF_CI_USERNAME"], let p = env["TF_CI_PASSWORD"], !u.isEmpty, !p.isEmpty else { return }
        username = u
        password = p
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await submit()
        #endif
    }
}

private extension View {
    func fieldStyle() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .foregroundStyle(.white)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
    }
}
