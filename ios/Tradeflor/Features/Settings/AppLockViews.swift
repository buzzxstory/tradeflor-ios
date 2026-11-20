import SwiftUI
import UIKit

extension AppLockKind: Identifiable { var id: String { rawValue } }

private let lockRed = Theme.dyn(0xFF4D59, 0xD8404A)

private func lockHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}

private func lockNotify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    UINotificationFeedbackGenerator().notificationOccurred(type)
}

/// The dark navy ground with the glowing curves, as the other full-screen screens.
struct AppLockBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.dyn(0x02242F, 0xF4FBFC), Theme.dyn(0x00131B, 0xEAF6F8), Theme.dyn(0x000F16, 0xE2F1F4)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ProfileHeroLines().frame(height: 280).frame(maxHeight: .infinity, alignment: .top).opacity(0.85).ignoresSafeArea()
            ProfileHeroLines().frame(height: 240).frame(maxHeight: .infinity, alignment: .bottom).opacity(0.7).ignoresSafeArea()
        }
    }
}

/// The dots of a PIN: they fill, with a glow, as the digits come in.
struct AppLockDots: View {
    let count: Int
    let total: Int
    var failed = false

    var body: some View {
        let tint = failed ? lockRed : Theme.accent
        HStack(spacing: 18) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < count ? tint : Color.clear)
                    .overlay(Circle().stroke(tint.opacity(0.65), lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .shadow(color: i < count ? tint.opacity(0.75) : .clear, radius: 7)
                    .scaleEffect(i < count ? 1.12 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: count)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(count) / \(total)"))
    }
}

private struct LockKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.18 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The number pad of the PIN lock: round glass keys, six dots above.
struct AppLockPinPad: View {
    @Binding var entry: String
    var failed = false
    var extra: AnyView? = nil
    let onComplete: (String) -> Void
    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
    /// Smaller keys on a short screen (iPhone SE / 8), so the pad and the rest fit.
    static let keySize: CGFloat = UIScreen.main.bounds.height < 700 ? 62 : 78

    var body: some View {
        VStack(spacing: 28) {
            AppLockDots(count: entry.count, total: AppLockRules.pinLength, failed: failed)
            VStack(spacing: 14) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 22) { ForEach(row, id: \.self) { key($0) } }
                }
                HStack(spacing: 22) {
                    Group { if let extra { extra } else { Color.clear } }.frame(width: AppLockPinPad.keySize, height: AppLockPinPad.keySize)
                    key("0")
                    Button {
                        guard !entry.isEmpty else { return }
                        entry.removeLast()
                        lockHaptic()
                    } label: {
                        Image(systemName: "delete.left").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.muted)
                            .frame(width: AppLockPinPad.keySize, height: AppLockPinPad.keySize).contentShape(Circle())
                    }
                    .buttonStyle(LockKeyStyle())
                    .opacity(entry.isEmpty ? 0.35 : 1)
                    .accessibilityLabel(Text("chat.delete"))
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight) // 1 2 3 stay 1 2 3 in Arabic
    }

    private func key(_ d: String) -> some View {
        Button {
            guard entry.count < AppLockRules.pinLength else { return }
            entry.append(d)
            lockHaptic()
            if entry.count == AppLockRules.pinLength { onComplete(entry) }
        } label: {
            Text(d).font(.system(size: 32, weight: .light)).foregroundStyle(Theme.text)
                .frame(width: AppLockPinPad.keySize, height: AppLockPinPad.keySize)
                .background(Circle().fill(Theme.dyn(0x0A3440, 0xFFFFFF, 0.55, 0.92)))
                .shadow(color: Theme.dyn(0x000000, 0x0097A5, 0, 0.10), radius: 8, y: 3)
                .overlay(Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(LockKeyStyle())
    }
}

/// The pattern lock: nine numbered dots, a glowing line that follows the finger, a dot passed on the way is taken too.
struct AppLockPatternPad: View {
    var failed = false
    let onDone: ([Int]) -> Void
    @State private var path: [Int] = []
    @State private var finger: CGPoint?
    @State private var drawing = false
    @State private var gen = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ox = (geo.size.width - side) / 2
            let oy = (geo.size.height - side) / 2
            let pts: [CGPoint] = (0..<9).map { i in
                CGPoint(x: ox + side * (CGFloat(i % 3) * 2 + 1) / 6, y: oy + side * (CGFloat(i / 3) * 2 + 1) / 6)
            }
            let tint: Color = failed ? lockRed : Theme.accent
            ZStack {
                Canvas { ctx, _ in
                    guard !path.isEmpty else { return }
                    var line = Path()
                    line.move(to: pts[path[0] - 1])
                    for d in path.dropFirst() { line.addLine(to: pts[d - 1]) }
                    if drawing, let f = finger { line.addLine(to: f) }
                    ctx.addFilter(.shadow(color: tint.opacity(0.85), radius: 8))
                    ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(0..<9, id: \.self) { i in dot(i + 1, at: pts[i], size: side / 3, tint: tint) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in touch(v.location, pts: pts, hit: side / 3 * 0.34) }
                    .onEnded { _ in finish() }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func dot(_ n: Int, at p: CGPoint, size: CGFloat, tint: Color) -> some View {
        let on = path.contains(n)
        return ZStack {
            Circle().stroke(tint.opacity(on ? 0.95 : 0.35), lineWidth: 2).frame(width: size * 0.5, height: size * 0.5)
            Circle().fill(on ? tint : Theme.dyn(0x0A3440, 0xFFFFFF, 0.6, 0.95)).frame(width: size * (on ? 0.38 : 0.34), height: size * (on ? 0.38 : 0.34))
            Text(verbatim: "\(n)").font(.system(size: size * 0.16, weight: .semibold)).foregroundStyle(on ? Theme.onAccent : Theme.muted)
        }
        .shadow(color: on ? tint.opacity(0.7) : .clear, radius: 10)
        .scaleEffect(on ? 1.1 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
        .position(p)
        .allowsHitTesting(false)
    }

    private func touch(_ p: CGPoint, pts: [CGPoint], hit: CGFloat) {
        if !drawing { path = []; gen += 1 } // a new stroke starts clean (the last one may still be fading)
        drawing = true
        finger = p
        for i in 0..<9 where hypot(p.x - pts[i].x, p.y - pts[i].y) < hit {
            let n = i + 1
            if path.contains(n) { break }
            // a stroke over a dot in between takes that dot first (1 to 3 passes 2)
            if let last = path.last, let mid = AppLockRules.between(last, n), !path.contains(mid) {
                path.append(mid)
                lockHaptic(.soft)
            }
            path.append(n)
            lockHaptic(.soft)
            break
        }
    }

    private func finish() {
        drawing = false
        finger = nil
        let done = path
        guard !done.isEmpty else { return }
        onDone(done)
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if g == gen { path = [] } }
    }
}

/// The lock screen: shown in its own window above everything while the app is locked.
struct AppLockScreen: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject private var lock = AppLock.shared
    @State private var entry = ""
    @State private var failed = false
    @State private var note: String?
    @State private var shake: CGFloat = 0
    @State private var confirmForgot = false
    @State private var bioAutoTried = false

    @State private var now = Date()
    private var waiting: Bool { (lock.lockedUntil ?? .distantPast) > now }

    var body: some View {
        ZStack {
            AppLockBackdrop()
            VStack(spacing: 22) {
                Spacer(minLength: 16)
                Image("BrandFlower").resizable().scaledToFit().frame(width: 64).shadow(color: Theme.accent.opacity(0.5), radius: 14)
                VStack(spacing: 6) {
                    Text(LocalizedStringKey(lock.kind == .pattern ? "lock2.enter.pattern" : "lock2.enter.pin"))
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Text(statusLine).font(.system(size: 14)).foregroundStyle(failed ? lockRed : Theme.muted)
                        .multilineTextAlignment(.center).frame(minHeight: 20)
                }
                pad.offset(x: shake).disabled(waiting).opacity(waiting ? 0.45 : 1)
                Spacer(minLength: 8)
                Button { confirmForgot = true } label: {
                    Text("lock2.forgot").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .tfColorScheme()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .task { await autoBiometrics() }
        // Face ID once the app is really in front (a cold launch asks while the scene is still becoming active); only once
        // per return: cancelling it to type the PIN does not bring it back
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await autoBiometrics() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            bioAutoTried = false
        }
        .alert(Text("lock2.forgot"), isPresented: $confirmForgot) {
            Button("lock2.signout", role: .destructive) { Task { await store.signOut() } }
            Button("chat.close", role: .cancel) {}
        } message: { Text("lock2.forgot.msg") }
    }

    @ViewBuilder private var pad: some View {
        if lock.kind == .pattern {
            AppLockPatternPad(failed: failed) { dots in submit(AppLockRules.patternSecret(dots), valid: AppLockRules.validPattern(dots)) }
                .frame(maxWidth: 330)
        } else {
            AppLockPinPad(entry: $entry, failed: failed, extra: bioButton) { code in
                submit(code, valid: AppLockRules.validPIN(code))
            }
        }
    }

    private var bioButton: AnyView? {
        guard lock.biometrics, lock.biometryAvailable else { return nil }
        return AnyView(
            Button { Task { await tryBiometrics() } } label: {
                Image(systemName: BiometricPIN.biometryName == "Touch ID" ? "touchid" : "faceid")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                    .frame(width: AppLockPinPad.keySize, height: AppLockPinPad.keySize).contentShape(Circle())
            }
            .buttonStyle(LockKeyStyle())
        )
    }

    private var statusLine: String {
        if let until = lock.lockedUntil, until > now {
            let s = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            let t = s >= 60 ? "\(s / 60):" + String(format: "%02d", s % 60) : "\(s)"
            return String(format: NSLocalizedString("lock2.wait", comment: ""), t)
        }
        return note ?? ""
    }

    private func submit(_ secret: String, valid: Bool) {
        guard !waiting else { return }
        guard valid else {
            // too short a pattern is only said, not counted as a wrong try
            note = NSLocalizedString("lock2.short", comment: "")
            entry = ""
            return
        }
        if lock.verify(secret) {
            lockNotify(.success)
            lock.unlock()
        } else {
            lockNotify(.error)
            note = NSLocalizedString("lock2.wrong", comment: "")
            failed = true
            entry = ""
            withAnimation(.linear(duration: 0.06).repeatCount(5, autoreverses: true)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { failed = false }
        }
    }

    private func autoBiometrics() async {
        guard !bioAutoTried, UIApplication.shared.applicationState == .active else { return }
        bioAutoTried = true
        await tryBiometrics()
    }

    private func tryBiometrics() async {
        guard !waiting else { return }
        if await lock.unlockWithBiometrics(reason: NSLocalizedString("lock2.bio.reason", comment: "")) { lock.unlock() }
    }
}

/// Create (twice) a PIN or a pattern.
struct AppLockSetupView: View {
    let kind: AppLockKind
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var entry = ""
    @State private var failed = false
    @State private var note: String?
    @State private var shake: CGFloat = 0

    var body: some View {
        ZStack {
            AppLockBackdrop()
            VStack(spacing: 22) {
                HStack {
                    Button { dismiss() } label: {
                        Label("chat.close", systemImage: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(Theme.accent.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Text(LocalizedStringKey(title)).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text(note ?? " ").font(.system(size: 14)).foregroundStyle(failed ? lockRed : Theme.muted).frame(minHeight: 20)
                }
                Group {
                    if kind == .pattern {
                        AppLockPatternPad(failed: failed) { dots in got(AppLockRules.patternSecret(dots), valid: AppLockRules.validPattern(dots)) }
                            .frame(maxWidth: 330)
                    } else {
                        AppLockPinPad(entry: $entry, failed: failed) { code in got(code, valid: AppLockRules.validPIN(code)) }
                    }
                }
                .offset(x: shake)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .tfColorScheme()
    }

    private var title: String {
        if kind == .pattern { return first == nil ? "lock2.create.pattern" : "lock2.confirm.pattern" }
        return first == nil ? "lock2.create.pin" : "lock2.confirm.pin"
    }

    private func got(_ secret: String, valid: Bool) {
        guard valid else {
            note = NSLocalizedString("lock2.short", comment: "")
            entry = ""
            return
        }
        guard let one = first else {
            first = secret
            note = nil
            entry = ""
            lockNotify(.success)
            return
        }
        if one == secret, AppLock.shared.setSecret(kind: kind, secret: secret) {
            lockNotify(.success)
            onDone()
            dismiss()
        } else {
            first = nil
            entry = ""
            failed = true
            note = NSLocalizedString("lock2.mismatch", comment: "")
            lockNotify(.error)
            withAnimation(.linear(duration: 0.06).repeatCount(5, autoreverses: true)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { failed = false; note = nil }
        }
    }
}

/// "Confirm it is you": the current PIN or pattern, before it is changed or turned off.
struct AppLockVerifyView: View {
    let onVerified: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = AppLock.shared
    @State private var entry = ""
    @State private var failed = false
    @State private var note: String?
    @State private var shake: CGFloat = 0
    @State private var now = Date()

    private var waiting: Bool { (lock.lockedUntil ?? .distantPast) > now }
    private var line: String {
        if let until = lock.lockedUntil, until > now {
            let s = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            let t = s >= 60 ? "\(s / 60):" + String(format: "%02d", s % 60) : "\(s)"
            return String(format: NSLocalizedString("lock2.wait", comment: ""), t)
        }
        return note ?? " "
    }

    var body: some View {
        ZStack {
            AppLockBackdrop()
            VStack(spacing: 22) {
                HStack {
                    Button { dismiss() } label: {
                        Label("chat.close", systemImage: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(Theme.accent.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Text("lock2.verify").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text(line).font(.system(size: 14)).foregroundStyle(failed ? lockRed : Theme.muted).frame(minHeight: 20)
                }
                Group {
                    if lock.kind == .pattern {
                        AppLockPatternPad(failed: failed) { dots in check(AppLockRules.patternSecret(dots), valid: AppLockRules.validPattern(dots)) }
                            .frame(maxWidth: 330)
                    } else {
                        AppLockPinPad(entry: $entry, failed: failed) { code in check(code, valid: AppLockRules.validPIN(code)) }
                    }
                }
                .offset(x: shake).disabled(waiting).opacity(waiting ? 0.45 : 1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .tfColorScheme()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func check(_ secret: String, valid: Bool) {
        guard !waiting else { return }
        guard valid else { note = NSLocalizedString("lock2.short", comment: ""); entry = ""; return }
        if lock.verify(secret) {
            lockNotify(.success)
            dismiss()
            onVerified()
        } else {
            lockNotify(.error)
            failed = true
            entry = ""
            note = NSLocalizedString("lock2.wrong", comment: "")
            withAnimation(.linear(duration: 0.06).repeatCount(5, autoreverses: true)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { failed = false }
        }
    }
}

/// Settings > App Lock: the person chooses one of the two lock types, the time before it comes back, and Face ID.
struct AppLockSettingsPage: View {
    @ObservedObject private var lock = AppLock.shared
    @State private var setupKind: AppLockKind?
    @State private var verifyFor: Action?
    @State private var afterVerify: Action?

    enum Action: Identifiable, Equatable {
        case disable
        case change(AppLockKind)
        var id: String {
            switch self {
            case .disable: return "disable"
            case .change(let k): return "change-" + k.rawValue
            }
        }
    }

    private static let delays: [(TimeInterval, String)] = [
        (0, "lock2.d0"), (30, "lock2.d30"), (60, "lock2.d60"), (300, "lock2.d300"), (900, "lock2.d900"),
    ]

    var body: some View {
        SettingsPage(title: NSLocalizedString("lock2.title", comment: ""), subtitle: NSLocalizedString("lock2.sub", comment: ""), icon: "lock.shield") {
            SBanner(icon: "lock.shield", title: NSLocalizedString("lock2.banner.title", comment: ""),
                    subtitle: NSLocalizedString("lock2.banner.sub", comment: ""))
            SSection(text: NSLocalizedString("lock2.type", comment: ""))
            HStack(spacing: 12) {
                typeCard(.pin)
                typeCard(.pattern)
            }
            if lock.enabled {
                SSection(text: NSLocalizedString("lock2.options", comment: ""))
                SCard {
                    HStack {
                        Text("lock2.delay").font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
                        Spacer()
                        Picker("", selection: $lock.delay) {
                            ForEach(Self.delays, id: \.0) { d in Text(LocalizedStringKey(d.1)).tag(d.0) }
                        }
                        .pickerStyle(.menu).tint(Theme.accent)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 56)
                    if lock.biometryAvailable {
                        SDivider()
                        SToggleRow(icon: BiometricPIN.biometryName == "Touch ID" ? "touchid" : "faceid",
                                   title: String(format: NSLocalizedString("lock2.bio", comment: ""), BiometricPIN.biometryName),
                                   isOn: $lock.biometrics)
                    }
                }
                Button(role: .destructive) { verifyFor = .disable } label: {
                    Text("lock2.disable").font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.danger)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SetUI.danger.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .fullScreenCover(item: $setupKind) { k in AppLockSetupView(kind: k) {} }
        .fullScreenCover(item: $verifyFor, onDismiss: runAfterVerify) { a in
            AppLockVerifyView { afterVerify = a }
        }
    }

    /// The verify screen has closed: do what it was for (turn off, or start the new lock).
    private func runAfterVerify() {
        guard let a = afterVerify else { return }
        afterVerify = nil
        switch a {
        case .disable: lock.disable()
        case .change(let k): setupKind = k
        }
    }

    private func typeCard(_ kind: AppLockKind) -> some View {
        let on = lock.enabled && lock.kind == kind
        return Button {
            if !lock.enabled { setupKind = kind } else { verifyFor = .change(kind) }
        } label: {
            VStack(spacing: 10) {
                glyph(kind).frame(height: 64)
                Text(LocalizedStringKey(kind == .pin ? "lock2.pin" : "lock2.pattern")).font(.system(size: 17, weight: .bold)).foregroundStyle(SetUI.text)
                Text(LocalizedStringKey(on ? "lock2.on" : (kind == .pin ? "lock2.pin.sub" : "lock2.pattern.sub")))
                    .font(.system(size: 12.5)).foregroundStyle(on ? Theme.accent : SetUI.sub)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(on ? Theme.accent : Theme.accent.opacity(0.25), lineWidth: on ? 2 : 1))
            .shadow(color: on ? Theme.accent.opacity(0.35) : .clear, radius: 10)
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent).padding(10)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// A small picture of each lock: a number pad, or dots joined by a line.
    @ViewBuilder private func glyph(_ kind: AppLockKind) -> some View {
        if kind == .pin {
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.accent.opacity(0.75)).frame(width: 11, height: 11) } }
                }
            }
        } else {
            Canvas { ctx, size in
                let step = size.height / 3
                func p(_ i: Int) -> CGPoint {
                    CGPoint(x: size.width / 2 + (CGFloat(i % 3) - 1) * step, y: step / 2 + CGFloat(i / 3) * step)
                }
                var line = Path()
                line.move(to: p(0)); line.addLine(to: p(1)); line.addLine(to: p(4)); line.addLine(to: p(8))
                ctx.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                for i in 0..<9 {
                    let c = p(i)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                             with: .color([0, 1, 4, 8].contains(i) ? Theme.accent : Theme.accent.opacity(0.55)))
                }
            }
            .frame(width: 66, height: 64)
        }
    }
}
