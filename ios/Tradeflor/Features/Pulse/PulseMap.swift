import SwiftUI
import UIKit
import MapLibre

/// One person on the Pulse map, as the screen prepared them.
struct PulseMapPerson: Equatable {
    enum Ring: Equatable { case live, lagging, stale, arrived }
    let id: String
    var name: String
    var avatarID: String?
    var coordinate: CLLocationCoordinate2D
    var accuracy: Double
    var approximate: Bool
    var ring: Ring
    var line: String // "~8 min · 1.2 km", "Arrived", "Last updated 3 min ago"
    var status: String?
    var statusAt: Int64?
    var isMe: Bool
    var moving: Bool
    var measuredAt: Int64
    var glide: Double // seconds to glide from the previous real position (0 = jump)

    static func == (a: PulseMapPerson, b: PulseMapPerson) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.accuracy == b.accuracy && a.ring == b.ring && a.line == b.line && a.status == b.status && a.name == b.name
            && a.avatarID == b.avatarID && a.moving == b.moving
    }
}

struct PulseMapDest: Equatable {
    var coordinate: CLLocationCoordinate2D
    var name: String
    var icon: String
    static func == (a: PulseMapDest, b: PulseMapDest) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.name == b.name && a.icon == b.icon
    }
}

/// What the camera should do now (a new `nonce` = do it again).
struct PulseCamera: Equatable {
    enum Mode: Equatable { case everyone, place, me, follow(String), none }
    var mode: Mode = .everyone
    var nonce = 0
}

/// The Pulse map (MapLibre Native): flat, north-up, the "Pulse Night" style (or the server's style), avatars with their
/// rings, the accuracy circles, a dashed direction line to the place, "+N" groups, at most six floating statuses.
struct PulseMapView: UIViewRepresentable {
    let token: String
    var styleURL: String?
    var people: [PulseMapPerson]
    var dest: PulseMapDest?
    var camera: PulseCamera
    var selected: String?
    var compact = false
    var onTapMap: ((CLLocationCoordinate2D) -> Void)?
    /// A café, restaurant, bar... tapped on the map (its name and where it is): offered as the meeting place.
    var onTapPlace: ((String, CLLocationCoordinate2D, String?) -> Void)?
    var onSelect: ((String) -> Void)?
    var onUserMoved: (() -> Void)?
    var onTilesFailed: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.style(styleURL))
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.compassView.isHidden = true
        map.logoView.isHidden = false
        map.attributionButton.tintColor = UIColor(white: 1, alpha: 0.5)
        map.backgroundColor = UIColor(red: 0.02, green: 0.07, blue: 0.1, alpha: 1)
        map.setCenter(dest?.coordinate ?? people.first?.coordinate ?? CLLocationCoordinate2D(latitude: 33.8938, longitude: 35.5018),
                      zoomLevel: compact ? 13 : 12, animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for g in map.gestureRecognizers ?? [] where g is UITapGestureRecognizer { tap.require(toFail: g) }
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.sync()
    }

    /// The bundled Pulse Night style (docs/pulse/pulse-night-style.json), or the server's when it gives one.
    static func style(_ url: String?) -> URL? {
        if let s = url, !s.isEmpty, let u = URL(string: s) { return u }
        return Bundle.main.url(forResource: "pulse-night-style", withExtension: "json")
    }

    static var offlineStyle: URL? { Bundle.main.url(forResource: "pulse-offline-style", withExtension: "json") }

    static let poiLayer = "pulse-poi"

    /// The badge group of an OpenMapTiles poi class (desktop pulsePoi.ts poiGroup), or nil.
    static func poiGroupKey(_ cls: String?) -> String? {
        switch cls ?? "" {
        case "cafe": return "cafe"
        case "restaurant": return "food"
        case "fast_food": return "fast"
        case "bar", "beer": return "bar"
        case "ice_cream", "bakery": return "sweet"
        default: return nil
        }
    }

    static func color(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// The place groups (desktop pulsePoi.ts POI_GROUPS): emoji and ring colour.
    static let poiGroups: [(key: String, emoji: String, ring: UInt32)] = [
        ("cafe", "☕", 0xF2B155), ("food", "🍽️", 0xFF7F66), ("fast", "🍔", 0xFFA64D), ("bar", "🍹", 0xB48CFF), ("sweet", "🍦", 0xFF8FC8),
    ]

    /// One badge per group, as the web paints it: a 96 px canvas at pixel ratio 2, a soft radial glow of the ring colour,
    /// a dark disc (#071a24, radius 34), a 5 px ring and the emoji at 40 px.
    static let poiBadges: [String: UIImage] = {
        var out: [String: UIImage] = [:]
        let f = UIGraphicsImageRendererFormat()
        f.scale = 2
        f.opaque = false
        let size = CGSize(width: 48, height: 48) // 96 px
        for g in poiGroups {
            let ring = UIColor(red: CGFloat((g.ring >> 16) & 0xFF) / 255, green: CGFloat((g.ring >> 8) & 0xFF) / 255, blue: CGFloat(g.ring & 0xFF) / 255, alpha: 1)
            out["pulse-poi-" + g.key] = UIGraphicsImageRenderer(size: size, format: f).image { rc in
                let ctx = rc.cgContext
                let mid = CGPoint(x: 24, y: 24)
                let colors = [ring.withAlphaComponent(0x55 / 255.0).cgColor, ring.withAlphaComponent(0).cgColor] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.drawRadialGradient(grad, startCenter: mid, startRadius: 13, endCenter: mid, endRadius: 24, options: [])
                }
                let disc = CGRect(x: 24 - 17, y: 24 - 17, width: 34, height: 34)
                ctx.setFillColor(UIColor(red: 0x07 / 255.0, green: 0x1A / 255.0, blue: 0x24 / 255.0, alpha: 1).cgColor)
                ctx.fillEllipse(in: disc)
                ctx.setStrokeColor(ring.cgColor)
                ctx.setLineWidth(2.5)
                ctx.strokeEllipse(in: disc)
                let s = NSAttributedString(string: g.emoji, attributes: [.font: UIFont.systemFont(ofSize: 20)])
                let b = s.size()
                s.draw(at: CGPoint(x: 24 - b.width / 2, y: 24 - b.height / 2))
            }
        }
        return out
    }()

    final class PersonAnnotation: MLNPointAnnotation { var personID = "" }
    final class DestAnnotation: MLNPointAnnotation {}

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: PulseMapView
        weak var map: MLNMapView?
        private var annotations: [String: PersonAnnotation] = [:]
        private var shown: [String: PulseMapPerson] = [:]
        private var destAnnotation: DestAnnotation?
        private var styleReady = false
        private var cameraNonce = -1
        private var usedOffline = false
        private var fitted = false

        init(_ p: PulseMapView) { parent = p }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map else { return }
            let pt = g.location(in: map)
            // a place badge under the finger (a 22 pt box: the badges are small)
            if let onPlace = parent.onTapPlace {
                let box = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
                if let f = map.visibleFeatures(in: box, styleLayerIdentifiers: [PulseMapView.poiLayer]).first {
                    let a = f.attributes
                    let name = (a["name:latin"] as? String) ?? (a["name_en"] as? String) ?? (a["name"] as? String) ?? ""
                    if !name.isEmpty {
                        let c = (f as? MLNPointFeature)?.coordinate ?? map.convert(pt, toCoordinateFrom: map)
                        onPlace(name, c, a["class"] as? String)
                        return
                    }
                }
            }
            parent.onTapMap?(map.convert(pt, toCoordinateFrom: map))
        }

        func sync() {
            guard let map else { return }
            // people
            let ids = Set(parent.people.map(\.id))
            for (id, a) in annotations where !ids.contains(id) {
                map.removeAnnotation(a)
                annotations[id] = nil
                shown[id] = nil
            }
            for p in parent.people {
                if let a = annotations[p.id] {
                    let old = shown[p.id]
                    if old?.coordinate.latitude != p.coordinate.latitude || old?.coordinate.longitude != p.coordinate.longitude {
                        if p.glide > 0 {
                            UIView.animate(withDuration: p.glide, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { a.coordinate = p.coordinate }
                        } else {
                            a.coordinate = p.coordinate
                        }
                    }
                    shown[p.id] = p
                    (map.view(for: a) as? PersonPinView)?.show(p, token: parent.token, selected: parent.selected == p.id)
                } else {
                    let a = PersonAnnotation()
                    a.personID = p.id
                    a.coordinate = p.coordinate
                    annotations[p.id] = a
                    shown[p.id] = p
                    map.addAnnotation(a)
                }
            }
            // the place
            if let d = parent.dest {
                if let a = destAnnotation {
                    a.coordinate = d.coordinate
                    (map.view(for: a) as? DestPinView)?.show(d)
                } else {
                    let a = DestAnnotation()
                    a.coordinate = d.coordinate
                    destAnnotation = a
                    map.addAnnotation(a)
                }
            } else if let a = destAnnotation {
                map.removeAnnotation(a)
                destAnnotation = nil
            }
            updateShapes()
            regroup()
            applyCamera()
        }

        // MARK: camera

        private func applyCamera() {
            guard let map else { return }
            let cam = parent.camera
            if case .follow(let id) = cam.mode, let p = parent.people.first(where: { $0.id == id }) {
                if cam.nonce != cameraNonce { cameraNonce = cam.nonce; map.setCenter(p.coordinate, zoomLevel: max(map.zoomLevel, 15), animated: true) } else { map.setCenter(p.coordinate, animated: true) }
                return
            }
            guard cam.nonce != cameraNonce || (!fitted && !parent.people.isEmpty) else { return }
            cameraNonce = cam.nonce
            fitted = true
            switch cam.mode {
            case .place:
                if let d = parent.dest { map.setCenter(d.coordinate, zoomLevel: 16, animated: true) }
            case .me:
                if let me = parent.people.first(where: \.isMe) { map.setCenter(me.coordinate, zoomLevel: 16, animated: true) }
            case .everyone:
                var coords = parent.people.map(\.coordinate) + (parent.dest.map { [$0.coordinate] } ?? [])
                if coords.count == 1 {
                    map.setCenter(coords[0], zoomLevel: 15, animated: true)
                } else if coords.count > 1 {
                    map.setVisibleCoordinates(&coords, count: UInt(coords.count), edgePadding: UIEdgeInsets(top: 90, left: 50, bottom: 140, right: 50), animated: true)
                }
            default: break
            }
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            // a hand on the map stops following
            if reason.contains(.gesturePan) || reason.contains(.gesturePinch) || reason.contains(.gestureZoomIn) || reason.contains(.gestureZoomOut) {
                parent.onUserMoved?()
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { regroup() }

        // MARK: style, shapes

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleReady = true
            // the place badges are painted here (they are in no sprite): pulse-poi-cafe|food|fast|bar|sweet
            for (name, img) in PulseMapView.poiBadges { style.setImage(img, forName: name) }
            let acc = MLNShapeSource(identifier: "pulse-accuracy", shape: nil, options: nil)
            let lines = MLNShapeSource(identifier: "pulse-lines", shape: nil, options: nil)
            style.addSource(acc)
            style.addSource(lines)
            let fill = MLNFillStyleLayer(identifier: "pulse-accuracy-fill", source: acc)
            fill.fillColor = NSExpression(forConstantValue: UIColor(red: 0, green: 0.83, blue: 0.87, alpha: 1))
            fill.fillOpacity = NSExpression(forConstantValue: 0.14)
            let edge = MLNLineStyleLayer(identifier: "pulse-accuracy-edge", source: acc)
            edge.lineColor = NSExpression(forConstantValue: UIColor(red: 0, green: 0.83, blue: 0.87, alpha: 0.55))
            edge.lineWidth = NSExpression(forConstantValue: 1)
            let line = MLNLineStyleLayer(identifier: "pulse-direction", source: lines)
            line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 0.8))
            line.lineWidth = NSExpression(forConstantValue: 2.5)
            line.lineDashPattern = NSExpression(forConstantValue: [1.5, 2])
            line.lineCap = NSExpression(forConstantValue: "round")
            style.addLayer(fill)
            style.addLayer(edge)
            style.addLayer(line)
            updateShapes()
            parent.onTilesFailed?(usedOffline)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            // tiles cannot load: a plain dark background, the people still shown, and a banner
            guard !usedOffline, let off = PulseMapView.offlineStyle else { return }
            usedOffline = true
            styleReady = false
            mapView.styleURL = off
            parent.onTilesFailed?(true)
        }

        private func updateShapes() {
            guard styleReady, let style = map?.style else { return }
            var circles: [MLNPolygonFeature] = []
            var lines: [MLNPolylineFeature] = []
            for p in parent.people {
                if p.accuracy >= 25 {
                    var ring = PulseRules.circlePolygon(lat: p.coordinate.latitude, lon: p.coordinate.longitude, radiusM: p.accuracy)
                    circles.append(MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count)))
                }
                if p.moving, p.ring != .arrived, p.ring != .stale, let d = parent.dest {
                    var pts = [p.coordinate, d.coordinate]
                    lines.append(MLNPolylineFeature(coordinates: &pts, count: 2))
                }
            }
            (style.source(withIdentifier: "pulse-accuracy") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: circles)
            (style.source(withIdentifier: "pulse-lines") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: lines)
        }

        // MARK: annotations

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let a = annotation as? PersonAnnotation {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "person") as? PersonPinView) ?? PersonPinView(reuseIdentifier: "person")
                if let p = shown[a.personID] { v.show(p, token: parent.token, selected: parent.selected == p.id) }
                return v
            }
            if annotation is DestAnnotation {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "dest") as? DestPinView) ?? DestPinView(reuseIdentifier: "dest")
                if let d = parent.dest { v.show(d) }
                return v
            }
            return nil
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            guard let a = annotation as? PersonAnnotation else { return }
            if let v = mapView.view(for: a) as? PersonPinView, v.groupCount > 1 {
                mapView.setCenter(a.coordinate, zoomLevel: min(19, mapView.zoomLevel + 2), animated: true) // a "+N" group: zoom in
                return
            }
            parent.onSelect?(a.personID)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        /// Overlapping avatars become "+N"; at most six statuses float at once.
        private func regroup() {
            guard let map else { return }
            var pts: [PulseRules.ScreenPoint] = []
            for (id, a) in annotations {
                let pt = map.convert(a.coordinate, toPointTo: map)
                let p = shown[id]
                pts.append(PulseRules.ScreenPoint(id: id, x: pt.x, y: pt.y, priority: p?.isMe == true ? 2 : (parent.selected == id ? 3 : 1)))
            }
            let clusters = PulseRules.clusterPoints(pts)
            var statusAt: [String: Int64] = [:]
            for p in parent.people where p.status != nil { statusAt[p.id] = p.statusAt ?? 0 }
            let statuses = PulseRules.visibleStatuses(clusters, statusAt: statusAt, selected: parent.selected)
            for c in clusters {
                for (i, id) in c.ids.enumerated() {
                    guard let a = annotations[id], let v = map.view(for: a) as? PersonPinView else { continue }
                    v.setGroup(i == 0 ? c.ids.count : 0, showStatus: statuses.contains(id))
                }
            }
        }
    }
}

/// An avatar on the map: the photo in a ring (live turquoise, delayed dimmed, stale grey, arrived green), the name and a line
/// under it, a floating status above it, "+N" when it stands for a group.
final class PersonPinView: MLNAnnotationView {
    private let photo = UIImageView()
    private let ring = CAShapeLayer()
    private let initials = UILabel()
    private let name = UILabel()
    private let line = UILabel()
    private let status = UILabel()
    private let badge = UILabel()
    private var avatarKey = ""
    private(set) var groupCount = 1
    private var loadTask: Task<Void, Never>?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 120, height: 104)
        centerOffset = CGVector(dx: 0, dy: -6)
        photo.frame = CGRect(x: 38, y: 26, width: 44, height: 44)
        photo.layer.cornerRadius = 22
        photo.clipsToBounds = true
        photo.contentMode = .scaleAspectFill
        photo.backgroundColor = UIColor(red: 0.05, green: 0.2, blue: 0.26, alpha: 1)
        initials.frame = photo.frame
        initials.textAlignment = .center
        initials.font = .systemFont(ofSize: 18, weight: .bold)
        initials.textColor = UIColor(red: 0.03, green: 0.85, blue: 0.85, alpha: 1)
        ring.path = UIBezierPath(ovalIn: photo.frame.insetBy(dx: -3, dy: -3)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 3
        for l in [name, line] {
            l.textAlignment = .center
            l.textColor = .white
            l.shadowColor = UIColor(white: 0, alpha: 0.8)
            l.shadowOffset = CGSize(width: 0, height: 1)
        }
        name.frame = CGRect(x: 0, y: 73, width: 120, height: 15)
        name.font = .systemFont(ofSize: 12, weight: .bold)
        line.frame = CGRect(x: 0, y: 88, width: 120, height: 14)
        line.font = .systemFont(ofSize: 10.5, weight: .medium)
        status.frame = CGRect(x: 4, y: 0, width: 112, height: 22)
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.textColor = .white
        status.textAlignment = .center
        status.backgroundColor = UIColor(red: 0.02, green: 0.16, blue: 0.2, alpha: 0.92)
        status.layer.cornerRadius = 11
        status.clipsToBounds = true
        badge.frame = CGRect(x: 72, y: 22, width: 28, height: 20)
        badge.font = .systemFont(ofSize: 11, weight: .heavy)
        badge.textAlignment = .center
        badge.textColor = UIColor(red: 0.02, green: 0.17, blue: 0.23, alpha: 1)
        badge.backgroundColor = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 1)
        badge.layer.cornerRadius = 10
        badge.clipsToBounds = true
        badge.isHidden = true
        layer.addSublayer(ring)
        [photo, initials, name, line, status, badge].forEach(addSubview)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ p: PulseMapPerson, token: String, selected: Bool) {
        let colour: UIColor
        switch p.ring {
        case .live: colour = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 1)
        case .lagging: colour = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 0.45)
        case .stale: colour = UIColor(white: 0.6, alpha: 1)
        case .arrived: colour = UIColor(red: 0.08, green: 0.76, blue: 0.48, alpha: 1)
        }
        ring.strokeColor = colour.cgColor
        ring.lineWidth = selected ? 4.5 : 3
        photo.alpha = p.ring == .stale ? 0.55 : 1
        photo.layer.filters = nil
        name.text = p.isMe ? NSLocalizedString("chat.you", comment: "") : p.name
        line.text = p.line
        status.text = p.status.map { " \($0) " }
        status.isHidden = p.status == nil
        initials.text = String(p.name.prefix(1)).uppercased()
        accessibilityLabel = [name.text ?? "", p.line, p.status ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        let key = p.id + "|" + (p.avatarID ?? "")
        if key != avatarKey {
            avatarKey = key
            photo.image = nil
            initials.isHidden = false
            loadTask?.cancel()
            if let aid = p.avatarID, !aid.isEmpty {
                let uid = p.id
                loadTask = Task { [weak self] in
                    guard let d = await APIClient.shared.avatar(token: token, userID: uid, avatarID: aid), let img = UIImage(data: d) else { return }
                    guard !Task.isCancelled, self?.avatarKey == key else { return }
                    self?.photo.image = img
                    self?.initials.isHidden = true
                }
            }
        }
    }

    /// n > 1: this avatar stands for a group of n; 0: hidden under another one's group.
    func setGroup(_ n: Int, showStatus: Bool) {
        groupCount = n
        isHidden = n == 0
        badge.isHidden = n <= 1
        badge.text = "+\(max(0, n - 1))"
        status.alpha = showStatus && n == 1 ? 1 : 0
    }
}

/// The meeting place: a glowing gold marker with the activity icon and the place name.
final class DestPinView: MLNAnnotationView {
    private let dot = UILabel()
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 140, height: 74)
        dot.frame = CGRect(x: 48, y: 0, width: 44, height: 44)
        dot.textAlignment = .center
        dot.font = .systemFont(ofSize: 22)
        dot.backgroundColor = UIColor(red: 0.94, green: 0.75, blue: 0.2, alpha: 1)
        dot.layer.cornerRadius = 22
        dot.clipsToBounds = true
        layer.shadowColor = UIColor(red: 0.94, green: 0.75, blue: 0.2, alpha: 1).cgColor
        layer.shadowRadius = 12
        layer.shadowOpacity = 0.8
        layer.shadowOffset = .zero
        label.frame = CGRect(x: 0, y: 48, width: 140, height: 22)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = UIColor(red: 1, green: 0.86, blue: 0.4, alpha: 1)
        label.shadowColor = UIColor(white: 0, alpha: 0.8)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dot)
        addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ d: PulseMapDest) {
        dot.text = d.icon
        label.text = d.name
        accessibilityLabel = String(format: NSLocalizedString("pulse.place.ax", comment: ""), d.name)
    }
}
