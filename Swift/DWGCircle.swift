import Foundation

/// A decoded CIRCLE entity (object type 18).
///
/// Validated against real R2000 drawings (Constraints.dwg, TS1.dwg), producing
/// plausible geometry in both.
struct DWGCircle {
    let handle: Int
    let center: DWGPoint
    let radius: Double
    let thickness: Double
    let extrusion: DWGPoint
    let color: Int

    /// Decodes a CIRCLE's data, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  centre
    ///     BD   radius
    ///     BT   thickness
    ///     BE   extrusion
    ///
    /// Note the centre is a plain 3BD here — unlike LINE, circles don't use the
    /// split-coordinate / delta trick.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGCircle {
        let c = try r.read3BD()
        let radius = try r.readBD()
        let thickness = try r.readBT()
        let e = try r.readBE()

        guard radius.isFinite, radius > 0 else {
            throw DWGError.invalidValue("circle radius \(radius)")
        }

        return DWGCircle(
            handle: header.handle,
            center: DWGPoint(x: c.x, y: c.y, z: c.z),
            radius: radius,
            thickness: thickness,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            color: header.color
        )
    }
}
