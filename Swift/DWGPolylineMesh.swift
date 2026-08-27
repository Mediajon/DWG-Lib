import Foundation

/// A decoded POLYLINE_MESH (object type 30) — a rectangular grid of vertices,
/// the old-style 3D surface mesh.
///
/// Like POLYLINE_2D, the vertices live in separate objects (VERTEX_MESH,
/// type 12) reached through the handle chain; this type stores only the grid's
/// shape.
///
/// Validated against a real drawing: a 3 × 4 mesh whose 12 vertices decode with
/// the first at (25.1299, 32.8528) — matching AutoCAD exactly, and matching the
/// 12 VERTEX entities in the same drawing's DXF export.
struct DWGPolylineMesh {
    let handle: Int
    /// Vertices along the M direction.
    let mVertexCount: Int
    /// Vertices along the N direction.
    let nVertexCount: Int
    let mDensity: Int
    let nDensity: Int
    let isClosedInM: Bool
    let isClosedInN: Bool
    let curveType: Int
    let layer: Int?
    let firstVertex: Int?
    let lastVertex: Int?
    let seqEnd: Int?
    let color: Int

    /// Total vertices expected in the grid.
    var vertexCount: Int { mVertexCount * nVertexCount }

    private enum Flag {
        static let closedInM = 0x01
        static let is3DMesh  = 0x10
        static let closedInN = 0x20
    }

    /// Decodes a POLYLINE_MESH, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     BS   flags
    ///     BS   curve type
    ///     BS   M vertex count      BS  N vertex count
    ///     BS   M density           BS  N density
    ///     ..   handle references, then first vertex, last vertex, seqend
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGPolylineMesh {
        let flags = try r.readBS()
        let curveType = try r.readBS()
        let mCount = try r.readBS()
        let nCount = try r.readBS()
        let mDensity = try r.readBS()
        let nDensity = try r.readBS()

        guard mCount >= 0, nCount >= 0, mCount < 100_000, nCount < 100_000 else {
            throw DWGError.invalidValue("mesh grid \(mCount)×\(nCount)")
        }

        let refs = try DWGEntityHandles.parse(&r, header: header)
        let first = try r.readHandle().resolved(against: header.handle)
        let last = try r.readHandle().resolved(against: header.handle)
        let seq = try r.readHandle().resolved(against: header.handle)

        return DWGPolylineMesh(
            handle: header.handle,
            mVertexCount: mCount,
            nVertexCount: nCount,
            mDensity: mDensity,
            nDensity: nDensity,
            isClosedInM: (flags & Flag.closedInM) != 0,
            isClosedInN: (flags & Flag.closedInN) != 0,
            curveType: curveType,
            layer: refs.layer,
            firstVertex: first,
            lastVertex: last,
            seqEnd: seq,
            color: header.color
        )
    }
}

/// A decoded VERTEX_MESH (object type 12) — one grid point of a POLYLINE_MESH.
struct DWGVertexMesh {
    let handle: Int
    let point: DWGPoint
    let flags: UInt8

    /// Decodes a VERTEX_MESH, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     RC   flags
    ///     3BD  point
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGVertexMesh {
        let flags = try r.readRC()
        let p = try r.read3BD()
        return DWGVertexMesh(
            handle: header.handle,
            point: DWGPoint(x: p.x, y: p.y, z: p.z),
            flags: flags
        )
    }
}
