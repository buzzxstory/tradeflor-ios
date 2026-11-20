import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// Every QR in the app, as the website's features/identity/qr.tsx (QRSvg / BrandedQRSvg, brandedQrLayout, BrandMark, ScanBeam)
// and styles/31-identity.css: error correction Q, a 4-module quiet zone on a #f6fafc tile (corner 2.2 modules), dark modules
// #04121a, the TRADEFLOR mark in an empty centre square (only while the code has no centre alignment pattern, versions 1-6),
// and the scan beam (a cyan band sweeping top to bottom, 2.4 s, multiply) which is hidden when Reduce Motion is on.

struct BrandedQR: View {
    let text: String
    let side: CGFloat
    var beam: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let layout = Self.layout(for: text) {
                // the code is drawn once; the beam is its own small layer on top (it was a TimelineView that drew the whole
                // code again on every display frame)
                Canvas { ctx, size in
                    Self.draw(&ctx, size: size, layout: layout)
                }
                .overlay {
                    if beam && !reduceMotion { Beam(side: side, modules: CGFloat(layout.n)) }
                }
            } else {
                RoundedRectangle(cornerRadius: side * 0.06).fill(Self.paper)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
    }

    /// The branded code as a picture (no beam), for share cards and anything that needs a UIImage.
    static func image(text: String, side: CGFloat) -> UIImage? {
        guard let layout = layout(for: text), side > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { rc in
            let cg = rc.cgContext
            let n = CGFloat(layout.n)
            let u = side / n
            cg.scaleBy(x: u, y: u)
            let tile = CGRect(x: 0, y: 0, width: n, height: n)
            cg.setFillColor(UIColor(red: 0xF6 / 255.0, green: 0xFA / 255.0, blue: 0xFC / 255.0, alpha: 1).cgColor)
            cg.addPath(UIBezierPath(roundedRect: tile, cornerRadius: 2.2).cgPath)
            cg.fillPath()
            cg.setFillColor(UIColor(red: 0x04 / 255.0, green: 0x12 / 255.0, blue: 0x1A / 255.0, alpha: 1).cgColor)
            cg.addPath(layout.modules.cgPath)
            cg.fillPath()
            if let r = layout.markRect {
                cg.setFillColor(UIColor(red: 0x06 / 255.0, green: 0x17 / 255.0, blue: 0x22 / 255.0, alpha: 1).cgColor)
                cg.addPath(UIBezierPath(roundedRect: r, cornerRadius: r.width * 0.24).cgPath)
                cg.fillPath()
                UIImage(named: markAsset)?.draw(in: r.insetBy(dx: r.width * 0.14, dy: r.height * 0.14))
            }
        }
    }

    // MARK: - drawing

    static let paper = Theme.hex(0xF6FAFC)
    private static let ink = Theme.hex(0x04121A)
    private static let markGround = Theme.hex(0x061722)
    private static let beamEdge = Theme.hex(0x00D5E0)
    private static let beamGradient = Gradient(stops: [
        .init(color: Theme.hex(0x2FF0F3, 0), location: 0),
        .init(color: Theme.hex(0x2FF0F3, 0.32), location: 0.7),
        .init(color: Theme.hex(0x2FF0F3, 0.85), location: 1),
    ])
    /// The website's /tradeflor-brand-mark.png (byte-identical to the BrandFlower image set).
    private static let markAsset = "BrandFlower"

    /// The scan beam: a cyan band sweeping from just above the code to just below it (2.4 s, multiply), clipped to the tile.
    /// Only this band moves.
    private struct Beam: View {
        let side: CGFloat
        /// The code's side in modules (quiet zone included).
        let modules: CGFloat
        @State private var down = false

        var body: some View {
            let u = side / max(1, modules)
            let h = side * 0.11
            LinearGradient(gradient: BrandedQR.beamGradient, startPoint: .top, endPoint: .bottom)
                .frame(width: side, height: h)
                .overlay(alignment: .bottom) { BrandedQR.beamEdge.frame(height: 0.55 * u) }
                // translateY 0 -> 112 % of the code, the band's lower edge leading
                .offset(y: (down ? side * 1.12 : 0) - h)
                .animation(.timingCurve(0.45, 0, 0.55, 1, duration: 2.4).repeatForever(autoreverses: false), value: down)
                .frame(width: side, height: side, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 2.2 * u))
                .blendMode(.multiply)
                .allowsHitTesting(false)
                .onAppear { down = true }
        }
    }

    private static func draw(_ ctx: inout GraphicsContext, size: CGSize, layout: Layout) {
        let n = CGFloat(layout.n)
        let u = min(size.width, size.height) / n
        ctx.scaleBy(x: u, y: u)
        let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: n, height: n), cornerRadius: 2.2)
        ctx.fill(tile, with: .color(paper))
        ctx.fill(layout.modules, with: .color(ink))
        if let r = layout.markRect {
            ctx.fill(Path(roundedRect: r, cornerRadius: r.width * 0.24), with: .color(markGround))
            ctx.draw(Image(markAsset), in: r.insetBy(dx: r.width * 0.14, dy: r.height * 0.14))
        }
    }

    // MARK: - layout (brandedQrLayout)

    final class Layout {
        /// Side in modules, quiet zone included (code + 8).
        let n: Int
        /// The empty centre square in modules (0 = no mark).
        let hole: Int
        /// All dark modules (outside the hole), in module units with the quiet zone offset.
        let modules: Path
        /// The mark's box: hole - 1 modules, centred (a half-module margin all round).
        var markRect: CGRect? {
            guard hole > 1 else { return nil }
            let box = CGFloat(hole - 1)
            let at = (CGFloat(n) - box) / 2
            return CGRect(x: at, y: at, width: box, height: box)
        }

        init(n: Int, hole: Int, modules: Path) {
            self.n = n
            self.hole = hole
            self.modules = modules
        }
    }

    private static let cache = NSCache<NSString, Layout>()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func layout(for text: String) -> Layout? {
        if let hit = cache.object(forKey: text as NSString) { return hit }
        guard let m = matrix(text) else { return nil }
        let size = m.count
        let version = (size - 17) / 4
        var hole = 0
        if (size - 17) % 4 == 0, version <= 6 {
            hole = Int((Double(size) * 0.22).rounded())
            if hole % 2 != size % 2 { hole += 1 } // centred on whole modules
        }
        let lo = (size - hole) / 2
        let hi = lo + hole
        let path = CGMutablePath()
        for r in 0..<size {
            var c = 0
            while c < size {
                let inHole = hole > 0 && r >= lo && r < hi && c >= lo && c < hi
                guard m[r][c], !inHole else { c += 1; continue }
                var e = c
                while e < size && m[r][e] && !(hole > 0 && r >= lo && r < hi && e >= lo && e < hi) { e += 1 }
                path.addRect(CGRect(x: c + 4, y: r + 4, width: e - c, height: 1))
                c = e
            }
        }
        let layout = Layout(n: size + 8, hole: hole, modules: Path(path))
        cache.setObject(layout, forKey: text as NSString)
        return layout
    }

    /// The module matrix (true = dark), read from CIQRCodeGenerator at one pixel per module, correction Q.
    private static func matrix(_ text: String) -> [[Bool]]? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "Q"
        guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = ctx.bytesPerRow
        // Core Image adds its own margin: crop to the dark modules (the three finder patterns fix the code's bounds)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[y * rowBytes + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let size = maxX - minX + 1
        guard size >= 21, maxY - minY + 1 == size else { return nil }
        return (0..<size).map { r in (0..<size).map { c in px[(minY + r) * rowBytes + (minX + c)] < 128 } }
    }
}
