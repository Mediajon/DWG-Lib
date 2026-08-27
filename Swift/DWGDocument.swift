import Foundation

/// A parsed DWG drawing: layers, block definitions and entities.
///
/// This is the top of the parser and the only type callers need. It walks the
/// object map, dispatches each object to its decoder, and collects the results.
/// It performs no rendering and holds no drawing state — turning this into
/// pixels is a separate concern.
///
/// **Resilience.** A DWG is a bag of independently-addressed objects, so one
/// unreadable object need not spoil the file. Each is decoded in isolation and
/// failures are counted in `skippedObjectCount` rather than thrown, so a
/// drawing with an odd proxy entity still opens. Errors that make the *file*
/// unreadable — wrong version, bad header, missing object map — still throw.
struct DWGDocument {

    let version: DWGVersion
    /// The section-locator header, which only R2000 has: from R2004 the file is
    /// a container of named sections instead, so there is nothing equivalent to
    /// keep.
    let fileHeader: DWGFileHeader?

    /// handle → layer
    let layers: [Int: DWGLayer]
    /// handle → block definition
    let blocks: [Int: DWGBlockHeader]
    /// handle → VERTEX_2D, kept aside so a POLYLINE_2D can resolve its run.
    let vertices: [Int: DWGVertex2D]
    /// handle → VERTEX_MESH, likewise for POLYLINE_MESH.
    let meshVertices: [Int: DWGVertexMesh]
    /// handle → VERTEX_3D, likewise for POLYLINE_3D.
    let vertices3D: [Int: DWGVertex3D]
    /// handle → MLINESTYLE, giving an MLINE its parallel line offsets.
    let mlineStyles: [Int: DWGMLineStyle]

    /// Every decoded entity, in handle order.
    let records: [DWGEntityRecord]

    /// Objects that could not be decoded (unsupported or malformed).
    let skippedObjectCount: Int

    // MARK: - Parsing

    static func parse(contentsOf url: URL) throws -> DWGDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> DWGDocument {
        guard let version = DWGVersion.detect(from: data) else {
            throw DWGError.malformed("not a DWG file")
        }

        // How the object stream is *stored* changed in R2004; what an object
        // looks like did not. R2000 keeps the stream in the file and points at
        // it with a locator, while R2004 wraps it in compressed, obfuscated
        // pages that have to be reassembled first. Recovering the same two
        // buffers here lets everything below decode a drawing of either vintage
        // without knowing which it came from.
        let objectData: Data
        let map: DWGObjectMap
        var header: DWGFileHeader?

        switch version {
        case .r2000:
            let fileHeader = try DWGFileHeader.parse(data)
            guard let locator = fileHeader.locator(.objectMap) else {
                throw DWGError.malformed("file has no object map")
            }
            map = try DWGObjectMap.parse(data: data, locator: locator, objectDataSize: data.count)
            objectData = data
            header = fileHeader

        case .r2004, .r2010, .r2013, .r2018:
            // R2010 and later reuse R2004's container — only the objects inside
            // describe themselves differently, and from R2013 the page map may
            // carry gap entries the container now skips. R2007 is deliberately
            // absent: it has a container of its own that nothing else shares.
            let container = try DWGR2004Container.read([UInt8](data))
            objectData = Data(container.objects)
            map = try DWGObjectMap.parse(mapData: Data(container.handles),
                                         objectDataSize: objectData.count)

        default:
            throw DWGError.unsupportedVersion(version.displayName)
        }

        var layers: [Int: DWGLayer] = [:]
        var blocks: [Int: DWGBlockHeader] = [:]
        var vertices: [Int: DWGVertex2D] = [:]
        var meshVertices: [Int: DWGVertexMesh] = [:]
        var vertices3D: [Int: DWGVertex3D] = [:]
        var mlineStyles: [Int: DWGMLineStyle] = [:]
        var records: [DWGEntityRecord] = []
        var skipped = 0

        for handle in map.handles {
            guard let offset = map.offset(forHandle: handle) else { continue }
            do {
                try decodeObject(
                    data: objectData,
                    offset: offset,
                    version: version,
                    layers: &layers,
                    blocks: &blocks,
                    vertices: &vertices,
                    meshVertices: &meshVertices,
                    vertices3D: &vertices3D,
                    mlineStyles: &mlineStyles,
                    records: &records
                )
            } catch {
                skipped += 1
            }
        }

        return DWGDocument(
            version: version,
            fileHeader: header,
            layers: layers,
            blocks: blocks,
            vertices: vertices,
            meshVertices: meshVertices,
            vertices3D: vertices3D,
            mlineStyles: mlineStyles,
            records: records,
            skippedObjectCount: skipped
        )
    }

    /// Decodes one object. Objects and entities carry different headers, so the
    /// type is peeked first and the object is then re-read with the right one.
    private static func decodeObject(
        data: Data,
        offset: Int,
        version: DWGVersion,
        layers: inout [Int: DWGLayer],
        blocks: inout [Int: DWGBlockHeader],
        vertices: inout [Int: DWGVertex2D],
        meshVertices: inout [Int: DWGVertexMesh],
        vertices3D: inout [Int: DWGVertex3D],
        mlineStyles: inout [Int: DWGMLineStyle],
        records: inout [DWGEntityRecord]
    ) throws {
        // Peek the type before committing to an entity or object path. How the
        // type is written depends on the version: R2010 slipped a handle-stream
        // size in ahead of it and turned the type itself into a short code, so
        // reading it the R2004 way there yields nonsense and every object is
        // silently dropped — a whole drawing decodes to nothing at all.
        var probe = DWGBitReader(data)
        try probe.seek(toByte: offset)
        _ = try probe.readMS()
        let rawType: Int
        if version.usesObjectTypeCode {
            _ = try probe.readUMC()             // handle-stream size, skipped here
            rawType = try probe.readObjectTypeCode()
        } else {
            rawType = try probe.readBS()
        }

        // Types we don't model — class-defined objects (500+), dictionaries,
        // styles and so on — are skipped silently. They aren't failures, so
        // counting them would make the diagnostic meaningless.
        guard let type = DWGObjectType(rawValue: rawType) else { return }

        var r = DWGBitReader(data)
        try r.seek(toByte: offset)

        switch type {
        // ---- Table objects: the shorter, non-entity header ----
        case .layer:
            let header = try DWGObjectHeader.parse(&r, version: version)
            layers[header.handle] = try DWGLayer.parse(&r, header: header, version: version)

        case .blockHeader:
            let header = try DWGObjectHeader.parse(&r, version: version)
            blocks[header.handle] = try DWGBlockHeader.parse(&r, header: header)

        case .mlinestyle:
            let header = try DWGObjectHeader.parse(&r, version: version)
            mlineStyles[header.handle] = try DWGMLineStyle.parse(&r, header: header)

        // ---- Entities ----
        case .line, .circle, .arc, .point, .lwpolyline, .polyline2D, .vertex2D,
             .text, .mtext, .ellipse, .spline, .ray, .xline, .hatch, .insert, .seqend,
             .face3D, .solid, .trace, .polylineMesh, .vertexMesh,
             .polyline3D, .vertex3D, .mline, .leader:
            let header = try DWGEntityHeader.parse(&r, version: version)
            let (entity, refs) = try decodeEntity(type: type, reader: &r, header: header, version: version)

            if case let .vertex2D(v) = entity {
                vertices[header.handle] = v
            }
            if case let .vertexMesh(v) = entity {
                meshVertices[header.handle] = v
            }
            if case let .vertex3D(v) = entity {
                vertices3D[header.handle] = v
            }

            records.append(DWGEntityRecord(
                handle: header.handle,
                entity: entity,
                layerHandle: refs.layer,
                ownerHandle: refs.owner,
                entityMode: header.entityMode,
                color: header.color,
                lineweight: header.lineweight
            ))

        default:
            return          // a real object, but not one we render
        }
    }

    /// Decodes an entity's body and its handle references.
    ///
    /// Most decoders read only their own geometry and leave the reader at the
    /// handle section, which is read here. INSERT and POLYLINE_2D are the
    /// exceptions: they carry extra handles *after* the common ones, so they
    /// consume the section themselves and report what they found.
    private static func decodeEntity(
        type: DWGObjectType,
        reader r: inout DWGBitReader,
        header: DWGEntityHeader,
        version: DWGVersion
    ) throws -> (DWGEntity, DWGEntityHandles) {

        switch type {
        case .insert:
            let e = try DWGInsert.parse(&r, header: header)
            var refs = DWGEntityHandles()
            refs.layer = e.layer
            refs.owner = e.owner
            return (.insert(e), refs)

        case .polyline2D:
            let e = try DWGPolyline2D.parse(&r, header: header)
            var refs = DWGEntityHandles()
            refs.layer = e.layer
            return (.polyline2D(e), refs)

        case .polylineMesh:
            let e = try DWGPolylineMesh.parse(&r, header: header)
            var refs = DWGEntityHandles()
            refs.layer = e.layer
            return (.polylineMesh(e), refs)

        case .polyline3D:
            let e = try DWGPolyline3D.parse(&r, header: header)
            var refs = DWGEntityHandles()
            refs.layer = e.layer
            return (.polyline3D(e), refs)

        case .mline:
            let e = try DWGMLine.parse(&r, header: header)
            var refs = DWGEntityHandles()
            refs.layer = e.layer
            return (.mline(e), refs)

        case .seqend:
            let refs = try DWGEntityHandles.parse(&r, header: header)
            return (.seqEnd, refs)

        default:
            let entity: DWGEntity
            switch type {
            case .line:       entity = .line(try DWGLine.parse(&r, header: header))
            case .circle:     entity = .circle(try DWGCircle.parse(&r, header: header))
            case .arc:        entity = .arc(try DWGArc.parse(&r, header: header))
            case .point:      entity = .point(try DWGPointEntity.parse(&r, header: header))
            case .lwpolyline: entity = .lwpolyline(try DWGLWPolyline.parse(&r, header: header))
            case .vertex2D:   entity = .vertex2D(try DWGVertex2D.parse(&r, header: header))
            case .text:       entity = .text(try DWGText.parse(&r, header: header))
            case .mtext:      entity = .mtext(try DWGMText.parse(&r, header: header, version: version))
            case .ellipse:    entity = .ellipse(try DWGEllipse.parse(&r, header: header))
            case .spline:     entity = .spline(try DWGSpline.parse(&r, header: header, version: version))
            case .ray:        entity = .infiniteLine(try DWGInfiniteLine.parse(&r, header: header, kind: .ray))
            case .xline:      entity = .infiniteLine(try DWGInfiniteLine.parse(&r, header: header, kind: .xline))
            case .hatch:      entity = .hatch(try DWGHatch.parse(&r, header: header, version: version))
            case .face3D:     entity = .face3D(try DWG3DFace.parse(&r, header: header))
            case .solid:      entity = .solid(try DWGSolid.parse(&r, header: header, kind: .solid))
            case .trace:      entity = .solid(try DWGSolid.parse(&r, header: header, kind: .trace))
            case .vertexMesh: entity = .vertexMesh(try DWGVertexMesh.parse(&r, header: header))
            case .vertex3D:   entity = .vertex3D(try DWGVertex3D.parse(&r, header: header))
            case .leader:     entity = .leader(try DWGLeader.parse(&r, header: header))
            default:
                throw DWGError.invalidValue("no decoder for \(type)")
            }
            let refs = try DWGEntityHandles.parse(&r, header: header)
            return (entity, refs)
        }
    }

    // MARK: - Queries

    /// Entities that belong to the drawing itself rather than to a block
    /// definition, and that represent something drawable.
    var modelSpaceRecords: [DWGEntityRecord] {
        records.filter { $0.isModelSpace && $0.entity.isDrawable }
    }

    /// Entities owned by a given block definition — the contents an INSERT
    /// should draw.
    func records(ownedBy blockHandle: Int) -> [DWGEntityRecord] {
        records.filter { $0.ownerHandle == blockHandle && $0.entity.isDrawable }
    }

    /// The geometry that makes up the drawing's dimensions.
    ///
    /// AutoCAD pre-renders every dimension — its lines, arrowheads and text —
    /// into an anonymous block named `*D…`, and the DIMENSION entity itself just
    /// points at that block. Crucially, this geometry is defined in **world
    /// coordinates** with a zero base point, so drawing the block's contents
    /// directly reproduces the dimension exactly, with no need to interpret
    /// dimension semantics or measure anything.
    ///
    /// Table blocks (`*T…`) are deliberately excluded: their contents are laid
    /// out relative to the table's own origin and need the insertion point from
    /// the ACAD_TABLE entity, which we don't decode — drawing them directly
    /// would stack them at the origin.
    var dimensionRecords: [DWGEntityRecord] {
        // AutoCAD names its pre-rendered dimension blocks `*D` followed by a
        // number — the `*` prefix is its anonymous-block convention. The parsed
        // "anonymous" flag can't be relied on here (some R2013 files leave it
        // clear on blocks that are plainly anonymous by name), so the name
        // prefix is the signal: a block called `*D…` is a dimension block.
        let dimensionBlocks = Set(
            blocks.values
                .filter { $0.name.hasPrefix("*D") }
                .map(\.handle)
        )
        guard !dimensionBlocks.isEmpty else { return [] }
        return records.filter { record in
            guard let owner = record.ownerHandle, dimensionBlocks.contains(owner) else { return false }
            return record.entity.isDrawable
        }
    }

    func layer(forHandle handle: Int?) -> DWGLayer? {
        guard let handle else { return nil }
        return layers[handle]
    }

    /// Name of a block, for renderers that key blocks by name.
    func blockName(forHandle handle: Int?) -> String? {
        guard let handle else { return nil }
        return blocks[handle]?.name
    }

    /// The VERTEX_2D objects belonging to a POLYLINE_2D, in order. The polyline
    /// stores only the first and last handles; the run in between is contiguous.
    func vertices(of polyline: DWGPolyline2D) -> [DWGVertex2D] {
        guard let first = polyline.firstVertex, let last = polyline.lastVertex, first <= last else {
            return []
        }
        return (first...last).compactMap { vertices[$0] }
    }

    /// The VERTEX_MESH objects of a POLYLINE_MESH, in row-major order.
    func vertices(of mesh: DWGPolylineMesh) -> [DWGVertexMesh] {
        guard let first = mesh.firstVertex, let last = mesh.lastVertex, first <= last else {
            return []
        }
        return (first...last).compactMap { meshVertices[$0] }
    }

    /// The VERTEX_3D objects belonging to a POLYLINE_3D, in order.
    func vertices(of polyline: DWGPolyline3D) -> [DWGVertex3D] {
        guard let first = polyline.firstVertex, let last = polyline.lastVertex, first <= last else {
            return []
        }
        return (first...last).compactMap { vertices3D[$0] }
    }

    /// The MLINESTYLE an MLINE refers to, if it was decoded.
    func mlineStyle(forHandle handle: Int?) -> DWGMLineStyle? {
        guard let handle else { return nil }
        return mlineStyles[handle]
    }

    /// Effective colour index for an entity, resolving ByLayer through the
    /// layer table. Returns 7 (the default) when nothing else applies.
    func resolvedColorIndex(for record: DWGEntityRecord) -> Int {
        if !record.isByLayerColor { return record.color }
        if let layer = layer(forHandle: record.layerHandle) { return layer.colorIndex }
        return 7
    }

    /// Diagnostic summary, handy while developing.
    var debugSummary: String {
        var counts: [String: Int] = [:]
        for r in records where r.isModelSpace {
            counts[r.entity.typeName, default: 0] += 1
        }
        var s = "DWG \(version.displayName)"
        s += "\n  layers: \(layers.count), blocks: \(blocks.count)"
        s += "\n  entities: \(records.count) total, \(modelSpaceRecords.count) in model space"
        s += "\n  dimension geometry: \(dimensionRecords.count) entities"
        s += "\n  skipped objects: \(skippedObjectCount)"
        s += "\n  model space contents:"
        for key in counts.keys.sorted() {
            s += "\n    \(counts[key]!) × \(key)"
        }
        return s
    }
}
