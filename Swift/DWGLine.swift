import Foundation

/// A decoded LINE entity (object type 19).
///
/// Validated byte-exact against AutoCAD's own property dump:
/// handle 0x1CA, start (21.6078, 2.81192, 0), end (11.0307, 16.6375, 0).
struct DWGLine {
    let handle: Int
    let start: DWGPoint
    let end: DWGPoint
    let thickness: Double
    let extrusion: DWGPoint
    let color: Int

    /// Decodes a LINE's data, with the reader positioned immediately after the
    /// common entity header.
    ///
    /// R2000 stores lines compactly and asymmetrically — the X pair first, then
    /// the Y pair, with each end coordinate written as a delta against its own
    /// start. When both Z values are zero (the usual case in 2D drawings) a
    /// single flag bit replaces them entirely:
    ///
    ///     B   "Z coordinates are both zero" flag
    ///     RD  start X        DD  end X  (default: start X)
    ///     RD  start Y        DD  end Y  (default: start Y)
    ///     RD  start Z        DD  end Z  (only when the flag is clear)
    ///     BT  thickness
    ///     BE  extrusion
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGLine {
        let zBothZero = try r.readBit() == 1

        let sx = try r.readRD()
        let ex = try r.readDD(default: sx)
        let sy = try r.readRD()
        let ey = try r.readDD(default: sy)

        var sz = 0.0
        var ez = 0.0
        if !zBothZero {
            sz = try r.readRD()
            ez = try r.readDD(default: sz)
        }

        let thickness = try r.readBT()
        let e = try r.readBE()

        return DWGLine(
            handle: header.handle,
            start: DWGPoint(x: sx, y: sy, z: sz),
            end: DWGPoint(x: ex, y: ey, z: ez),
            thickness: thickness,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            color: header.color
        )
    }
}
