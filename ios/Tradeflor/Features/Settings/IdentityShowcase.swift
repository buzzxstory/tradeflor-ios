import Photos
import SwiftUI

// Settings › My Identity, as the website's IdentityShowcase (features/identity/IdentityCard.tsx, 31-identity.css): who, the PIN
// with copy and its Code 39 barcode, the Flash Connect QR (an opaque code, never the PIN), class / early badges; Share Card,
// Download (the card image to Photos) and QR Only.

enum Code39 {
    private static let table: [Character: String] = [
        "0": "101001101101", "1": "110100101011", "2": "101100101011", "3": "110110010101", "4": "101001101011",
        "5": "110100110101", "6": "101100110101", "7": "101001011011", "8": "110100101101", "9": "101100101101",
        "*": "100101101101",
    ]
    /// Modules (1 = bar) for a digits-only value with start/stop characters; "" for anything else.
    static func modules(_ value: String) -> String {
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return "" }
        return (["*"] + Array(value) + ["*"]).compactMap { table[$0] }.joined(separator: "0")
    }
}

struct BarcodeView: View {
    let value: String
    var body: some View {
        Canvas { ctx, size in
            let m = Array(Code39.modules(value))
            guard !m.isEmpty else { return }
            let quiet = 10.0
            let w = size.width / (Double(m.count) + quiet * 2)
            var i = 0
            while i < m.count {
                if m[i] != "1" { i += 1; continue }
                var j = i
                while j < m.count && m[j] == "1" { j += 1 }
                ctx.fill(Path(CGRect(x: (Double(i) + quiet) * w, y: 0, width: Double(j - i) * w, height: size.height)), with: .color(Color(red: 2 / 255, green: 9 / 255, blue: 14 / 255)))
                i = j
            }
        }
        .accessibilityLabel(Text(String(format: NSLocalizedString("id.barcode", comment: ""), value)))
    }
}

enum IdentityTone {
    static let card = Theme.hex(0x061219)
    static let text = Theme.hex(0xF2F8FA)
    static let muted = Theme.hex(0x8AA3AE)
    static let accent = Theme.hex(0x08D9D9)
    static func tone(_ cls: String?) -> Color {
        switch cls {
        case "royal": return Theme.hex(0xD8B56A)
        case "diamond": return Theme.hex(0xBFE6F2)
        case "rare": return Theme.hex(0xB9C3FF)
        case "special": return Theme.hex(0xE3D3B0)
        default: return accent
        }
    }
}

/// The card face (also what "Download" saves as an image).
struct IdentityCardFace: View {
    let id: StIdentity
    let link: String
    var avatar: UIImage?
    /// The scan beam on the QR; off for the saved / shared card image.
    var beam = true

    private var name: String { id.display_name.trimmingCharacters(in: .whitespaces).isEmpty ? id.username : id.display_name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image("BrandFlower").resizable().scaledToFit().frame(width: 20, height: 20)
                    Text("TRADEFLOR").font(.system(size: 13, weight: .heavy)).tracking(1.5).foregroundStyle(IdentityTone.text)
                }
                Spacer()
                Text("id.kind").font(.system(size: 11, weight: .semibold)).foregroundStyle(IdentityTone.muted)
            }
            HStack(spacing: 12) {
                Group {
                    if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                    else {
                        Text(String(name.prefix(1)).uppercased()).font(.system(size: 22, weight: .bold)).foregroundStyle(IdentityTone.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.hex(0x0E3342))
                    }
                }
                .frame(width: 52, height: 52).clipShape(Circle())
                .overlay(Circle().stroke(IdentityTone.accent.opacity(0.35), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 17, weight: .bold)).foregroundStyle(IdentityTone.text).lineLimit(1)
                    Text("@" + id.username).font(.system(size: 13)).foregroundStyle(IdentityTone.muted)
                }
                Spacer()
                if let cc = id.country, cc.count == 2 {
                    Text(Self.flag(cc)).font(.system(size: 22)).accessibilityLabel(Text(Locale.current.localizedString(forRegionCode: cc) ?? cc))
                }
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRADEFLOR PIN").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(IdentityTone.muted)
                    Text(id.pin).font(.system(size: 38, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(IdentityTone.text).lineLimit(1).minimumScaleFactor(0.6)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityLabel(Text("PIN " + id.pin.map(String.init).joined(separator: " ")))
                    BarcodeView(value: id.pin).frame(height: 34).padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: 240).background(Theme.hex(0xF2F8FA), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer(minLength: 0)
                BrandedQR(text: link, side: 116, beam: beam)
                    .accessibilityLabel(Text(String(format: NSLocalizedString("id.qr.for", comment: ""), id.username)))
            }
            badges
            Text("id.hint").font(.system(size: 12.5)).foregroundStyle(IdentityTone.muted).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
        .background(
            ZStack {
                IdentityTone.card
                RadialGradient(colors: [IdentityTone.accent.opacity(0.1), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
            }
        )
        .overlay(alignment: .topLeading) {
            Capsule().fill(IdentityTone.tone(id.pin_class)).frame(width: 96, height: 3).padding(.leading, 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IdentityTone.accent.opacity(0.32), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var badges: some View {
        let cls = id.pin_class ?? ""
        if !cls.isEmpty || id.early_member == true {
            HStack(spacing: 6) {
                if !cls.isEmpty {
                    Label(LocalizedStringKey("id.class." + cls), systemImage: Self.classIcon(cls))
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(IdentityTone.tone(cls))
                        .padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().stroke(IdentityTone.tone(cls).opacity(0.5), lineWidth: 1))
                }
                if id.early_member == true {
                    Label("set.early", systemImage: "star").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.hex(0x9FE9EA))
                        .padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().stroke(Theme.hex(0x9FE9EA, 0.5), lineWidth: 1))
                }
            }
        }
    }

    static func classIcon(_ c: String) -> String {
        switch c {
        case "royal": return "crown"
        case "diamond": return "diamond"
        case "rare": return "sparkles"
        default: return "seal"
        }
    }

    static func flag(_ cc: String) -> String {
        cc.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

struct IdentityShowcase: View {
    let id: StIdentity
    let link: String
    let token: String
    @State private var avatar: UIImage?
    @State private var note: String?
    @State private var qrOnly = false
    @State private var shareItem: CardImage?
    @State private var saving = false
    @State private var flashTask: Task<Void, Never>?

    struct CardImage: Identifiable { let id = UUID(); let image: UIImage }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                IdentityCardFace(id: id, link: link, avatar: avatar)
                Button {
                    UIPasteboard.general.string = id.pin
                    flash("set.copied.pin")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 14, weight: .semibold)).foregroundStyle(IdentityTone.text)
                        .frame(width: 36, height: 36).background(IdentityTone.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(IdentityTone.accent.opacity(0.16), lineWidth: 1))
                }
                .padding(.top, 54).padding(.trailing, 14)
                .accessibilityLabel(Text("set.copy.pin"))
            }
            HStack(spacing: 10) {
                action("square.and.arrow.up", "id.share.card") {
                    if let img = render() { shareItem = CardImage(image: img) }
                }
                action("square.and.arrow.down", "id.download") { Task { await download() } }
                    .disabled(saving)
                action("qrcode", "id.qr.only") { qrOnly = true }
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent) }
        }
        // read again when the photo changes (the card is read again after a pull or a username change)
        .task(id: id.avatar_id ?? "") {
            guard let a = id.avatar_id, !a.isEmpty else { avatar = nil; return }
            if let d = await APIClient.shared.avatar(token: token, userID: id.user_id, avatarID: a) {
                avatar = UIImage(data: d)
            }
        }
        .sheet(item: $shareItem) { item in
            // the image, and the link when it reads as one (a nil boxed in Any was handed to the share sheet before)
            ActivityShare(items: [item.image as Any] + (URL(string: link).map { [$0 as Any] } ?? []))
        }
        .sheet(isPresented: $qrOnly) {
            VStack(spacing: 14) {
                BrandedQR(text: link, side: 272)
                    .accessibilityLabel(Text(String(format: NSLocalizedString("id.qr.for", comment: ""), id.username)))
                Text(id.display_name.isEmpty ? id.username : id.display_name).font(.title3.bold()).foregroundStyle(Theme.text)
                Text("@\(id.username) · PIN \(id.pin)").font(.subheadline).foregroundStyle(Theme.muted)
                Button { qrOnly = false } label: {
                    Text("id.done").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: 220).frame(height: 46).background(Theme.accent, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panelGradient.ignoresSafeArea())
            .presentationDetents([.large])
        }
    }

    private func action(_ icon: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @MainActor private func render() -> UIImage? {
        let r = ImageRenderer(content: IdentityCardFace(id: id, link: link, avatar: avatar, beam: false).frame(width: 380).padding(16).background(Theme.hex(0x02090E)))
        r.scale = 3
        return r.uiImage
    }

    private func download() async {
        // one save at a time: a quick double tap put the card in Photos twice
        guard !saving else { return }
        saving = true
        defer { saving = false }
        guard let img = render() else { flash("media.failed"); return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { flash("media.denied"); return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            flash("id.saved")
        } catch {
            flash("media.failed")
        }
    }

    private func flash(_ key: String) {
        note = NSLocalizedString(key, comment: "")
        // the newest note stays its full time (an earlier one's timer cleared it early)
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { note = nil }
        }
    }
}

/// The system share sheet.
struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
