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

    @State private var showPassword = false

    /// The website's light sign-in (55-auth-light.css): sky gradient with soft waves, one glass card, the flower mark,
    /// "Welcome back", pill fields, the teal "Sign in" button, and "Create account" / "Forgot password?" under it.
    var body: some View {
        ZStack {
            AuthBackground()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(RadialGradient(colors: [Theme.hex(0x28D2EB, 0.45), Theme.hex(0x3CA0FF, 0.15), .clear],
                                                         center: .center, startRadius: 0, endRadius: 95))
                                .frame(width: 190, height: 190).blur(radius: 6)
                            Image("BrandFlower").resizable().scaledToFit().frame(width: 104, height: 104)
                        }
                        .frame(height: 120)
                        .accessibilityHidden(true)
                        Text("login.welcome").font(.system(size: 32, weight: .heavy)).foregroundStyle(AuthStyle.navy)
                        Text("login.title").font(.system(size: 17, weight: .medium)).foregroundStyle(AuthStyle.ink2)
                            .padding(.top, 6).padding(.bottom, 20)

                        VStack(spacing: 14) {
                            AuthPill(icon: "person") {
                                TextField("", text: $username, prompt: Text("login.username").foregroundColor(AuthStyle.placeholder))
                                    .textContentType(.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .accessibilityIdentifier("login.username")
                            }
                            AuthPill(icon: "lock") {
                                Group {
                                    if showPassword {
                                        TextField("", text: $password, prompt: Text("login.password").foregroundColor(AuthStyle.placeholder))
                                    } else {
                                        SecureField("", text: $password, prompt: Text("login.password").foregroundColor(AuthStyle.placeholder))
                                    }
                                }
                                .textContentType(.password)
                                .submitLabel(.go)
                                .onSubmit { Task { await submit() } }
                                .accessibilityIdentifier("login.password")
                                Button { showPassword.toggle() } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye").font(.system(size: 19)).foregroundStyle(AuthStyle.muted)
                                        .frame(width: 40, height: 40)
                                }
                                .accessibilityLabel(Text("login.show"))
                            }
                            if let error {
                                Text(error)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.hex(0x9B1C33))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Theme.hex(0xFDECEF), in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hex(0xF5B9C4), lineWidth: 1))
                                    .accessibilityIdentifier("login.error")
                            }
                            Button { Task { await submit() } } label: {
                                HStack(spacing: 10) {
                                    if busy { ProgressView().tint(.white) } else {
                                        Text("login.submit")
                                        Image(systemName: "arrow.right")
                                    }
                                }
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .background(LinearGradient(colors: [Theme.hex(0x0AA5A8), Theme.hex(0x08879A), Theme.hex(0x066C86)],
                                                           startPoint: .top, endPoint: .bottom), in: Capsule())
                                .shadow(color: Theme.hex(0x088CAA, 0.55), radius: 14, y: 10)
                            }
                            .disabled(busy || username.isEmpty || password.isEmpty)
                            .opacity(username.isEmpty || password.isEmpty ? 0.7 : 1)
                            .accessibilityIdentifier("login.submit")
                        }

                        HStack(spacing: 14) {
                            Button { showSignUp = true } label: {
                                Label("login.signup", systemImage: "person.badge.plus").font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AuthStyle.tealDark)
                            }
                            Rectangle().fill(AuthStyle.line).frame(width: 1, height: 20)
                            Button { showForgot = true } label: {
                                Label("login.forgot", systemImage: "key").font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AuthStyle.ink2)
                            }
                        }
                        .padding(.top, 18)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .background(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.85), Theme.hex(0xF7FBFF, 0.76)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.hex(0x1E64BE, 0.25), radius: 30, y: 24)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 2))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 520)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.colorScheme, .light)
        .task { await ciAutoLogin() }
        .sheet(isPresented: $showSignUp) { SignUpView().preferredColorScheme(.dark) }
        .sheet(isPresented: $showForgot) { ForgotPasswordView().preferredColorScheme(.dark) }
        .sheet(isPresented: Binding(get: { unverifiedUserID != nil }, set: { if !$0 { unverifiedUserID = nil } })) {
            if let id = unverifiedUserID {
                NavigationStack { VerifyEmailView(userID: id, username: username, displayName: "") }.preferredColorScheme(.dark)
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

enum AuthStyle {
    static let navy = Theme.hex(0x0D1F45)
    static let ink2 = Theme.hex(0x2B3A55)
    static let muted = Theme.hex(0x4A566E)
    static let line = Theme.hex(0xCFDBEA)
    static let teal = Theme.hex(0x0B8FA8)
    static let tealDark = Theme.hex(0x08738A)
    static let placeholder = Theme.hex(0x5A667C)
}

/// The sky-blue ground of every signed-out screen, with the website's soft waves.
struct AuthBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.hex(0xF3F8FF), Theme.hex(0xE9F2FD), Theme.hex(0xDFECFB)], startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.78))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.70), control1: CGPoint(x: w * 0.35, y: h * 0.66), control2: CGPoint(x: w * 0.65, y: h * 0.86))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.hex(0x9FD3F5, 0.55), Theme.hex(0x5FB4EA, 0.35)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.86))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.82), control1: CGPoint(x: w * 0.4, y: h * 0.95), control2: CGPoint(x: w * 0.7, y: h * 0.74))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.hex(0x2E8FD0, 0.35), Theme.hex(0x0B5FA8, 0.45)], startPoint: .top, endPoint: .bottom))
            }
        }
        .ignoresSafeArea()
    }
}

/// A white pill field with its leading icon (.lx-pill).
struct AuthPill<Content: View>: View {
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(AuthStyle.muted).frame(width: 26)
            content()
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(AuthStyle.navy)
        .padding(.leading, 20).padding(.trailing, 10)
        .frame(minHeight: 58)
        .background(Theme.hex(0xFBFDFF), in: Capsule())
        .overlay(Capsule().stroke(Theme.hex(0xC4D6EE, 0.95), lineWidth: 1))
        .shadow(color: Theme.hex(0x3C6EB4, 0.2), radius: 10, y: 8)
    }
}
