import Foundation

/// A decoded POLYLINE_2D (object type 15) — the old-style polyline.
///
/// Where LWPOLYLINE stores its vertices inline, this one stores only *handles*:
/// the first vertex, the last vertex, and a SEQEND that closes the run. The
/// vertices themselves are separate VERTEX_2D objects, fetched from the object
/// map. Callers must resolve them to get any geometry — this type on its own
/// describes an empty shape.
///
/// Verified against a real drawing: an open polyline of width 0.15 spanning
/// (-0.5, -0.5) to (0.5, 0.5), and a closed one of width 0.5 whose two vertices
/// both carry bulge 1.0 (a ring). Both resolved to layer "0".
struct DWGPolyline2D {
    let handle: Int
    let isClosed: Bool
    /// 0 = none, 5 = quadratic B-spline, 6 = cubic B-spline, 8 = Bezier.
    let curveType: Int
    let defaultStartWidth: Double
    let defaultEndWidth: Double
    let thickness: Double
    let elevation: Double
    let extrusion: DWGPoint
    let layer: Int?
    /// Handle of the first VERTEX_2D.
    let firstVertex: Int?
    /// Handle of the last VERTEX_2D.
    let lastVertex: Int?
    /// Handle of the SEQEND (object type 6) that terminates the vertex list.
    /// SEQEND carries no data of its own — it exists purely as a marker.
    let seqEnd: Int?
    let color: Int

    private enum Flag {
        static let closed          = 0x01
        static let curveFit        = 0x02
        static let splineFit       = 0x04
        static let is3DPolyline    = 0x08
        static let is3DMesh        = 0x10
        static let isPolyfaceMesh  = 0x40
    }

    /// Decodes a POLYLINE_2D, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     BS   flags
    ///     BS   curve type
    ///     BD   default start width
    ///     BD   default end width
    ///     BT   thickness
    ///     BD   elevation
    ///     BE   extrusion
    ///     ..   handle references, then:
    ///     H    first vertex
    ///     H    last vertex
    ///     H    seqend
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGPolyline2D {
        let flags = try r.readBS()
        let curveType = try r.readBS()
        let startWidth = try r.readBD()
        let endWidth = try r.readBD()
        let thickness = try r.readBT()
        let elevation = try r.readBD()
        let e = try r.readBE()

        let refs = try DWGEntityHandles.parse(&r, header: header)

        let first = try r.readHandle().resolved(against: header.handle)
        let last = try r.readHandle().resolved(against: header.handle)
        let seq = try r.readHandle().resolved(against: header.handle)

        return DWGPolyline2D(
            handle: header.handle,
            isClosed: (flags & Flag.closed) != 0,
            curveType: curveType,
            defaultStartWidth: startWidth,
            defaultEndWidth: endWidth,
            thickness: thickness,
            elevation: elevation,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            layer: refs.layer,
            firstVertex: first,
            lastVertex: last,
            seqEnd: seq,
            color: header.color
        )
    }
}
