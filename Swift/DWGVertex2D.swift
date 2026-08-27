import Foundation

/// A decoded VERTEX_2D (object type 10) — one vertex of a POLYLINE_2D.
///
/// Unlike LWPOLYLINE, which packs its vertices inline, an old-style polyline
/// stores each vertex as a **separate object** with its own handle and entity
/// header. The polyline points at the first and last, and they are read from
/// the object map in between.
///
/// Verified against a real drawing: a 0.15-wide polyline decoded to vertices
/// (-0.5, -0.5) and (0.5, 0.5), and a closed one to (-0.25, 0) and (0.25, 0)
/// with both bulges exactly 1.0 — two semicircles forming a ring.
struct DWGVertex2D {
    let handle: Int
    let point: DWGPoint
    let startWidth: Double
    let endWidth: Double
    /// Tangent of a quarter of the arc's included angle to the next vertex.
    /// 0 = straight; 1 = a semicircle.
    let bulge: Double
    /// Curve-fit tangent direction, in radians.
    let tangentDirection: Double
    let flags: UInt8

    /// Decodes a VERTEX_2D, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     RC   flags
    ///     3BD  point
    ///     BD   start width — **if negative**, its absolute value is both the
    ///          start and end width, and no end width follows
    ///     BD   end width (only when start width was non-negative)
    ///     BD   bulge
    ///     BD   tangent direction
    ///
    /// That negative-width shorthand is easy to miss: read it naively and the
    /// end width consumes the bulge's bits, shifting everything after.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGVertex2D {
        let flags = try r.readRC()
        let p = try r.read3BD()

        var startWidth = try r.readBD()
        var endWidth: Double
        if startWidth < 0 {
            startWidth = abs(startWidth)
            endWidth = startWidth
        } else {
            endWidth = try r.readBD()
        }

        let bulge = try r.readBD()
        let tangentDirection = try r.readBD()

        return DWGVertex2D(
            handle: header.handle,
            point: DWGPoint(x: p.x, y: p.y, z: p.z),
            startWidth: startWidth,
            endWidth: endWidth,
            bulge: bulge,
            tangentDirection: tangentDirection,
            flags: flags
        )
    }
}
