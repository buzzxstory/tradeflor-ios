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
    /// metres to the meeting place (the server's distance_m), nil without a place
    var toPlaceM: Double?
    var measuredAt: Int64
    var glide: Double // seconds to glide from the previous real position (0 = jump)
    /// this person's SOS is active: the ring turns red and blinks, two red waves go out
    var sos = false

    static func == (a: PulseMapPerson, b: PulseMapPerson) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.accuracy == b.accuracy && a.ring == b.ring && a.line == b.line && a.status == b.status && a.name == b.name
            && a.avatarID == b.avatarID && a.toPlaceM == b.toPlaceM && a.sos == b.sos && a.measuredAt == b.measuredAt
    }

    /// The dashed line to the place (web PulseMap refreshGeo): everyone not arrived and more than 60 m away; a stale position's
    /// line is drawn faint, never hidden (it came and went before).
    var drawsLine: Bool { ring != .arrived && (toPlaceM ?? 0) > 60 }
}

/// A place someone proposed (web: "📍 name · proposed"), or the spot being picked.
struct PulseMapPin: Equatable {
    let id: String
    var coordinate: CLLocationCoordinate2D
    var name: String
    static func == (a: PulseMapPin, b: PulseMapPin) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.name == b.name
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

/// What the camera should do now (a new `nonce` = do it again). As on the web, a mode keeps being applied while positions
/// change (everyone stays framed, me / a friend stays centred) until a hand moves or zooms the map (`none` = free).
/// `center` shows one spot at zoom 15 (Create's "Near me": the map moves, the pin does not).
struct PulseCamera: Equatable {
    enum Mode: Equatable { case everyone, place, me, follow(String), center(Double, Double), none }
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
    /// SOS senders with no live position here but a position in their SOS: a red beacon
    var beacons: [PulseSOSBeacon] = []
    /// open proposals (drawn as "📍 name · proposed") and the spot being picked for a new one
    var proposals: [PulseMapPin] = []
    var pick: PulseMapPin?

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

    /// What the map shows; the meetup redraws every second, the map only when this changed (audit 19).
    struct SyncKey: Equatable {
        var style: String?
        var people: [PulseMapPerson]
        var dest: PulseMapDest?
        var camera: PulseCamera
        var selected: String?
        var beacons: [PulseSOSBeacon]
        var proposals: [PulseMapPin]
        var pick: PulseMapPin?
        var size: CGSize
        var bucket: Int
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let key = SyncKey(style: styleURL, people: people, dest: dest, camera: camera, selected: selected, beacons: beacons,
                          proposals: proposals, pick: pick, size: map.bounds.size, bucket: Int(Date().timeIntervalSince1970 / 10))
        guard key != c.lastSync else { return }
        c.lastSync = key
        c.sync()
    }

    /// The bundled Pulse Night style (docs/pulse/pulse-night-style.json), or the server's when it gives one.
    static func style(_ url: String?) -> URL? {
        if let s = url, !s.isEmpty, let u = URL(string: s) { return u }
        return Bundle.main.url(forResource: "pulse-night-style", withExtension: "json")
    }

    static var offlineStyle: URL? { Bundle.main.url(forResource: "pulse-offline-style", withExtension: "json") }

    static let poiLayer = "pulse-poi"
    /// The id of the spot being picked among `PulseMapPin`s.
    static let pickID = "__pick"

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
    final class BeaconAnnotation: MLNPointAnnotation { var beaconID = ""; var name = "" }
    final class DestAnnotation: MLNPointAnnotation {}
    final class PinAnnotation: MLNPointAnnotation { var pinID = ""; var name = ""; var isPick = false }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: PulseMapView
        var lastSync: SyncKey?
        weak var map: MLNMapView?
        private var annotations: [String: PersonAnnotation] = [:]
        private var shown: [String: PulseMapPerson] = [:]
        private var destAnnotation: DestAnnotation?
        private var beaconAnnotations: [String: BeaconAnnotation] = [:]
        private var pinAnnotations: [String: PinAnnotation] = [:]
        private var styleReady = false
        private var cameraNonce = -1
        private var usedOffline = false

        init(_ p: PulseMapView) { parent = p }

        /// The first name that says something (web: name:latin || name_en || name, trimmed): an empty "name:latin" no longer
        /// hides the place's real name.
        static func placeName(_ a: [String: Any]) -> String {
            for k in ["name:latin", "name_en", "name"] {
                if let s = (a[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return ""
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map else { return }
            let pt = g.location(in: map)
            // the place badge nearest the finger (badges may overlap: the first hit could be the café next door)
            if let onPlace = parent.onTapPlace {
                let box = CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44)
                let named: [(MLNFeature, String, CGPoint)] = map.visibleFeatures(in: box, styleLayerIdentifiers: [PulseMapView.poiLayer]).compactMap { f in
                    let n = Coordinator.placeName(f.attributes)
                    guard !n.isEmpty, let p = f as? MLNPointFeature else { return nil }
                    return (f, n, map.convert(p.coordinate, toPointTo: map))
                }
                if let best = named.min(by: { hypot($0.2.x - pt.x, $0.2.y - pt.y) < hypot($1.2.x - pt.x, $1.2.y - pt.y) }),
                   let p = best.0 as? MLNPointFeature {
                    onPlace(best.1, p.coordinate, best.0.attributes["class"] as? String)
                    return
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
            // SOS beacons (a sender with no live position here)
            let bids = Set(parent.beacons.map(\.id))
            for (id, a) in beaconAnnotations where !bids.contains(id) { map.removeAnnotation(a); beaconAnnotations[id] = nil }
            for b in parent.beacons {
                if let a = beaconAnnotations[b.id] {
                    a.coordinate = b.coordinate
                    if a.name != b.name { a.name = b.name; (map.view(for: a) as? SOSBeaconView)?.show(name: b.name) }
                } else {
                    let a = BeaconAnnotation()
                    a.beaconID = b.id
                    a.name = b.name
                    a.coordinate = b.coordinate
                    beaconAnnotations[b.id] = a
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
            // open proposals and the spot being picked
            var pins = parent.proposals
            if let p = parent.pick { pins.append(p) }
            let pinIDs = Set(pins.map(\.id))
            for (id, a) in pinAnnotations where !pinIDs.contains(id) { map.removeAnnotation(a); pinAnnotations[id] = nil }
            for p in pins {
                if let a = pinAnnotations[p.id], a.name == p.name {
                    a.coordinate = p.coordinate
                } else {
                    if let old = pinAnnotations[p.id] { map.removeAnnotation(old) }
                    let a = PinAnnotation()
                    a.pinID = p.id
                    a.name = p.name
                    a.isPick = p.id == PulseMapView.pickID
                    a.coordinate = p.coordinate
                    pinAnnotations[p.id] = a
                    map.addAnnotation(a)
                }
            }
            updateShapes()
            regroup()
            applyCamera()
        }

        // MARK: camera

        /// The web's camera (PulseMap.tsx "camera"): applied again on every change while not free; a place, me or a friend at
        /// zoom max(current, 15.5); everyone framed without stale or rough (> 1 km) positions while a good one exists, with
        /// margins in proportion to the map and at most zoom 16.5.
        /// What the camera depends on: the ask, where people and the place are, the map's size. Labels change every second
        /// ("Last updated 45 s ago"); they redraw the pins but never move the camera.
        private struct CameraKey: Equatable {
            var camera: PulseCamera
            var spots: [Double]
            var size: CGSize
        }
        private var lastCameraKey: CameraKey?

        private func applyCamera() {
            guard let map else { return }
            let cam = parent.camera
            let key = CameraKey(camera: cam,
                                spots: parent.people.flatMap { [$0.coordinate.latitude, $0.coordinate.longitude, $0.accuracy] }
                                    + (parent.dest.map { [$0.coordinate.latitude, $0.coordinate.longitude] } ?? []),
                                size: map.bounds.size)
            guard key != lastCameraKey else { return }
            lastCameraKey = key
            if case .none = cam.mode { cameraNonce = cam.nonce; return }
            // not laid out yet (zero size): the fit waits for the real size instead of landing at zoom 0 (SyncKey has the size)
            guard map.bounds.width > 1, map.bounds.height > 1 else { return }
            let asked = cam.nonce != cameraNonce
            cameraNonce = cam.nonce
            let close = max(map.zoomLevel, 15.5)
            switch cam.mode {
            case .place:
                if let d = parent.dest { map.setCenter(d.coordinate, zoomLevel: close, animated: true) }
            case .me:
                if let me = parent.people.first(where: \.isMe) { map.setCenter(me.coordinate, zoomLevel: close, animated: true) }
            case .follow(let id):
                if let p = parent.people.first(where: { $0.id == id }) { map.setCenter(p.coordinate, zoomLevel: close, animated: true) }
            case .center(let lat, let lon):
                // once per ask: a pin set afterwards must not pull the map back
                if asked { map.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoomLevel: 15, animated: true) }
            case .everyone:
                let t = PulseRules.nowMs()
                let good = parent.people.filter { PulseRules.freshness($0.measuredAt, now: t) != .stale && $0.accuracy <= 1000 }
                let coords = (good.isEmpty ? parent.people : good).map(\.coordinate) + (parent.dest.map { [$0.coordinate] } ?? [])
                guard let first = coords.first else { return }
                if coords.count == 1 {
                    map.setCenter(first, zoomLevel: 15, animated: true)
                    return
                }
                let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
                let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                                 ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
                let w = map.bounds.width, h = map.bounds.height
                let pad = UIEdgeInsets(top: min(120, h * 0.22), left: min(80, w * 0.16), bottom: min(110, h * 0.18), right: min(90, w * 0.2))
                let fit = map.cameraThatFitsCoordinateBounds(bounds, edgePadding: pad)
                let z = MLNZoomLevelForAltitude(fit.altitude, fit.pitch, fit.centerCoordinate.latitude, map.bounds.size)
                if z > 16.5 {
                    map.setCenter(fit.centerCoordinate, zoomLevel: 16.5, animated: true)
                } else {
                    map.setCamera(fit, animated: true)
                }
            case .none:
                break
            }
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            // a hand on the map (drag, pinch, double tap, two-finger tap, one-finger zoom): the camera stays where it is put
            let hand: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom]
            if !reason.intersection(hand).isEmpty { parent.onUserMoved?() }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { regroup() }

        // MARK: style, shapes

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleReady = true
            // the place badges are painted here (they are in no sprite): pulse-poi-cafe|food|fast|bar|sweet
            for (name, img) in PulseMapView.poiBadges { style.setImage(img, forName: name) }
            let acc = MLNShapeSource(identifier: "pulse-accuracy", shape: nil, options: nil)
            let lines = MLNShapeSource(identifier: "pulse-lines", shape: nil, options: nil)
            let staleLines = MLNShapeSource(identifier: "pulse-lines-stale", shape: nil, options: nil)
            style.addSource(acc)
            style.addSource(lines)
            style.addSource(staleLines)
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
            // a stale position's line: the same dashes, faint (web line-opacity 0.25)
            let faint = MLNLineStyleLayer(identifier: "pulse-direction-stale", source: staleLines)
            faint.lineColor = NSExpression(forConstantValue: UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 0.25))
            faint.lineWidth = NSExpression(forConstantValue: 2.5)
            faint.lineDashPattern = NSExpression(forConstantValue: [1.5, 2])
            faint.lineCap = NSExpression(forConstantValue: "round")
            style.addLayer(fill)
            style.addLayer(edge)
            style.addLayer(faint)
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
            var staleLines: [MLNPolylineFeature] = []
            let t = PulseRules.nowMs()
            for p in parent.people {
                if p.accuracy >= 25 {
                    // at most 3 km (web): an internet-provider position of ±50 km must not paint the whole map
                    var ring = PulseRules.circlePolygon(lat: p.coordinate.latitude, lon: p.coordinate.longitude, radiusM: min(p.accuracy, 3000))
                    circles.append(MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count)))
                }
                if p.drawsLine, let d = parent.dest {
                    var pts = [p.coordinate, d.coordinate]
                    let f = MLNPolylineFeature(coordinates: &pts, count: 2)
                    if PulseRules.freshness(p.measuredAt, now: t) == .stale { staleLines.append(f) } else { lines.append(f) }
                }
            }
            (style.source(withIdentifier: "pulse-accuracy") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: circles)
            (style.source(withIdentifier: "pulse-lines") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: lines)
            (style.source(withIdentifier: "pulse-lines-stale") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: staleLines)
        }

        // MARK: annotations

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let a = annotation as? PersonAnnotation {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "person") as? PersonPinView) ?? PersonPinView(reuseIdentifier: "person")
                if let p = shown[a.personID] { v.show(p, token: parent.token, selected: parent.selected == p.id) }
                // a reused view may still be hidden under someone else's "+N": shown alone, then grouped again right after
                v.setGroup(1, showStatus: true)
                Task { @MainActor [weak self] in self?.regroup() }
                return v
            }
            if let a = annotation as? PinAnnotation {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? ProposalPinView) ?? ProposalPinView(reuseIdentifier: "pin")
                v.show(name: a.name, pick: a.isPick)
                return v
            }
            if let b = annotation as? BeaconAnnotation {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "sos") as? SOSBeaconView) ?? SOSBeaconView(reuseIdentifier: "sos")
                v.show(name: b.name)
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
                parent.onUserMoved?() // the camera is free now, or the next update would pan away again (web: "free")
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
    private let sosWaves = [CAShapeLayer(), CAShapeLayer()]
    private var sosOn = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 120, height: 104)
        for w in sosWaves {
            w.path = UIBezierPath(arcCenter: .zero, radius: 25, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
            w.position = CGPoint(x: 60, y: 48)
            w.fillColor = UIColor.clear.cgColor
            w.strokeColor = UIColor(red: 1, green: 0.23, blue: 0.31, alpha: 1).cgColor
            w.lineWidth = 2.5
            w.opacity = 0
            layer.addSublayer(w)
        }
        // the photo's centre (y 48) on the position, not the view's (y 52): the line and the accuracy circle meet the avatar
        centerOffset = CGVector(dx: 0, dy: 52 - 48)
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

    override func prepareForReuse() {
        super.prepareForReuse()
        setGroup(1, showStatus: true)
    }

    /// Core Animation drops running animations when the app goes to the background or the view leaves the window (MapLibre
    /// reuses annotation views): an SOS ring and its waves are started again when the view is back on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, sosOn, ring.animation(forKey: "sos") == nil else { return }
        sosOn = false
        setSOS(true)
    }

    func show(_ p: PulseMapPerson, token: String, selected: Bool) {
        let colour: UIColor
        switch p.ring {
        case .live: colour = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 1)
        case .lagging: colour = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 0.45)
        case .stale: colour = UIColor(white: 0.6, alpha: 1)
        case .arrived: colour = UIColor(red: 0.08, green: 0.76, blue: 0.48, alpha: 1)
        }
        ring.strokeColor = (p.sos ? UIColor(red: 1, green: 0.23, blue: 0.31, alpha: 1) : colour).cgColor
        ring.lineWidth = p.sos ? 4.5 : (selected ? 4.5 : 3)
        setSOS(p.sos)
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

    /// SOS: the ring blinks red (0.9 s) and two red waves go out. It keeps running with Reduce Motion, slower: it is an
    /// emergency.
    private func setSOS(_ on: Bool) {
        guard on != sosOn else { return }
        sosOn = on
        ring.removeAnimation(forKey: "sos")
        for w in sosWaves { w.removeAllAnimations(); w.opacity = 0 }
        guard on else { return }
        let k = UIAccessibility.isReduceMotionEnabled ? 1.4 : 1.0
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.45 * k
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        ring.add(blink, forKey: "sos")
        for (i, w) in sosWaves.enumerated() {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1
            s.toValue = 2.1
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0.8
            o.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [s, o]
            g.duration = 1.8 * k
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.9 * k
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.isRemovedOnCompletion = false
            w.add(g, forKey: "wave")
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
        // the gold dot's centre (y 22) on the place, not the view's (y 37): the dashed lines end in the dot
        centerOffset = CGVector(dx: 0, dy: 37 - 22)
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
        // a place without a name still says what it is (web "Meeting place")
        let n = d.name.trimmingCharacters(in: .whitespaces).isEmpty ? NSLocalizedString("pulse.place.default", comment: "") : d.name
        label.text = n
        accessibilityLabel = String(format: NSLocalizedString("pulse.place.ax", comment: ""), n)
    }
}

/// A proposed place ("📍 name · proposed", web PulseMap proposals) or the spot being picked (a cyan pin).
final class ProposalPinView: MLNAnnotationView {
    private let dot = UILabel()
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 160, height: 58)
        centerOffset = CGVector(dx: 0, dy: 29 - 16) // the dot's centre on the spot
        dot.frame = CGRect(x: 64, y: 0, width: 32, height: 32)
        dot.text = "📍"
        dot.textAlignment = .center
        dot.font = .systemFont(ofSize: 17)
        dot.backgroundColor = UIColor(red: 0.03, green: 0.1, blue: 0.14, alpha: 0.95)
        dot.layer.cornerRadius = 16
        dot.layer.borderWidth = 2
        dot.clipsToBounds = true
        label.frame = CGRect(x: 0, y: 35, width: 160, height: 20)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 11.5, weight: .bold)
        label.textColor = .white
        label.shadowColor = UIColor(white: 0, alpha: 0.8)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dot)
        addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(name: String, pick: Bool) {
        let cyan = UIColor(red: 0.24, green: 0.94, blue: 0.93, alpha: 1)
        dot.layer.borderColor = (pick ? cyan : UIColor(red: 1, green: 0.86, blue: 0.4, alpha: 1)).cgColor
        let n = name.trimmingCharacters(in: .whitespaces)
        label.text = pick ? n : String(format: NSLocalizedString("pulse.proposal.pin", comment: ""), n)
        label.isHidden = label.text?.isEmpty ?? true
        accessibilityLabel = label.text
    }
}

/// An SOS sender seen only through their SOS position: a red disc reading "SOS", two red waves and the name.
final class SOSBeaconView: MLNAnnotationView {
    private let disc = UILabel()
    private let name = UILabel()
    private let waves = [CAShapeLayer(), CAShapeLayer()]

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 140, height: 82)
        centerOffset = CGVector(dx: 0, dy: 41 - 26)
        let red = UIColor(red: 1, green: 0.23, blue: 0.31, alpha: 1)
        let k = UIAccessibility.isReduceMotionEnabled ? 1.4 : 1.0
        for (i, w) in waves.enumerated() {
            w.path = UIBezierPath(arcCenter: .zero, radius: 22, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
            w.position = CGPoint(x: 70, y: 26)
            w.fillColor = UIColor.clear.cgColor
            w.strokeColor = red.cgColor
            w.lineWidth = 2.5
            w.opacity = 0
            layer.addSublayer(w)
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1
            s.toValue = 2.2
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0.85
            o.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [s, o]
            g.duration = 1.8 * k
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.9 * k
            g.repeatCount = .infinity
            g.isRemovedOnCompletion = false // kept through the background and a reuse
            w.add(g, forKey: "wave")
        }
        disc.frame = CGRect(x: 48, y: 4, width: 44, height: 44)
        disc.text = "SOS"
        disc.textAlignment = .center
        disc.font = .systemFont(ofSize: 13, weight: .black)
        disc.textColor = .white
        disc.backgroundColor = red
        disc.layer.cornerRadius = 22
        disc.layer.borderColor = UIColor.white.cgColor
        disc.layer.borderWidth = 2.5
        disc.clipsToBounds = true
        name.frame = CGRect(x: 10, y: 54, width: 120, height: 22)
        name.textAlignment = .center
        name.font = .systemFont(ofSize: 12, weight: .bold)
        name.textColor = .white
        name.backgroundColor = UIColor(red: 0.45, green: 0.04, blue: 0.1, alpha: 0.92)
        name.layer.cornerRadius = 11
        name.clipsToBounds = true
        addSubview(disc)
        addSubview(name)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(name n: String) {
        name.text = " " + n + " "
        accessibilityLabel = String(format: NSLocalizedString("pulse.sos.beacon.ax", comment: ""), n)
    }
}

struct PulseSOSBeacon: Equatable {
    let id: String
    var coordinate: CLLocationCoordinate2D
    var name: String
    static func == (a: PulseSOSBeacon, b: PulseSOSBeacon) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.name == b.name
    }
}
