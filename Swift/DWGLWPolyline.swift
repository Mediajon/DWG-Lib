import Foundation

/// A decoded LWPOLYLINE entity (object type 77) — the workhorse of real 2D
/// drawings: rectangles, polygons, donuts and most freehand outlines are all
/// lightweight polylines.
///
/// Validated against real R2000 drawings:
/// - `Polygon.dwg` — a 10-point closed polyline that reproduces AutoCAD's
///   reported length (39.7655) and area (121.668) exactly, with every
///   circumradius agreeing to seven decimals (a perfect regular decagon).
/// - `Donut.dwg` — 2 points, both bulges exactly 1.0 (two semicircles).
struct DWGLWPolyline {

    /// A single vertex, with the arc and width information that may accompany it.
    struct Vertex {
        var point: DWGPoint
        /// Tangent of a quarter of the arc's included angle. 0 = straight
        /// segment to the next vertex; 1 = a semicircle.
        var bulge: Double = 0
        var startWidth: Double = 0
        var endWidth: Double = 0
    }

    let handle: Int
    let vertices: [Vertex]
    let isClosed: Bool
    let constantWidth: Double
    let elevation: Double
    let thickness: Double
    let extrusion: DWGPoint
    let color: Int

    /// Which optional fields are present. Only the flags we act on are named.
    private enum Flag {
        static let extrusion     = 0x001
        static let thickness     = 0x002
        static let constantWidth = 0x004
        static let elevation     = 0x008
        static let bulges        = 0x010
        static let widths        = 0x020
        static let closed        = 0x200
    }

    /// Decodes an LWPOLYLINE, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     BS   flags
    ///     BD   constant width  (only if the flag is set)
    ///     BD   elevation       ( "  )
    ///     BD   thickness       ( "  )
    ///     3BD  extrusion       ( "  )
    ///     BL   vertex count
    ///     BL   bulge count     ( "  )
    ///     BL   width count     ( "  )
    ///     2RD  first vertex
    ///     2DD  each remaining vertex (default: the previous vertex)
    ///     BD   each bulge
    ///     BD BD  each width pair
    ///
    /// Only the first vertex is stored in full; the rest are deltas against
    /// their predecessor, which is what makes these compact.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGLWPolyline {
        let flags = try r.readBS()

        let constantWidth = (flags & Flag.constantWidth) != 0 ? try r.readBD() : 0
        let elevation     = (flags & Flag.elevation) != 0 ? try r.readBD() : 0
        let thickness     = (flags & Flag.thickness) != 0 ? try r.readBD() : 0

        var extrusion = DWGPoint.defaultExtrusion
        if (flags & Flag.extrusion) != 0 {
            let e = try r.read3BD()
            extrusion = DWGPoint(x: e.x, y: e.y, z: e.z)
        }

        let pointCount = try r.readBL()
        guard pointCount > 0, pointCount < 1_000_000 else {
            throw DWGError.invalidValue("lwpolyline vertex count \(pointCount)")
        }
        let bulgeCount = (flags & Flag.bulges) != 0 ? try r.readBL() : 0
        let widthCount = (flags & Flag.widths) != 0 ? try r.readBL() : 0
        guard bulgeCount >= 0, bulgeCount <= pointCount,
              widthCount >= 0, widthCount <= pointCount else {
            throw DWGError.invalidValue("lwpolyline bulge/width counts \(bulgeCount)/\(widthCount)")
        }

        var points: [DWGPoint] = []
        points.reserveCapacity(pointCount)

        var x = try r.readRD()
        var y = try r.readRD()
        points.append(DWGPoint(x: x, y: y, z: elevation))
        for _ in 1..<pointCount {
            x = try r.readDD(default: x)
            y = try r.readDD(default: y)
            points.append(DWGPoint(x: x, y: y, z: elevation))
        }

        var bulges: [Double] = []
        bulges.reserveCapacity(bulgeCount)
        for _ in 0..<bulgeCount { bulges.append(try r.readBD()) }

        var widths: [(Double, Double)] = []
        widths.reserveCapacity(widthCount)
        for _ in 0..<widthCount { widths.append((try r.readBD(), try r.readBD())) }

        let vertices = points.enumerated().map { index, p in
            Vertex(
                point: p,
                bulge: index < bulges.count ? bulges[index] : 0,
                startWidth: index < widths.count ? widths[index].0 : constantWidth,
                endWidth: index < widths.count ? widths[index].1 : constantWidth
            )
        }

        return DWGLWPolyline(
            handle: header.handle,
            vertices: vertices,
            isClosed: (flags & Flag.closed) != 0,
            constantWidth: constantWidth,
            elevation: elevation,
            thickness: thickness,
            extrusion: extrusion,
            color: header.color
        )
    }
}
