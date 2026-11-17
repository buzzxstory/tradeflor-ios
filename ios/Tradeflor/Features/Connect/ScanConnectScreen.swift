import SwiftUI
import PhotosUI

// Scan & Connect, one screen with two tabs (website ScanTabs.tsx + FlashScanner.tsx + MutualConnect.tsx +
// 73-scan-tabs.css, 5211e17): Scan QR (the camera) | My Code (my one-time code). Both tabs share the header
// (back · TRADEFLOR · ?), the "Scan & Connect" heading and the switch; changing tab replaces the middle and the controls
// in place (no new screen), so Back leaves in one step. Everything fits without scrolling: the camera square and the QR
// shrink to the height that is left, the buttons stay on screen.

enum ScanTab: String, Identifiable {
    case scan, code
    var id: String { rawValue }
}

/// The colours of the Mutual Connect shell (61-mutual-connect.css / 73-scan-tabs.css).
enum ScanLook {
    static let cyan = Theme.hex(0x35E6F2)
    static let light = Theme.hex(0xC4D5DF)
    static let white = Theme.hex(0xF2F8FB)
    static let ink = Theme.hex(0x04222C)
    static let thumb = LinearGradient(colors: [Theme.hex(0xA8FBFF), Theme.hex(0x5EEAF3), Theme.hex(0x22CFE0)], startPoint: .top, endPoint: .bottom)
    static let headline = LinearGradient(colors: [Theme.hex(0x8FF6FB), Theme.hex(0x35E6F2), Theme.hex(0x16C9DA)], startPoint: .leading, endPoint: .trailing)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [Theme.hex(0x082231), Theme.hex(0x061A27), Theme.hex(0x04121D)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.hex(0x127080, 0.34), .clear], center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Theme.hex(0x0A5C6E, 0.32), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    /// The four glowing cyan corners around a square of `side` (the code and the camera share them).
    static func corners(_ side: CGFloat, dim: Bool = false) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { k in
                CornerMark().stroke(cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(Double(k) * 90))
                    .offset(x: (k == 0 || k == 3 ? -1 : 1) * (side / 2 + 12), y: (k < 2 ? -1 : 1) * (side / 2 + 12))
                    .shadow(color: cyan.opacity(0.6), radius: 6)
            }
        }
        .opacity(dim ? 0.75 : 1)
        .allowsHitTesting(false)
    }
}

struct ScanConnectScreen: View {
    let onOpen: (ConversationSummary) -> Void
    /// A TRADEFLOR code was read (camera, photo or link); the caller shows what it points to.
    let onResult: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var hub = FlashHub.shared
    @StateObject private var camera = QRCamera()
    @State private var tab: ScanTab
    @State private var help = false
    @State private var note: String?
    @State private var paste = false
    @State private var pasted = ""
    @State private var picked: PhotosPickerItem?
    @State private var presenterID = "scan-" + UUID().uuidString
    @FocusState private var pasteFocused: Bool

    static let maxPhoto = 15 * 1024 * 1024

    init(initial: ScanTab = .scan, onOpen: @escaping (ConversationSummary) -> Void, onResult: @escaping (String) -> Void) {
        self.onOpen = onOpen
        self.onResult = onResult
        _tab = State(initialValue: initial)
    }

    var body: some View {
        GeometryReader { g in
            let small = g.size.height < 700
            VStack(spacing: 0) {
                header
                heading(small)
                switcher(small)
                if tab == .scan {
                    scanTab(width: g.size.width, height: g.size.height, small: small)
                } else {
                    MyCodePanel(side: codeSide(width: g.size.width, height: g.size.height, small: small), small: small)
                }
            }
            .padding(.horizontal, 20)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .overlay(alignment: .topTrailing) { if help { helpCard.padding(.top, 62).padding(.trailing, 16) } }
        }
        .background(ScanLook.background)
        .preferredColorScheme(.dark)
        .onAppear {
            ScanTiming.mark("tap to scanner screen")
            hub.present(presenterID)
            camera.onCode = { code in
                if FlashTarget.parse(code) != nil {
                    camera.stop()
                    onResult(code)
                } else {
                    note = NSLocalizedString("sc.not.ours", comment: "")
                    camera.resume(after: 1.5)
                }
            }
            if tab == .scan { camera.start() }
            #if DEBUG
            if ProcessInfo.processInfo.environment["TF_CI_SCAN_HELP"] == "1" { help = true }
            #endif
        }
        .onDisappear {
            ScanTiming.done()
            camera.stop()
            hub.unpresent(presenterID)
        }
        .onChange(of: tab) { t in
            note = nil
            paste = false
            if t == .scan { camera.start() } else { camera.stop(); camera.state = .off }
        }
        .onChange(of: scenePhase) { p in
            if p == .background { camera.pause() }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task { await readPhoto(item) }
        }
        // someone scanned my code: the Connection Request over this screen
        .sheet(item: hub.binding(for: presenterID)) { r in
            ConnectionRequestSheet(request: r) { c in
                dismiss()
                onOpen(c)
            }
            .environmentObject(store)
        }
    }

    // MARK: sizes (73-scan-tabs.css: the camera / the code take what is left, within limits)

    private func camSide(width: CGFloat, height: CGFloat, small: Bool) -> CGFloat {
        let fixed: CGFloat = small ? 530 : 560
        return max(150, min(width * 0.78, height - fixed, small ? 300 : 360))
    }

    private func codeSide(width: CGFloat, height: CGFloat, small: Bool) -> CGFloat {
        let fixed: CGFloat = small ? 392 : 420
        return max(130, min(width * 0.68, height - fixed, small ? 280 : 320))
    }

    // MARK: shared top

    private var header: some View {
        HStack {
            round("chevron.left", "fc.back") { close() }
                .accessibilityIdentifier("sc.back")
            Spacer()
            HStack(spacing: 10) {
                Image("BrandFlower").resizable().scaledToFit().frame(width: 34, height: 34)
                Text("TRADEFLOR").font(.system(size: 19, weight: .heavy)).tracking(3).foregroundStyle(Theme.hex(0xEEF6FA))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Tradeflor"))
            Spacer()
            round("questionmark", "sc.help.label", on: help) { withAnimation(.easeOut(duration: 0.15)) { help.toggle() } }
        }
        .padding(.top, 6)
    }

    private func round(_ icon: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(on ? ScanLook.ink : ScanLook.white)
                .frame(width: 48, height: 48)
                .background(on ? AnyShapeStyle(Theme.hex(0x5EEAF3)) : AnyShapeStyle(Theme.hex(0x041019, 0.7)), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func heading(_ small: Bool) -> some View {
        VStack(spacing: small ? 6 : 8) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: small ? 24 : 28)).foregroundStyle(ScanLook.cyan)
                (Text("sc.h.a").foregroundColor(ScanLook.white) + Text("sc.h.b").foregroundColor(ScanLook.cyan))
                    .font(.system(size: small ? 28 : 32, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(LocalizedStringKey(tab == .scan ? "sc.scan.hint" : "sc.code.hint"))
                .font(.system(size: small ? 14 : 15)).foregroundStyle(ScanLook.light)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.top, small ? 6 : 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// [ Scan QR | My Code ], a sliding cyan thumb (0.22 s).
    private func switcher(_ small: Bool) -> some View {
        let h: CGFloat = small ? 40 : 44
        return GeometryReader { g in
            let half = (g.size.width - 8) / 2
            ZStack(alignment: .leading) {
                Capsule().fill(ScanLook.thumb)
                    .overlay(Capsule().stroke(Theme.hex(0xAAFAFF, 0.5), lineWidth: 1))
                    .shadow(color: Theme.hex(0x24D6E8, 0.35), radius: 8, y: 4)
                    .frame(width: half, height: h)
                    .offset(x: tab == .scan ? 0 : half)
                    .animation(.timingCurve(0.3, 0.9, 0.3, 1, duration: 0.22), value: tab)
                HStack(spacing: 0) {
                    tabButton(.scan, "camera", "sc.tab.scan", h)
                    tabButton(.code, "qrcode", "sc.tab.code", h)
                }
            }
            .padding(4)
        }
        .frame(height: h + 8)
        .environment(\.layoutDirection, .leftToRight) // the thumb slides left → right, as on the website
        .frame(maxWidth: 380)
        .background(Theme.hex(0x030E16, 0.7), in: Capsule())
        .overlay(Capsule().stroke(Theme.hex(0x6EE8F4, 0.26), lineWidth: 1))
        .padding(.top, small ? 10 : 18)
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ t: ScanTab, _ icon: String, _ key: String, _ h: CGFloat) -> some View {
        Button { if tab != t { tab = t; help = false } } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(LocalizedStringKey(key)).font(.system(size: 15.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tab == t ? ScanLook.ink : ScanLook.light)
            .frame(maxWidth: .infinity).frame(height: h)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == t ? [.isSelected] : [])
        .accessibilityIdentifier("sc.tab." + t.rawValue)
    }

    // MARK: help

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("sc.help.title").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "sc.help.1")
                step(2, "sc.help.2")
                step(3, "sc.help.3")
            }
            Text("sc.help.note").font(.system(size: 13.5)).foregroundStyle(Theme.hex(0xA9C0CB))
            HStack {
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { help = false } } label: {
                    Text("sc.help.ok").font(.system(size: 14.5, weight: .bold)).foregroundStyle(ScanLook.ink)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.hex(0x5EEAF3), in: Capsule())
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 14.5))
        .foregroundStyle(Theme.hex(0xDCE8EE))
        .padding(18)
        .frame(width: 330)
        .background(Theme.hex(0x051823, 0.98), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.hex(0x6EE8F4, 0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 25, y: 20)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
    }

    private func step(_ n: Int, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").foregroundStyle(Theme.hex(0x7FF3F3)).bold()
            Text(LocalizedStringKey(key))
        }
    }

    // MARK: the Scan QR tab

    private func scanTab(width: CGFloat, height: CGFloat, small: Bool) -> some View {
        let side = camSide(width: width, height: height, small: small)
        return VStack(spacing: 0) {
            if pasteFocused { Spacer(minLength: 12) } else {
            ZStack {
                ZStack {
                    RadialGradient(colors: [Theme.hex(0x0B2A38), Theme.hex(0x03101A)], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: side * 0.8)
                    QRPreview(session: camera.session).opacity(camera.state == .live ? 1 : 0)
                    if camera.state == .live { ScanSweep() } else { camMessage }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.1, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: side * 0.1, style: .continuous).stroke(Theme.hex(0x6EE8F4, 0.35), lineWidth: 1))
                .shadow(color: Theme.hex(0x46E1F0, 0.22), radius: 19)
                ScanLook.corners(side, dim: camera.state != .live)
            }
            .frame(width: side + 44, height: side + 44)
            .frame(maxHeight: .infinity)

            if camera.cams.count > 1 || camera.canFlip || camera.hasTorch { camRow }
            }
            Text(note ?? " ").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.hex(0x7FF3F3))
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                .frame(minHeight: 20).padding(.top, 8)
        
            VStack(spacing: 12) {
                PhotosPicker(selection: $picked, matching: .images) {
                    // outlined like Enter Connect Link (web 80-contacts-v4.css)
                    Label("sc.photo", systemImage: "photo.on.rectangle")
                        .font(.system(size: small ? 17 : 18, weight: .heavy)).foregroundStyle(ScanLook.white)
                        .frame(maxWidth: .infinity).frame(height: small ? 50 : 54)
                        .background(Theme.hex(0x041019, 0.55), in: Capsule())
                        .overlay(Capsule().stroke(Theme.hex(0x6EE8F4, 0.55), lineWidth: 1.5))
                }
                .accessibilityIdentifier("sc.photo")
                HStack(spacing: 14) {
                    Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
                    Text("sc.or").font(.system(size: 14)).foregroundStyle(Theme.hex(0x8FA6B2))
                    Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
                }
                if paste { pasteField(small) } else {
                    Button {
                        paste = true
                        pasteFocused = true
                    } label: {
                        Label("sc.enter.link", systemImage: "link")
                            .font(.system(size: 17, weight: .heavy)).foregroundStyle(ScanLook.white)
                            .frame(maxWidth: .infinity).frame(height: small ? 50 : 54)
                            .background(Theme.hex(0x041019, 0.55), in: Capsule())
                            .overlay(Capsule().stroke(Theme.hex(0x6EE8F4, 0.55), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sc.enter.link")
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var camMessage: some View {
        VStack(spacing: 12) {
            if camera.state == .starting { ProgressView().tint(Theme.hex(0x5EEAF3)) }
            if camera.state != .off {
                Text(LocalizedStringKey("sc.cam." + camera.state.rawValue)).font(.system(size: 14.5)).foregroundStyle(Theme.hex(0xDCE8EE))
                    .multilineTextAlignment(.center).minimumScaleFactor(0.75)
            }
            switch camera.state {
            case .denied:
                retry("sc.cam.settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
            case .paused, .error:
                retry("sc.cam.on") { camera.start() }
            case .busy, .lost:
                retry("mc.tryagain") { camera.start() }
            default:
                EmptyView()
            }
        }
        .padding(18)
    }

    private func retry(_ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(key)).font(.system(size: 14.5, weight: .bold)).foregroundStyle(ScanLook.ink)
                .padding(.horizontal, 18).padding(.vertical, 10).background(Theme.hex(0x5EEAF3), in: Capsule())
        }
    }

    /// The camera's name (opens the list) + the round button to the next camera + the light when there is one.
    private var camRow: some View {
        HStack(spacing: 12) {
            // the camera's name and list only when there is a choice (web ea10bd9)
            if camera.cams.count > 1 {
            Menu {
                ForEach(camera.cams) { c in
                    Button { camera.select(c.id) } label: {
                        if c.id == camera.currentID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera").foregroundStyle(ScanLook.cyan)
                    Group {
                        if let n = camera.currentName { Text(n) } else { Text("sc.cam.none") }
                    }
                    .lineLimit(1).truncationMode(.tail)
                    if camera.cams.count > 1 { Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)) }
                }
                .font(.system(size: 15.5, weight: .bold)).foregroundStyle(ScanLook.white)
                .padding(.horizontal, 18).frame(height: 50)
                .frame(maxWidth: min(260, UIScreen.main.bounds.width * 0.62))
                .background(Theme.hex(0x041019, 0.7), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
            .disabled(camera.cams.count < 2)
            .accessibilityLabel(Text("sc.choose.cam"))
            }
            if camera.canFlip {
                roundSmall("arrow.triangle.2.circlepath.camera", "sc.switch") { camera.flip() }
            }
            if camera.hasTorch {
                roundSmall(camera.torch ? "flashlight.on.fill" : "flashlight.off.fill", camera.torch ? "fc.light.off" : "fc.light.on", on: camera.torch) {
                    camera.toggleTorch()
                }
            }
        }
        .frame(minHeight: 50)
    }

    private func roundSmall(_ icon: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(on ? ScanLook.ink : ScanLook.white)
                .frame(width: 50, height: 50)
                .background(on ? AnyShapeStyle(Theme.hex(0x5EEAF3)) : AnyShapeStyle(Theme.hex(0x041019, 0.7)), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func pasteField(_ small: Bool) -> some View {
        let h: CGFloat = small ? 50 : 54
        return HStack(spacing: 8) {
            TextField("", text: $pasted, prompt: Text("sc.paste.ph").foregroundColor(.white.opacity(0.5)))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                .font(.system(size: 16)).foregroundStyle(.white).focused($pasteFocused)
                .onSubmit { openPasted() }
                .padding(.horizontal, 18).frame(height: h)
                .background(Theme.hex(0x030E16, 0.75), in: Capsule())
                .overlay(Capsule().stroke(pasteFocused ? Theme.hex(0x8FF6FB) : Theme.hex(0x6EE8F4, 0.55), lineWidth: 1.5))
                .accessibilityLabel(Text("sc.paste.label"))
            Button { openPasted() } label: {
                Text("sc.open").font(.system(size: 16, weight: .heavy)).foregroundStyle(ScanLook.ink)
                    .padding(.horizontal, 20).frame(height: h).background(Theme.hex(0x5EEAF3), in: Capsule())
            }
            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(pasted.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
        }
    }

    private func openPasted() {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard FlashTarget.parse(t) != nil else { note = NSLocalizedString("sc.not.ours", comment: ""); return }
        pasteFocused = false
        camera.stop()
        onResult(t)
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        note = NSLocalizedString("sc.reading", comment: "")
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            note = NSLocalizedString("sc.photo.type", comment: "")
            return
        }
        if data.count > Self.maxPhoto { note = NSLocalizedString("sc.photo.big", comment: ""); return }
        guard let code = QRDecode.decode(data) else { note = NSLocalizedString("sc.photo.none", comment: ""); return }
        guard FlashTarget.parse(code) != nil else { note = NSLocalizedString("sc.not.ours", comment: ""); return }
        note = nil
        camera.stop()
        onResult(code)
    }

    private func close() {
        camera.stop()
        dismiss()
    }
}

// MARK: the My Code tab

/// My Connect Code (website MutualConnect.tsx): a 60-second, single-use code. It renews itself 1.5 s before it expires
/// while this tab is open and the app is in front (never in the background); an older answer never replaces a newer code
/// (each request has a number); "Try again" only when renewing failed. Someone scanning it only asks: the Connection
/// Request (FlashHub) comes up and you Accept or Decline.
struct MyCodePanel: View {
    let side: CGFloat
    var small = false
    @EnvironmentObject private var store: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: MutualSession?
    @State private var deadline: Date?
    @State private var now = Date()
    @State private var busy = false
    @State private var error: String?
    @State private var seq = 0
    @State private var copied: String?

    private var token: String { store.session?.token ?? "" }
    private var left: Int { deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? 0 }
    private var expired: Bool { deadline != nil && left == 0 }
    private var link: String? { session?.token.flatMap { expired ? nil : "https://app.tradeflor.com/?mutual=\($0)" } }
    private let cyan = ScanLook.cyan

    var body: some View {
        VStack(spacing: 0) {
            Text("mc.title").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).padding(.top, 14)
            stage.frame(maxHeight: .infinity)
            meta
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.hex(0xFF8A8A)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.8).padding(.top, 6)
            }
            bottom.padding(.top, 12).padding(.bottom, 12)
        }
        .task { await fresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                now = Date()
            }
        }
        // renew by itself 1.5 s before expiry, and at once when the app comes back with a code about to die; never in the background
        .task(id: "\(session?.id ?? "")|\(scenePhase == .active)") {
            guard scenePhase == .active, let d = deadline else { return }
            let wait = d.timeIntervalSinceNow - 1.5
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if Task.isCancelled || scenePhase != .active { return }
            await fresh()
        }
    }

    private var stage: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [cyan.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: side * 0.85))
                .frame(width: side * 1.5, height: side * 1.5)
                .allowsHitTesting(false)
            Group {
                if let link {
                    // the branded code (mark in the middle, correction Q, scan beam); its own tile carries the quiet zone
                    BrandedQR(text: link, side: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.082))
                        .accessibilityLabel(Text("mc.qr"))
                } else if expired {
                    VStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(Theme.hex(0x4A5A64))
                        Text(LocalizedStringKey(busy ? "mc.renewing" : "mc.expired.title")).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.hex(0x0B1F2A))
                        Text(LocalizedStringKey(busy ? "mc.renewing.sub" : "mc.expired.sub2")).font(.system(size: 12)).foregroundStyle(Theme.hex(0x4A5A64)).multilineTextAlignment(.center)
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.hex(0x0B6E7A))
                        Text(LocalizedStringKey(error == nil ? "mc.creating" : "mc.nocode")).font(.system(size: 13)).foregroundStyle(Theme.hex(0x4A5A64))
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                }
            }
            .frame(width: side, height: side)
            .background(BrandedQR.paper, in: RoundedRectangle(cornerRadius: side * 0.082))
            .opacity(expired ? 0.92 : 1)
            ScanLook.corners(side)
        }
        .frame(width: side + 44, height: side + 44)
    }

    /// "Expires in 57s | Single use | Auto refresh"
    private var meta: some View {
        HStack(spacing: 10) {
            Group {
                if session != nil && !expired {
                    (Text("mc.expires.in") + Text(" \(left)s").bold()).foregroundColor(left <= 10 ? Theme.hex(0xFFB35C) : ScanLook.light)
                } else if expired {
                    Text("mc.expired").bold().foregroundColor(Theme.hex(0xFF8A8A))
                } else {
                    Text("mc.expires.dash").foregroundColor(ScanLook.light)
                }
            }
            sep
            Label("mc.single", systemImage: "checkmark.shield").foregroundStyle(ScanLook.light)
            sep
            Label(LocalizedStringKey(busy ? "mc.refreshing" : "mc.auto"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(busy ? cyan : ScanLook.light)
        }
        .font(.system(size: 13.5))
        .lineLimit(1).minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private var sep: some View { Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 16) }

    @ViewBuilder private var bottom: some View {
        VStack(spacing: 6) {
            if error != nil {
                // renewing failed: the one moment a button is needed
                Button { Task { await fresh() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 20, weight: .semibold))
                        Text(LocalizedStringKey(busy ? "mc.trying" : "mc.tryagain")).font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(ScanLook.ink)
                    .frame(maxWidth: .infinity).frame(height: small ? 50 : 54)
                    .background(ScanLook.thumb, in: Capsule())
                    .shadow(color: cyan.opacity(0.35), radius: 14, y: 6)
                }
                .disabled(busy)
            } else {
                HStack(spacing: 10) {
                    if let link, let url = URL(string: link) {
                        ShareLink(item: url, subject: Text("mc.share.title"), message: Text("mc.share.msg")) { shareLabel }
                    } else {
                        shareLabel.opacity(0.5)
                    }
                    Button {
                        guard let link else { return }
                        UIPasteboard.general.string = link
                        copied = NSLocalizedString("mc.copied", comment: "")
                        Task {
                            try? await Task.sleep(nanoseconds: 2_600_000_000)
                            copied = nil
                        }
                    } label: {
                        Label("mc.copy", systemImage: "doc.on.doc").font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(ScanLook.white)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity).frame(height: small ? 50 : 54)
                            .background(Theme.hex(0x041019, 0.55), in: Capsule())
                            .overlay(Capsule().stroke(Theme.hex(0x6EE8F4, 0.55), lineWidth: 1.5))
                    }
                    .disabled(link == nil)
                    .accessibilityIdentifier("mc.copy")
                }
            }
            Text(copied ?? " ").font(.system(size: 12.5)).foregroundStyle(cyan).multilineTextAlignment(.center).lineLimit(2)
        }
    }

    private var shareLabel: some View {
        Label("mc.share", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(ScanLook.ink)
            .frame(maxWidth: .infinity).frame(height: small ? 50 : 54)
            .background(ScanLook.thumb, in: Capsule())
            .shadow(color: cyan.opacity(0.3), radius: 10, y: 4)
    }

    /// A new code; one request at a time, and an older answer is dropped. The countdown runs on the server's clock.
    private func fresh() async {
        guard !busy else { return }
        seq += 1
        let my = seq
        busy = true
        error = nil
        defer { busy = false }
        do {
            let s = try await APIClient.shared.ctStartMutual(token: token)
            guard my == seq else { return }
            guard s.token != nil else { error = NSLocalizedString("mc.err", comment: ""); return }
            let got = Date().timeIntervalSince1970
            let offset = s.server_now.map { Double($0) - got } ?? 0
            session = s
            deadline = Date(timeIntervalSince1970: Double(s.expires_at) - offset)
            now = Date()
        } catch {
            // a code still on screen stays valid until its own expiry
            guard my == seq else { return }
            switch error as? APIError {
            case .rateLimited?: self.error = NSLocalizedString("mc.err.rate", comment: "")
            case .badCredentials?: self.error = NSLocalizedString("sc.err.signin", comment: "")
            case .network?: self.error = NSLocalizedString("sc.err.offline", comment: "")
            case .refused(let why)?: self.error = why.isEmpty || why.count >= 140 ? NSLocalizedString("mc.err.403", comment: "") : why
            default: self.error = NSLocalizedString("mc.err", comment: "")
            }
        }
    }
}


/// Scan & Connect opened from the Chats header (web: openFlash({view: "scan"})): the two-tab screen, and what a scanned
/// code points to (a person to Add & Chat, Mutual Connect's confirm card, a group or an event) pushed on top of it; Back
/// returns to the scanner.
struct ScanFlow: View {
    let onOpen: (ConversationSummary) -> Void
    @State private var target: FlashTarget?
    @State private var initial: ScanTab = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TF_CI_FLASH"] == "mutual" { return .code }
        #endif
        return .scan
    }()

    var body: some View {
        NavigationStack {
            ScanConnectScreen(initial: initial, onOpen: onOpen) { text in target = FlashTarget.parse(text) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                    if let t = target {
                        ScanResultView(target: t, onOpen: onOpen, onDone: { target = nil })
                            .toolbar(.visible, for: .navigationBar)
                    }
                }
        }
    }
}
