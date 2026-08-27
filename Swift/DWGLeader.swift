import Foundation

/// A decoded LEADER (object type 45) — an annotation arrow: a short run of
/// points ending at whatever it points out, usually with a label alongside.
///
/// Only the path is decoded. A LEADER carries a long tail of styling and
/// annotation fields whose layout shifts between releases, and none of it is
/// needed to draw the leader itself — the points are the geometry. The tail is
/// left unread, which is safe because the reader stops here and the handle
/// section is reached separately.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x22E,
/// `AcDbLeader`, three points starting (29.2808, -1.00917, 0).
struct DWGLeader {
    let handle: Int
    /// The leader's path, in world coordinates.
    let points: [DWGPoint]
    /// 0 text, 1 tolerance, 2 block insert, 3 none.
    let annotationType: Int
    /// 0 straight segments, 1 spline.
    let pathType: Int
    let color: Int

    /// Decodes a LEADER, with the reader positioned immediately after the common
    /// entity header.
    ///
    ///     B    unused
    ///     BS   annotation type
    ///     BS   path type
    ///     BL   number of points
    ///     3BD  point, repeated
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGLeader {
        _ = try r.readBit()
        let annotationType = try r.readBS()
        let pathType = try r.readBS()
        let count = try r.readBL()

        guard count > 0, count < 10_000 else {
            throw DWGError.invalidValue("leader point count \(count)")
        }

        var points: [DWGPoint] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let p = try r.read3BD()
            points.append(DWGPoint(x: p.x, y: p.y, z: p.z))
        }

        return DWGLeader(
            handle: header.handle,
            points: points,
            annotationType: annotationType,
            pathType: pathType,
            color: header.color
        )
    }
}
