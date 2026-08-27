import Foundation

/// A decoded SOLID (object type 31) or TRACE (object type 32) — a filled
/// four-cornered shape. The two are stored identically and differ only in
/// intent, so they share one type here.
///
/// Validated byte-exact against AutoCAD's own property dump: TRACE handle 0x221,
/// corners (28.5811, 21.5359), (28.5811, 24.3847), (26.7879, 21.5359),
/// (27.9679, 24.3847), thickness 0.
///
/// **Corner order is the trap.** Unlike 3DFACE, these store corners in a "Z"
/// order: 1 and 2 form one edge, 3 and 4 the opposite edge. Drawing them in
/// stored order (1→2→3→4) produces a self-crossing bowtie — for the sample above
/// that yields an area of exactly zero, i.e. nothing visible at all. The correct
/// path is **1→2→4→3**, which `orderedCorners` returns.
struct DWGSolid {

    enum Kind {
        case solid
        case trace
    }

    let handle: Int
    let kind: Kind
    let corner1: DWGPoint
    let corner2: DWGPoint
    let corner3: DWGPoint
    let corner4: DWGPoint
    let thickness: Double
    let elevation: Double
    let extrusion: DWGPoint
    let color: Int

    /// Corners as a drawable path: 1 → 2 → 4 → 3.
    var orderedCorners: [DWGPoint] { [corner1, corner2, corner4, corner3] }

    /// Decodes a SOLID or TRACE, with the reader positioned immediately after
    /// the common entity header.
    ///
    ///     BT   thickness
    ///     BD   elevation (the shared Z for all four corners)
    ///     2RD  corner 1 … corner 4
    ///     BE   extrusion
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader, kind: Kind) throws -> DWGSolid {
        let thickness = try r.readBT()
        let elevation = try r.readBD()

        func corner() throws -> DWGPoint {
            DWGPoint(x: try r.readRD(), y: try r.readRD(), z: elevation)
        }
        let c1 = try corner()
        let c2 = try corner()
        let c3 = try corner()
        let c4 = try corner()

        let e = try r.readBE()

        return DWGSolid(
            handle: header.handle,
            kind: kind,
            corner1: c1, corner2: c2, corner3: c3, corner4: c4,
            thickness: thickness,
            elevation: elevation,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            color: header.color
        )
    }
}
