import Foundation

/// A decoded MLINE (object type 47) — a multi-line: several parallel lines
/// following one path, as used for walls and roads.
///
/// The entity stores only the *path*; how many lines run alongside it, and how
/// far off, lives in a separate MLINESTYLE object it points at by handle. So an
/// MLINE cannot be drawn from its own data alone — the style has to be resolved
/// first.
///
/// Each vertex carries a **miter direction** as well as a point: that's the
/// direction the parallel lines are offset along, angled to bisect the corner so
/// the outer line stays parallel through bends. Using the segment normal instead
/// would make the offsets pull apart at every corner.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x1BD,
/// scale 1.0, justification 0, six vertices starting (9.15538, 14.989) and
/// (18.7947, 10.0057), style "STANDARD".
struct DWGMLine {

    struct Vertex {
        var point: DWGPoint
        /// Direction of travel along the path.
        var direction: DWGPoint
        /// Direction the parallel lines are offset along at this vertex.
        var miterDirection: DWGPoint
    }

    /// Where the path sits relative to the lines: 0 top, 1 zero, 2 bottom.
    enum Justification: UInt8 {
        case top = 0, zero = 1, bottom = 2
    }

    let handle: Int
    /// Multiplies every offset in the style.
    let scale: Double
    let justification: Justification
    let basePoint: DWGPoint
    let extrusion: DWGPoint
    let isClosed: Bool
    /// How many parallel lines the style defines. Repeated here so the vertex
    /// data can be read without the style.
    let lineCount: Int
    let vertices: [Vertex]
    let layer: Int?
    /// Handle of the MLINESTYLE holding the offsets.
    let styleHandle: Int?
    let color: Int

    /// Decodes an MLINE, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     BD   scale
    ///     RC   justification
    ///     3BD  base point
    ///     3BD  extrusion
    ///     BS   flags — bit 0 marks it closed
    ///     RC   number of lines in the style
    ///     BS   vertex count
    ///     ..   each vertex: 3BD point, 3BD direction, 3BD miter direction,
    ///          then per style line: BS count + that many BD segment parameters,
    ///          and BS count + that many BD fill parameters
    ///     ..   handle references, then the style handle
    ///
    /// The per-line parameters describe where the line is broken along each
    /// segment, not where it sits — the offsets come from the style.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGMLine {
        let scale = try r.readBD()
        let justificationRaw = try r.readRC()
        let base = try r.read3BD()
        let e = try r.read3BD()
        let flags = try r.readBS()
        let lineCount = Int(try r.readRC())
        let vertexCount = try r.readBS()

        guard vertexCount >= 0, vertexCount < 1_000_000 else {
            throw DWGError.invalidValue("mline vertex count \(vertexCount)")
        }
        guard lineCount >= 0, lineCount < 1_000 else {
            throw DWGError.invalidValue("mline line count \(lineCount)")
        }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(vertexCount)

        for _ in 0..<vertexCount {
            let p = try r.read3BD()
            let d = try r.read3BD()
            let m = try r.read3BD()
            for _ in 0..<lineCount {
                let segmentCount = try r.readBS()
                guard segmentCount >= 0, segmentCount < 10_000 else {
                    throw DWGError.invalidValue("mline segment parameter count \(segmentCount)")
                }
                for _ in 0..<segmentCount { _ = try r.readBD() }
                let fillCount = try r.readBS()
                guard fillCount >= 0, fillCount < 10_000 else {
                    throw DWGError.invalidValue("mline fill parameter count \(fillCount)")
                }
                for _ in 0..<fillCount { _ = try r.readBD() }
            }
            vertices.append(Vertex(
                point: DWGPoint(x: p.x, y: p.y, z: p.z),
                direction: DWGPoint(x: d.x, y: d.y, z: d.z),
                miterDirection: DWGPoint(x: m.x, y: m.y, z: m.z)
            ))
        }

        let refs = try DWGEntityHandles.parse(&r, header: header)
        let style = try r.readHandle().resolved(against: header.handle)

        return DWGMLine(
            handle: header.handle,
            scale: scale,
            justification: Justification(rawValue: justificationRaw) ?? .top,
            basePoint: DWGPoint(x: base.x, y: base.y, z: base.z),
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            isClosed: (flags & 0x02) != 0,
            lineCount: lineCount,
            vertices: vertices,
            layer: refs.layer,
            styleHandle: style,
            color: header.color
        )
    }
}

/// A decoded MLINESTYLE (object type 73) — the parallel lines an MLINE follows.
///
/// Validated against a real drawing: style "STANDARD" decodes as two lines at
/// +0.5 and -0.5, both ByLayer, exactly as AutoCAD defines it.
struct DWGMLineStyle {

    struct Line {
        /// Distance from the path, multiplied by the MLINE's scale.
        var offset: Double
        /// 256 means ByLayer.
        var colorIndex: Int
    }

    let handle: Int
    let name: String
    let styleDescription: String
    let lines: [Line]

    /// Decodes an MLINESTYLE, with the reader positioned immediately after the
    /// common **object** header.
    ///
    ///     TV   name
    ///     TV   description
    ///     BS   flags
    ///     BS   fill colour
    ///     BD   start angle       BD  end angle
    ///     RC   line count
    ///     ..   each line: BD offset, BS colour, BS linetype index
    static func parse(_ r: inout DWGBitReader, header: DWGObjectHeader) throws -> DWGMLineStyle {
        let name = try r.readTV()
        let description = try r.readTV()
        _ = try r.readBS()              // flags
        _ = try r.readBS()              // fill colour
        _ = try r.readBD()              // start angle
        _ = try r.readBD()              // end angle
        let count = Int(try r.readRC())
        guard count >= 0, count < 1_000 else {
            throw DWGError.invalidValue("mline style line count \(count)")
        }

        var lines: [Line] = []
        lines.reserveCapacity(count)
        for _ in 0..<count {
            let offset = try r.readBD()
            let color = try r.readBS()
            _ = try r.readBS()          // linetype index
            lines.append(Line(offset: offset, colorIndex: color))
        }

        return DWGMLineStyle(
            handle: header.handle,
            name: name,
            styleDescription: description,
            lines: lines
        )
    }
}
