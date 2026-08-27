import Foundation

/// A decoded POLYLINE_3D (object type 16) — a polyline whose vertices carry a
/// real Z, rather than sharing one elevation.
///
/// Structured like POLYLINE_2D: the vertices are separate objects (VERTEX_3D,
/// type 11) reached through the handle chain, and a SEQEND closes the run. It's
/// simpler, though — no bulges and no widths, because a 3D polyline is always
/// straight segments.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x1C1,
/// six vertices starting (21.4409, 14.6498) and (20.8962, 5.65378), not closed.
struct DWGPolyline3D {
    let handle: Int
    let isClosed: Bool
    /// Spline/curve fitting applied to the path, from the first flags byte.
    let curveFlags: UInt8
    let layer: Int?
    let firstVertex: Int?
    let lastVertex: Int?
    let seqEnd: Int?
    let color: Int

    /// Decodes a POLYLINE_3D, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     RC   flags 1 — spline/curve fitting
    ///     RC   flags 2 — bit 0 marks the polyline closed
    ///     ..   handle references, then first vertex, last vertex, seqend
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGPolyline3D {
        let curveFlags = try r.readRC()
        let closedFlags = try r.readRC()

        let refs = try DWGEntityHandles.parse(&r, header: header)
        let first = try r.readHandle().resolved(against: header.handle)
        let last = try r.readHandle().resolved(against: header.handle)
        let seq = try r.readHandle().resolved(against: header.handle)

        return DWGPolyline3D(
            handle: header.handle,
            isClosed: (closedFlags & 0x01) != 0,
            curveFlags: curveFlags,
            layer: refs.layer,
            firstVertex: first,
            lastVertex: last,
            seqEnd: seq,
            color: header.color
        )
    }
}

/// A decoded VERTEX_3D (object type 11) — one vertex of a POLYLINE_3D.
struct DWGVertex3D {
    let handle: Int
    let point: DWGPoint
    let flags: UInt8

    /// Decodes a VERTEX_3D, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     RC   flags
    ///     3BD  point
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGVertex3D {
        let flags = try r.readRC()
        let p = try r.read3BD()
        return DWGVertex3D(
            handle: header.handle,
            point: DWGPoint(x: p.x, y: p.y, z: p.z),
            flags: flags
        )
    }
}
