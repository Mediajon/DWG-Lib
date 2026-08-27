import Foundation

/// A decoded RAY (object type 40) or XLINE (object type 41).
///
/// The two are stored identically — a base point plus a direction vector — and
/// differ only in extent: a ray starts at the point and runs to infinity in one
/// direction, while an xline (construction line) extends infinitely both ways.
/// They share one type here because splitting them would duplicate the file
/// without adding meaning.
///
/// Validated byte-exact against AutoCAD's own property dumps:
/// - RAY handle 0x1C0 — base (10.0931, 10.1931), direction (0, -1, 0)
/// - XLINE handle 0x1BB — base (34.684, 48.4498), direction (-0.018621, -0.999827, 0)
///
/// Renderers must clip these to the drawing extents: neither has a finite
/// length, so they cannot be emitted as ordinary line segments.
struct DWGInfiniteLine {

    enum Kind {
        /// Infinite in one direction from `basePoint`.
        case ray
        /// Infinite in both directions through `basePoint`.
        case xline
    }

    let handle: Int
    let kind: Kind
    let basePoint: DWGPoint
    /// Unit direction vector.
    let direction: DWGPoint
    let color: Int

    /// A second point one unit along the direction — matches AutoCAD's
    /// reported "SecondPoint", and is handy for building a clipped segment.
    var secondPoint: DWGPoint {
        DWGPoint(
            x: basePoint.x + direction.x,
            y: basePoint.y + direction.y,
            z: basePoint.z + direction.z
        )
    }

    /// Decodes a RAY or XLINE, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  base point
    ///     3BD  direction vector
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader, kind: Kind) throws -> DWGInfiniteLine {
        let p = try r.read3BD()
        let v = try r.read3BD()

        guard p.x.isFinite, p.y.isFinite, v.x.isFinite, v.y.isFinite else {
            throw DWGError.invalidValue("infinite line has non-finite geometry")
        }

        return DWGInfiniteLine(
            handle: header.handle,
            kind: kind,
            basePoint: DWGPoint(x: p.x, y: p.y, z: p.z),
            direction: DWGPoint(x: v.x, y: v.y, z: v.z),
            color: header.color
        )
    }
}
