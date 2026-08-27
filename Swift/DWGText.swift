import Foundation

/// A decoded TEXT entity (object type 1) — single-line text.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x22A,
/// insertion point (24.826, 57.7467), height 0.2, rotation 0, width factor 1,
/// string "some text".
struct DWGText {

    /// Horizontal justification.
    enum HorizontalAlignment: Int {
        case left = 0, center = 1, right = 2, aligned = 3, middle = 4, fit = 5
    }

    /// Vertical justification.
    enum VerticalAlignment: Int {
        case baseline = 0, bottom = 1, middle = 2, top = 3
    }

    let handle: Int
    let insertionPoint: DWGPoint
    /// Second alignment point, used when the text is centred, fitted, or
    /// otherwise not left/baseline aligned.
    let alignmentPoint: DWGPoint
    let height: Double
    /// Radians, counter-clockwise.
    let rotation: Double
    /// Italic slant, in radians.
    let obliqueAngle: Double
    /// Horizontal stretch; 1.0 is unscaled.
    let widthFactor: Double
    let text: String
    let thickness: Double
    let extrusion: DWGPoint
    let horizontalAlignment: HorizontalAlignment
    let verticalAlignment: VerticalAlignment
    let color: Int

    /// Bits of the leading DataFlags byte. A set bit means the corresponding
    /// field is **absent** and takes its default — R2000 omits whatever it can.
    private enum Absent {
        static let elevation    = 0x01
        static let alignPoint   = 0x02
        static let obliqueAngle = 0x04
        static let rotation     = 0x08
        static let widthFactor  = 0x10
        static let generation   = 0x20
        static let hAlignment   = 0x40
        static let vAlignment   = 0x80
    }

    /// Decodes a TEXT entity, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     RC   DataFlags — a set bit means "field omitted, use the default"
    ///     RD   elevation        (unless omitted)
    ///     2RD  insertion point
    ///     2DD  alignment point  (unless omitted; defaults to the insertion point)
    ///     BE   extrusion
    ///     BT   thickness
    ///     BD   oblique angle    (unless omitted)
    ///     BD   rotation         (unless omitted)
    ///     RD   height           ← a raw double, not a bitdouble
    ///     BD   width factor     (unless omitted)
    ///     TV   the string
    ///     BS   generation       (unless omitted)
    ///     BS   horizontal alignment (unless omitted)
    ///     BS   vertical alignment   (unless omitted)
    ///
    /// `height` being a raw `RD` while its neighbours are `BD` is easy to get
    /// wrong; it was confirmed by locating the known value's exact bit position.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGText {
        let flags = Int(try r.readRC())

        let elevation = (flags & Absent.elevation) != 0 ? 0 : try r.readRD()

        let ix = try r.readRD()
        let iy = try r.readRD()

        var ax = 0.0
        var ay = 0.0
        if (flags & Absent.alignPoint) == 0 {
            ax = try r.readDD(default: ix)
            ay = try r.readDD(default: iy)
        }

        let e = try r.readBE()
        let thickness = try r.readBT()

        let oblique = (flags & Absent.obliqueAngle) != 0 ? 0 : try r.readBD()
        let rotation = (flags & Absent.rotation) != 0 ? 0 : try r.readBD()
        let height = try r.readRD()
        let widthFactor = (flags & Absent.widthFactor) != 0 ? 1 : try r.readBD()
        let value = try r.readTV()
        _ = (flags & Absent.generation) != 0 ? 0 : try r.readBS()
        let hAlign = (flags & Absent.hAlignment) != 0 ? 0 : try r.readBS()
        let vAlign = (flags & Absent.vAlignment) != 0 ? 0 : try r.readBS()

        guard height.isFinite, height >= 0 else {
            throw DWGError.invalidValue("text height \(height)")
        }

        return DWGText(
            handle: header.handle,
            insertionPoint: DWGPoint(x: ix, y: iy, z: elevation),
            alignmentPoint: DWGPoint(x: ax, y: ay, z: elevation),
            height: height,
            rotation: rotation,
            obliqueAngle: oblique,
            widthFactor: widthFactor,
            text: value,
            thickness: thickness,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            horizontalAlignment: HorizontalAlignment(rawValue: hAlign) ?? .left,
            verticalAlignment: VerticalAlignment(rawValue: vAlign) ?? .baseline,
            color: header.color
        )
    }
}
