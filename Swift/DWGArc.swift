import Foundation

/// A decoded ARC entity (object type 17).
///
/// Validated byte-exact against AutoCAD's own property dump:
/// handle 0x1BD, centre (-18.1933, 6.68652, 0), radius 8.2931,
/// start angle 2.00242, end angle 1.51876.
struct DWGArc {
    let handle: Int
    let center: DWGPoint
    let radius: Double
    let thickness: Double
    let extrusion: DWGPoint
    /// Radians, counter-clockwise from the +X axis.
    let startAngle: Double
    /// Radians. May be numerically *less* than `startAngle` when the arc sweeps
    /// through 0 — callers must not assume start < end.
    let endAngle: Double
    let color: Int

    /// The swept angle in radians, normalised to 0..<2π.
    var sweep: Double {
        let raw = endAngle - startAngle
        return raw < 0 ? raw + 2 * .pi : raw
    }

    /// Decodes an ARC's data, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  centre
    ///     BD   radius
    ///     BT   thickness
    ///     BE   extrusion
    ///     BD   start angle (radians)
    ///     BD   end angle   (radians)
    ///
    /// Identical to CIRCLE up to the extrusion, then the two angles — which is
    /// why the two decoders stay in step.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGArc {
        let c = try r.read3BD()
        let radius = try r.readBD()
        let thickness = try r.readBT()
        let e = try r.readBE()
        let startAngle = try r.readBD()
        let endAngle = try r.readBD()

        guard radius.isFinite, radius > 0 else {
            throw DWGError.invalidValue("arc radius \(radius)")
        }
        guard startAngle.isFinite, endAngle.isFinite else {
            throw DWGError.invalidValue("arc angles \(startAngle)…\(endAngle)")
        }

        return DWGArc(
            handle: header.handle,
            center: DWGPoint(x: c.x, y: c.y, z: c.z),
            radius: radius,
            thickness: thickness,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            startAngle: startAngle,
            endAngle: endAngle,
            color: header.color
        )
    }
}
