import Foundation

/// A decoded 3DFACE entity (object type 28) — a filled three- or four-cornered
/// face.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x20E,
/// corners (25.6082, 37.403), (29.7663, 37.403), (29.7663, 34.5737),
/// (25.4136, 34.5737), all edges visible.
///
/// Unlike SOLID and TRACE, a 3DFACE's corners run **sequentially** around the
/// shape, so it can be drawn in the order stored. A triangular face simply
/// repeats its last corner.
struct DWG3DFace {
    let handle: Int
    let corner1: DWGPoint
    let corner2: DWGPoint
    let corner3: DWGPoint
    let corner4: DWGPoint
    /// Bit flags marking individual edges invisible (bit 0 = edge 1, and so on).
    let invisibleEdges: Int
    let color: Int

    /// True when the fourth corner repeats the third — i.e. a triangle.
    var isTriangle: Bool {
        corner4.x == corner3.x && corner4.y == corner3.y && corner4.z == corner3.z
    }

    /// The corners in drawing order.
    var corners: [DWGPoint] {
        isTriangle ? [corner1, corner2, corner3] : [corner1, corner2, corner3, corner4]
    }

    /// Decodes a 3DFACE, with the reader positioned immediately after the common
    /// entity header.
    ///
    ///     B    "has no flags" — when set, the invisible-edge field is absent
    ///     B    "Z is zero"    — when set, no Z is stored for the first corner
    ///     RD   x, RD y of corner 1
    ///     RD   z of corner 1   (only when Z isn't zero)
    ///     3DD  corner 2, defaulting to corner 1
    ///     3DD  corner 3, defaulting to corner 2
    ///     3DD  corner 4, defaulting to corner 3
    ///     BS   invisible edges (only when flags are present)
    ///
    /// Each corner defaults to the one before it, which is what makes a
    /// triangle — a repeated last corner — cost almost nothing to store.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWG3DFace {
        let hasNoFlags = try r.readBit() == 1
        let zIsZero = try r.readBit() == 1

        let x1 = try r.readRD()
        let y1 = try r.readRD()
        let z1 = zIsZero ? 0 : try r.readRD()
        let c1 = DWGPoint(x: x1, y: y1, z: z1)

        let c2 = try read3DD(&r, default: c1)
        let c3 = try read3DD(&r, default: c2)
        let c4 = try read3DD(&r, default: c3)

        let invisible = hasNoFlags ? 0 : try r.readBS()

        return DWG3DFace(
            handle: header.handle,
            corner1: c1, corner2: c2, corner3: c3, corner4: c4,
            invisibleEdges: invisible,
            color: header.color
        )
    }

    private static func read3DD(_ r: inout DWGBitReader, default d: DWGPoint) throws -> DWGPoint {
        DWGPoint(
            x: try r.readDD(default: d.x),
            y: try r.readDD(default: d.y),
            z: try r.readDD(default: d.z)
        )
    }
}
