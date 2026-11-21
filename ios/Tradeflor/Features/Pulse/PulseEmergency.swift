import SwiftUI
import Combine

/// The emergency screen, on any tab (PULSE_SAFETY_RESPONSE_SPEC.md sections 2 and 3). A recipient sees "EMERGENCY — FRIEND
/// NEEDS HELP" with Call, Message, View on map, the attached position, I'm responding and Contact emergency services (a
/// list, never dialled by itself). The sender sees "YOUR SOS IS ACTIVE", the delivery and each person's state, I'm safe…
/// (asked first) and Cancel this SOS.
struct PulseEmergencyScreen: View {
    let token: String
    let alertID: String
    @ObservedObject private var center = SOSCenter.shared
    @State private var now = Date()
    @State private var askSafe = false
    @State private var askCancel = false
    @State private var lines = false
    @State private var busy = false
    @State private var problem: String?
    // one timer for the life of the screen (a Timer.publish written in body is made again on every redraw, audit 20)
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var e: PulseEmergency? { center.emergency(alertID) }
    private var mine: Bool { e?.user_id == center.me }
    private var others: [PulseEmergency] { center.active.filter { $0.isActive && $0.id != alertID && $0.user_id != center.me } }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.hex(0xB8102A), Theme.hex(0x5A0612), Theme.hex(0x22020A)], center: .top, startRadius: 10, endRadius: 700)
                .ignoresSafeArea()
            if let e {
                ScrollView { content(e).padding(20) }
            } else if center.closed.contains(alertID) {
                VStack(spacing: 14) {
                    Text("sos.closed").font(.headline)
                    Button("chat.close") { center.shown = nil }
                }
            } else {
                // an event came before the list had it: loading, asked again (audit 8)
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("sos.loading").font(.headline)
                    Button("sos.minimize") { center.shown = nil }.font(.footnote.weight(.semibold))
                }
                .task(id: alertID) { await center.loadMissing(alertID) }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { center.markSeen(alertID) }
        .onChange(of: center.active) { _ in center.markSeen(alertID) } // opened from a push before the list came
        .onReceive(ticker) { now = $0 }
        .alert(Text("sos.safe.q"), isPresented: $askSafe) {
            Button("sos.safe.confirm") { Task { await close("safe") } }
            Button("sos.safe.keep", role: .cancel) {}
        } message: { Text("sos.safe.sub") }
        .alert(Text("sos.cancel.q"), isPresented: $askCancel) {
            Button("sos.cancel.confirm", role: .destructive) { Task { await close("cancelled") } }
            Button("sos.safe.keep", role: .cancel) {}
        }
        .confirmationDialog(Text("sos.em.title"), isPresented: $lines, titleVisibility: .visible) {
            ForEach(PulseSOSRules.lines(region: Locale.current.region?.identifier)) { l in
                Button(l.label + " · " + l.number + (l.local ? NSLocalizedString("sos.em.local", comment: "") : "")) {
                    if let u = URL(string: "tel:" + l.number) { UIApplication.shared.open(u) }
                }
            }
            Button("notes.cancel", role: .cancel) {}
        } message: { Text("sos.em.note") }
    }

    @ViewBuilder private func content(_ e: PulseEmergency) -> some View {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { center.shown = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel(Text("sos.minimize"))
            }
            Text(LocalizedStringKey(mine ? "sos.mine.head" : "sos.head")).font(.system(size: 13, weight: .black)).tracking(1.6).opacity(0.9)
            Avatar(token: token, userID: e.user_id, avatarID: center.people[e.user_id]?.avatar_id, title: center.name(e.user_id), size: 84)
                .overlay(Circle().stroke(.white, lineWidth: 3))
            Text(verbatim: mine ? NSLocalizedString("sos.mine.title", comment: "") : String(format: NSLocalizedString("sos.needs", comment: ""), center.name(e.user_id)))
                .font(.system(size: 26, weight: .heavy)).multilineTextAlignment(.center)
            if let r = e.reason, !r.isEmpty { Text(verbatim: r).font(.title3.weight(.semibold)) }
            Text(verbatim: timeLine(e, nowMs: nowMs)).font(.subheadline).opacity(0.85)
            if let t = e.circle_title, !t.isEmpty {
                Text(verbatim: t + (e.circle_live == false ? " · " + NSLocalizedString("sos.meetup.ended", comment: "") : "")).font(.footnote).opacity(0.8)
            }
            Text(verbatim: locationLine(e, nowMs: nowMs)).font(.footnote).opacity(0.85).multilineTextAlignment(.center)
            if mine { senderPart(e) } else { recipientPart(e) }
            if let problem { Text(verbatim: problem).font(.footnote).padding(10).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)) }
            Text("sos.footer").font(.caption).multilineTextAlignment(.center).opacity(0.75).padding(.top, 6)
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("sos.also").font(.caption.weight(.heavy)).opacity(0.8)
                    ForEach(others) { o in
                        Button { center.open(o.id) } label: {
                            Label(String(format: NSLocalizedString("sos.needs", comment: ""), center.name(o.user_id)), systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func timeLine(_ e: PulseEmergency, nowMs: Int64) -> String {
        guard let c = e.created_at else { return "" }
        let d = Date(timeIntervalSince1970: Double(c) / 1000)
        return DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) + " · " + PulseRules.agoText(c, now: nowMs)
    }

    private func locationLine(_ e: PulseEmergency, nowMs: Int64) -> String {
        guard e.hasPosition else { return NSLocalizedString("sos.noloc", comment: "") }
        let acc = PulseRules.distanceText(e.accuracy ?? 0)
        let age = e.location_at.map { PulseRules.agoText($0, now: nowMs) } ?? ""
        return String(format: NSLocalizedString("sos.loc", comment: ""), acc, age)
    }

    private var responders: [String] {
        (e?.rows ?? []).filter { $0.responding_at != nil }.map { center.name($0.user_id) }
    }

    // MARK: sender

    @ViewBuilder private func senderPart(_ e: PulseEmergency) -> some View {
        let dl = PulseSOSRules.deliveryText(e, responding: responders)
        VStack(spacing: 6) {
            Text(verbatim: dl.line).font(.headline)
            if !dl.detail.isEmpty { Text(verbatim: dl.detail).font(.footnote).opacity(0.85).multilineTextAlignment(.center) }
        }
        VStack(spacing: 6) {
            ForEach(e.rows, id: \.user_id) { r in
                HStack {
                    Text(verbatim: center.name(r.user_id)).font(.callout.weight(.semibold))
                    Spacer()
                    Text(verbatim: PulseSOSRules.recipientState(r)).font(.caption.weight(.semibold)).opacity(0.85)
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        if e.isActive {
            Button { askSafe = true } label: {
                Text("sos.safe").font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 52)
                    .background(PulseInk.green, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Theme.hex(0x04222C))
            }
            .buttonStyle(.plain).disabled(busy)
            Button("sos.cancel.link") { askCancel = true }.font(.footnote.weight(.semibold)).opacity(0.9)
        }
    }

    // MARK: recipient

    @ViewBuilder private func recipientPart(_ e: PulseEmergency) -> some View {
        if !responders.isEmpty {
            Text(verbatim: String(format: NSLocalizedString("sos.responders", comment: ""), PulseSOSRules.names(responders))).font(.footnote).opacity(0.9)
                .multilineTextAlignment(.center)
        }
        let myRow = e.rows.first { $0.user_id == center.me }
        let responding = myRow?.responding_at != nil
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            action("phone.fill", "sos.call") { Task { await call(e) } }
            action("message.fill", "sos.message") { Task { await message(e) } }
            if e.circle_live == true, let c = e.circle_id {
                action("map.fill", "sos.viewmap") {
                    center.shown = nil
                    PulseStore.shared.openCircle = c
                    TradeFlorView.go("tradeflor")
                }
            }
            if e.hasPosition, let lat = e.lat, let lon = e.lon {
                action("mappin.and.ellipse", "sos.openmaps") {
                    if let u = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=SOS") { UIApplication.shared.open(u) }
                }
            }
        }
        Button {
            Task {
                busy = true
                problem = await center.setResponding(e.id, !responding) ? nil : NSLocalizedString("sos.responding.failed", comment: "")
                busy = false
            }
        } label: {
            Label(LocalizedStringKey(responding ? "sos.responding.undo" : "sos.responding"), systemImage: responding ? "arrow.uturn.backward" : "figure.run")
                .font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Theme.hex(0xB8102A))
        }
        .buttonStyle(.plain).disabled(busy)
        if responding { Text("sos.responding.note").font(.caption).opacity(0.8) }
        Button { lines = true } label: {
            Label("sos.em.title", systemImage: "cross.case.fill").font(.callout.weight(.bold)).frame(maxWidth: .infinity, minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func action(_ icon: String, _ key: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20, weight: .bold))
                Text(LocalizedStringKey(key)).font(.footnote.weight(.bold)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func conversation(_ e: PulseEmergency) async -> String? {
        do { return try await APIClient.shared.directConversation(token: token, with: e.user_id) } catch {
            problem = NSLocalizedString("sos.notcontact", comment: "")
            return nil
        }
    }

    private func call(_ e: PulseEmergency) async {
        guard let conv = await conversation(e) else { return }
        center.shown = nil // the call screen comes up; the red pill brings this back
        CallManager.shared.start(conversationID: conv, peerName: center.name(e.user_id), peerID: e.user_id)
    }

    private func message(_ e: PulseEmergency) async {
        guard let conv = await conversation(e) else { return }
        center.shown = nil
        LocalNotifier.shared.tappedConversation = conv
    }

    private func close(_ how: String) async {
        busy = true
        defer { busy = false }
        if await center.resolve(alertID, how: how) {
            center.shown = nil
        } else {
            problem = NSLocalizedString("sos.resolve.failed", comment: "")
        }
    }
}

/// The emergency screen's item (the alert id).
struct SOSShown: Identifiable, Equatable { let id: String }

/// The red pill at the top of the app while an SOS is active and its screen is minimized: "<name> needs help" (+N).
struct PulseEmergencyPill: View {
    @ObservedObject private var center = SOSCenter.shared

    var body: some View {
        let list = center.active.filter(\.isActive)
        if center.shown == nil, let first = list.first(where: { $0.user_id != center.me }) ?? list.first {
            Button { center.open(first.id) } label: {
                HStack(spacing: 8) {
                    Text(verbatim: "SOS").font(.system(size: 10, weight: .black)).foregroundStyle(Theme.hex(0xB8102A))
                        .frame(width: 28, height: 28).background(.white, in: Circle())
                    Text(verbatim: first.user_id == center.me ? NSLocalizedString("sos.mine.title", comment: "")
                         : String(format: NSLocalizedString("sos.needs", comment: ""), center.name(first.user_id)))
                        .font(.subheadline.weight(.heavy)).lineLimit(1)
                    if list.count > 1 { Text(verbatim: "+\(list.count - 1)").font(.caption.weight(.heavy)).opacity(0.9) }
                }
                .foregroundStyle(.white)
                .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
                .background(LinearGradient(colors: [Theme.hex(0xFF4A5C), Theme.hex(0xB8102A)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                .shadow(color: Theme.hex(0xFF3B4E).opacity(0.5), radius: 10)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel(Text("sos.reopen"))
        }
    }
}

/// The short line after an SOS event ("<name> is responding", "<name> is safe").
struct PulseSOSToast: View {
    @ObservedObject private var center = SOSCenter.shared

    var body: some View {
        if let t = center.toast {
            Text(verbatim: t).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.hex(0x062A33, 0.96), in: Capsule())
                .onAppear { UIAccessibility.post(notification: .announcement, argument: t) }
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if center.toast == t { center.toast = nil }
                }
        }
    }
}


/// Pulse SOS above every sheet and full-screen cover (audit 1): the emergency screen, a safety alert sent to me, the red
/// pill and the toasts live in their own window over the app's window (under App Lock's window, so nothing shows while the
/// app is locked). Outside the full screen only the pill takes touches; the rest passes through to the app.
@MainActor
final class SOSWindow {
    static let shared = SOSWindow()
    private var window: SOSPassWindow?
    private var host: UIHostingController<AnyView>?
    private var subs = Set<AnyCancellable>()
    private var token = ""
    /// The pill's frame in the window (the only place that takes touches while nothing covers the screen).
    var hot: CGRect = .zero
    /// The emergency screen or a safety alert is up: the whole window takes touches.
    private(set) var full = false

    private init() {
        let c = SOSCenter.shared, p = PulseStore.shared, calls = CallManager.shared
        Publishers.CombineLatest4(c.$shown, c.$active, c.$toast, p.$incomingAlert)
            .combineLatest(calls.$showScreen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subs)
    }

    func attach(token: String) {
        guard token != self.token else { return }
        self.token = token
        window?.isHidden = true
        window = nil
        host = nil
        update()
    }

    func detach() {
        token = ""
        window?.isHidden = true
        window = nil
        host = nil
    }

    private func update() {
        let c = SOSCenter.shared
        let callUp = CallManager.shared.showScreen // a call screen is never hidden under it
        full = !callUp && (c.shown != nil || PulseStore.shared.incomingAlert != nil)
        let wanted = !token.isEmpty && !callUp && (full || c.active.contains(where: \.isActive) || c.toast != nil)
        if wanted, window == nil { make() }
        guard let w = window else { return }
        w.isHidden = !wanted
        host?.view.accessibilityViewIsModal = full
        if full, !w.isKeyWindow { w.makeKey() }
    }

    private func make() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached })
        else { return }
        let w = SOSPassWindow(windowScene: scene)
        w.windowLevel = .alert - 1 // over the app's sheets and covers, under App Lock (.alert + 1 / + 2)
        let h = UIHostingController(rootView: AnyView(SOSLayer(token: token)))
        h.view.backgroundColor = .clear
        w.rootViewController = h
        w.overrideUserInterfaceStyle = .dark
        w.isHidden = false
        window = w
        host = h
    }
}

final class SOSPassWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let s = SOSWindow.shared
        guard s.full || s.hot.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct SOSHotKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}

/// What the SOS window shows: the emergency screen, else a safety alert, else the pill and the toast at the top.
private struct SOSLayer: View {
    let token: String
    @ObservedObject private var center = SOSCenter.shared
    @ObservedObject private var pulse = PulseStore.shared
    @ObservedObject private var calls = CallManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea().allowsHitTesting(false)
            if calls.showScreen {
                EmptyView()
            } else if let id = center.shown {
                PulseEmergencyScreen(token: token, alertID: id).id(id)
                    .transition(.move(edge: .bottom))
            } else if let a = pulse.incomingAlert {
                PulseAlertScreen(token: token, alert: a) { pulse.incomingAlert = nil }
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    PulseEmergencyPill()
                        .background(GeometryReader { g in Color.clear.preference(key: SOSHotKey.self, value: g.frame(in: .global)) })
                    PulseSOSToast().allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: center.shown)
        .onPreferenceChange(SOSHotKey.self) { SOSWindow.shared.hot = $0 }
    }
}
