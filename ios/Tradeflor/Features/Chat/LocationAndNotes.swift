import SwiftUI
import CoreLocation
import MapKit
import AVFoundation
import UIKit

// MARK: live location

/// Shares my live location in a chat for 15 min, 1 h or 8 h (the server's only durations), like the website:
/// a start with the first fix, then updates at most every 10 s and only after moving 15 m (or once a minute anyway).
@MainActor
final class LocationSharer: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationSharer()

    @Published private(set) var sharing: Set<String> = []
    @Published var denied = false

    private let manager = CLLocationManager()
    private var token = ""
    private var pendingStart: (conversation: String, minutes: Int)?
    private var lastSent: (at: Date, location: CLLocation)?
    private var until: [String: Date] = [:]

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    func start(token: String, conversationID: String, minutes: Int) {
        self.token = token
        pendingStart = (conversationID, minutes)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true; pendingStart = nil
        default: manager.startUpdatingLocation()
        }
    }

    func stop(conversationID: String) {
        sharing.remove(conversationID)
        until[conversationID] = nil
        Task { await APIClient.shared.stopLocation(token: token, conversationID: conversationID) }
        if sharing.isEmpty && pendingStart == nil { manager.stopUpdatingLocation() }
    }

    /// The session is gone (a 401): sharing stops on this phone without asking the server, which cannot be told any more (it
    /// ends the shares of a session that no longer exists).
    func stopLocally() {
        pendingStart = nil
        sharing = []
        until = [:]
        lastSent = nil
        manager.stopUpdatingLocation()
    }

    /// Sign-out: the shares this phone runs end on the server (shares started on another device are that device's), and
    /// the phone stops reading its location.
    func stopAll(token: String) async {
        let convs = sharing
        pendingStart = nil
        sharing = []
        until = [:]
        lastSent = nil
        manager.stopUpdatingLocation()
        for c in convs { await APIClient.shared.stopLocation(token: token, conversationID: c) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.pendingStart != nil || !self.sharing.isEmpty { manager.startUpdatingLocation() }
            case .denied, .restricted:
                if self.pendingStart != nil { self.denied = true; self.pendingStart = nil }
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in await self.handle(loc) }
    }

    /// Location turned off for the app (or by Screen Time) while a share was asked: say so (Settings), instead of
    /// waiting for a fix that never comes. Other errors pass; Core Location keeps trying by itself.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor in
            if self.pendingStart != nil { self.denied = true; self.pendingStart = nil }
            if self.sharing.isEmpty { manager.stopUpdatingLocation() }
        }
    }

    private func handle(_ loc: CLLocation) async {
        if let p = pendingStart {
            pendingStart = nil
            do {
                try await APIClient.shared.startLocation(token: token, conversationID: p.conversation, minutes: p.minutes,
                                                         lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                                         accuracy: max(0, loc.horizontalAccuracy))
                sharing.insert(p.conversation)
                until[p.conversation] = Date().addingTimeInterval(Double(p.minutes) * 60)
                lastSent = (Date(), loc)
            } catch {
                if sharing.isEmpty { manager.stopUpdatingLocation() }
            }
            return
        }
        guard !sharing.isEmpty else { manager.stopUpdatingLocation(); return }
        let now = Date()
        if let last = lastSent {
            let elapsed = now.timeIntervalSince(last.at)
            let moved = loc.distance(from: last.location)
            guard elapsed >= 10, moved >= 15 || elapsed >= 60 else { return }
        }
        lastSent = (now, loc)
        for c in sharing {
            if let u = until[c], u < now { stop(conversationID: c); continue }
            let ok = await APIClient.shared.updateLocation(token: token, conversationID: c, lat: loc.coordinate.latitude,
                                                           lon: loc.coordinate.longitude, accuracy: max(0, loc.horizontalAccuracy))
            if !ok { sharing.remove(c); until[c] = nil }
        }
        if sharing.isEmpty { manager.stopUpdatingLocation() }
    }
}

/// A live-location share is ONE message (the card). A plain text "Live location" from the same sender within seconds of a card is
/// its stand-in (a copy made by another client or an older build): it is not drawn next to the card.
enum LocationCardTwin {
    private static let labels: Set<String> = ["live location", "📍 live location"]

    static func removing(from rows: [Message]) -> [Message] {
        guard rows.contains(where: { $0.kind == "location" }) else { return rows }
        let cards = rows.filter { $0.kind == "location" }
        return rows.filter { m in
            guard m.kind == "text", !m.isDeleted,
                  labels.contains(m.body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return true }
            return !cards.contains { $0.sender_id == m.sender_id && abs($0.created_at - m.created_at) <= (m.created_at > 100_000_000_000 ? 10_000 : 10) }
        }
    }
}

/// A live location message: a map while the share runs, "ended" after.
struct LocationCard: View {
    let token: String
    let message: Message
    let mine: Bool
    @State private var position: LivePosition?
    /// The first answer about where the share is has arrived. Until then a share that may still run keeps the map's size
    /// (it showed "ended" first and jumped to the 150 pt map: the list under it misjudged its height and left a gap).
    @State private var loaded = false
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))

    /// The end of each share (unix seconds; 0 = the text names none), read once per card text: it was a JSON read
    /// several times per card on every chat redraw. Used from the views (main thread) only.
    private static var untilMemo: [String: Double] = [:]

    private var until: Date? {
        guard let s = message.signal else { return nil }
        let u: Double
        if let hit = Self.untilMemo[s] {
            u = hit
        } else {
            var read = 0.0
            if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let v = o["until"] as? Double { read = v }
            if Self.untilMemo.count > 300 { Self.untilMemo.removeAll(keepingCapacity: true) }
            Self.untilMemo[s] = read
            u = read
        }
        // a share with no end named, or one named as 0, was never running: the same answer as before for both
        return u > 0 ? Date(timeIntervalSince1970: u) : nil
    }
    private var running: Bool { (until ?? .distantPast) > Date() && position != nil }
    private var maybeRunning: Bool { (until ?? .distantPast) > Date() && !loaded }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if running, let p = position {
                    Map(coordinateRegion: .constant(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))),
                        annotationItems: [p]) { item in
                        MapMarker(coordinate: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon), tint: .red)
                    }
                    .frame(width: 240, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
                    Button {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)))
                        item.openInMaps()
                    } label: { Label("location.open", systemImage: "map") }
                    .font(.footnote.weight(.semibold))
                    if let until { Text(String(format: NSLocalizedString("location.until", comment: ""), Self.time.string(from: until))).font(.caption2) }
                } else if maybeRunning {
                    // same size as the map card, so the row does not change height when the position arrives
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Theme.surface)
                        ProgressView()
                    }
                    .frame(width: 240, height: 150)
                    Label("location.open", systemImage: "map").font(.footnote.weight(.semibold)).opacity(0.35)
                    if let until { Text(String(format: NSLocalizedString("location.until", comment: ""), Self.time.string(from: until))).font(.caption2) }
                } else {
                    Label("location.ended", systemImage: "location.slash").font(.subheadline)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(10)
            .tfBubble(mine: mine)
            if !mine { Spacer(minLength: 48) }
        }
        .task(id: message.id) {
            while !Task.isCancelled {
                let all = await APIClient.shared.livePositions(token: token, conversationID: message.conversation_id)
                position = all.first { $0.message_id == message.id && $0.user_id == message.sender_id }
                loaded = true
                if (until ?? .distantPast) < Date() { break }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

// MARK: video notes (round videos)

/// Records a short front-camera video (up to 90 s) with the system camera.
struct VideoNoteRecorder: UIViewControllerRepresentable {
    let onVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.mediaTypes = ["public.movie"]
        c.cameraCaptureMode = .video
        if UIImagePickerController.isCameraDeviceAvailable(.front) { c.cameraDevice = .front }
        c.videoMaximumDuration = 90
        c.videoQuality = .typeMedium
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoNoteRecorder
        init(_ p: VideoNoteRecorder) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { parent.onVideo(url) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

enum VideoNotePrep {
    /// A 480x480 centre crop, H.264 MP4, as the website records them. Returns the bytes and the length in ms.
    static func square(from source: URL) async -> (data: Data, ms: Int)? {
        let asset = AVURLAsset(url: source)
        defer { try? FileManager.default.removeItem(at: source) }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(rect.width), h = abs(rect.height)
        let side = min(w, h)
        guard side > 0 else { return nil } // a track with no picture size: nothing to crop (and no division by zero)
        let out: CGFloat = 480
        let scale = out / side

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: out, height: out)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        var t = transform
        t = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        t = t.concatenating(CGAffineTransform(translationX: -(w - side) / 2, y: -(h - side) / 2))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else { return nil }
        export.outputURL = dest
        export.outputFileType = .mp4
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed, let data = try? Data(contentsOf: dest) else { return nil }
        return (data, Int(duration.seconds * 1000))
    }

    static func fileName(ms: Int) -> String { "videonote_\(Int(Date().timeIntervalSince1970 * 1000))_\(ms).mp4" }

    static func isNote(_ m: Message) -> Bool {
        m.kind == "file" && (m.file_name ?? "").hasPrefix("videonote_")
    }

    static func lengthMs(_ m: Message) -> Int {
        let parts = (m.file_name ?? "").split(separator: "_")
        guard parts.count >= 3, let ms = Int(parts[2].split(separator: ".").first ?? "") else { return 0 }
        return ms
    }
}

/// A round video message: the first frame in a circle with its length; tap to play.
struct VideoNoteBubble: View {
    let token: String
    let message: Message
    let mine: Bool
    let onPlay: () -> Void
    @State private var poster: UIImage?

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let poster { Image(uiImage: poster).resizable().scaledToFill() } else { Theme.surface }
                    Image(systemName: "play.fill").font(.title2.bold()).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(.black.opacity(0.4), in: Circle())
                }
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                Text(VoiceBubble.length(Int64(VideoNotePrep.lengthMs(message))))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule())
            }
            .onTapGesture(perform: onPlay)
            if !mine { Spacer(minLength: 48) }
        }
        .task(id: message.file_id) {
            guard let fid = message.file_id else { return }
            poster = await RemoteMedia.poster(token: token, fileID: fid)
        }
    }
}
