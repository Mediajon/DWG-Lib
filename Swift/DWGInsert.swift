import Foundation

/// A decoded INSERT entity (object type 7) — a placed instance of a block.
///
/// Unlike every other entity, an INSERT carries no geometry of its own: it
/// points at a BLOCK_HEADER by handle and supplies a transform. Rendering one
/// means finding that block's contents and drawing them through this
/// translate / scale / rotate.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x160,
/// insertion (25.9113, 56.4789), scales all 1.0, rotation 0, has attributes —
/// and `blockHeader` resolves to 0x157, the "some block" definition.
struct DWGInsert {
    let handle: Int
    let insertionPoint: DWGPoint
    let scale: DWGPoint
    /// Radians, counter-clockwise.
    let rotation: Double
    let extrusion: DWGPoint
    /// True when ATTRIB entities follow this insert.
    let hasAttributes: Bool
    /// Handle of the BLOCK_HEADER being instantiated.
    let blockHeader: Int?
    let layer: Int?
    /// Owner of this insert — the space or block it sits in. Needed to tell
    /// whether the insert is model-space content.
    let owner: Int?
    /// First and last ATTRIB, plus the SEQEND that closes them.
    let firstAttribute: Int?
    let lastAttribute: Int?
    let seqEnd: Int?
    let color: Int

    /// Decodes an INSERT, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  insertion point
    ///     BB   scale flags — the scale is stored in whichever form is smallest:
    ///          `11` all three are 1.0 (nothing stored at all)
    ///          `10` uniform: one RD, reused for Y and Z
    ///          `01` X is 1.0; Y and Z are DDs defaulting to 1.0
    ///          `00` X is an RD; Y and Z are DDs defaulting to X
    ///     BD   rotation
    ///     3BD  extrusion
    ///     B    has attributes
    ///     ..   handle references, then the block header handle
    ///
    /// There is no owned-object count here: that field arrived in R2004, and
    /// reading it against an R2000 file yields garbage.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGInsert {
        let p = try r.read3BD()

        var sx = 1.0, sy = 1.0, sz = 1.0
        switch try r.readBB() {
        case 3:
            break                                   // all 1.0
        case 2:
            sx = try r.readRD(); sy = sx; sz = sx   // uniform
        case 1:
            sx = 1.0
            sy = try r.readDD(default: 1.0)
            sz = try r.readDD(default: 1.0)
        default:
            sx = try r.readRD()
            sy = try r.readDD(default: sx)
            sz = try r.readDD(default: sx)
        }

        let rotation = try r.readBD()
        let e = try r.read3BD()
        let hasAttributes = try r.readBit() == 1

        let refs = try DWGEntityHandles.parse(&r, header: header)
        let blockHeader = try r.readHandle().resolved(against: header.handle)

        var firstAttribute: Int?
        var lastAttribute: Int?
        var seqEnd: Int?
        if hasAttributes {
            firstAttribute = try r.readHandle().resolved(against: header.handle)
            lastAttribute = try r.readHandle().resolved(against: header.handle)
            seqEnd = try r.readHandle().resolved(against: header.handle)
        }

        return DWGInsert(
            handle: header.handle,
            insertionPoint: DWGPoint(x: p.x, y: p.y, z: p.z),
            scale: DWGPoint(x: sx, y: sy, z: sz),
            rotation: rotation,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            hasAttributes: hasAttributes,
            blockHeader: blockHeader,
            layer: refs.layer,
            owner: refs.owner,
            firstAttribute: firstAttribute,
            lastAttribute: lastAttribute,
            seqEnd: seqEnd,
            color: header.color
        )
    }
}
