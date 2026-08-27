import Foundation

/// A decoded POINT entity (object type 27).
///
/// Named `DWGPointEntity` to avoid colliding with `DWGPoint`, which is the
/// geometry type used throughout the parser.
///
/// Validated byte-exact against AutoCAD's own property dump:
/// handle 0x1C0, coordinates (27.928, 8.65308, 0).
struct DWGPointEntity {
    let handle: Int
    let position: DWGPoint
    let thickness: Double
    let extrusion: DWGPoint
    /// Rotation of the point's display symbol about the extrusion axis, in
    /// radians. Almost always zero.
    let xAxisAngle: Double
    let color: Int

    /// Decodes a POINT's data, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  position
    ///     BT   thickness
    ///     BE   extrusion
    ///     BD   x-axis angle
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGPointEntity {
        let p = try r.read3BD()
        let thickness = try r.readBT()
        let e = try r.readBE()
        let xAxisAngle = try r.readBD()

        return DWGPointEntity(
            handle: header.handle,
            position: DWGPoint(x: p.x, y: p.y, z: p.z),
            thickness: thickness,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            xAxisAngle: xAxisAngle,
            color: header.color
        )
    }
}
