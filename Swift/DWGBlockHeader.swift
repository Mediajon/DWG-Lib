import Foundation

/// A decoded BLOCK_HEADER table entry (object type 49) — a block *definition*.
///
/// Every drawing has at least `*Model_Space` and `*Paper_Space`: the entities
/// you see are owned by those blocks, so block headers are the root of the
/// drawing's structure, not just a feature for reusable symbols.
///
/// Verified against a real drawing, where the table decoded as `*Model_Space`,
/// `*Paper_Space` (twice), `some block` (correctly flagged as having
/// attributes, matching the INSERT that references it), and several `*D`/`*T`
/// entries correctly flagged anonymous — AutoCAD's internal blocks for
/// dimensions and tables.
struct DWGBlockHeader {
    let handle: Int
    let name: String
    /// True for AutoCAD-generated blocks named `*D…`, `*T…` and similar.
    let isAnonymous: Bool
    let hasAttributes: Bool
    let isExternalReference: Bool
    let isOverlaidReference: Bool
    let isLoaded: Bool
    /// Origin the block's geometry is defined around; an INSERT places this
    /// point at its insertion point.
    let basePoint: DWGPoint
    /// Path for an external reference; empty for a normal block.
    let xrefPath: String

    /// True for the model or paper space pseudo-blocks that hold the drawing's
    /// own entities.
    var isLayoutBlock: Bool { name.hasPrefix("*Model_Space") || name.hasPrefix("*Paper_Space") }

    /// Decodes a BLOCK_HEADER, with the reader positioned immediately after the
    /// common **object** header.
    ///
    ///     TV   entry name
    ///     B    64-flag
    ///     BS   xref index + 1
    ///     B    xref dependent
    ///     B    anonymous
    ///     B    has attributes
    ///     B    is an xref
    ///     B    xref overlaid
    ///     B    loaded
    ///     3BD  base point
    ///     TV   xref path name
    static func parse(_ r: inout DWGBitReader, header: DWGObjectHeader) throws -> DWGBlockHeader {
        let name = try r.readTV()
        _ = try r.readBit()          // 64-flag
        _ = try r.readBS()           // xref index + 1
        _ = try r.readBit()          // xref dependent

        let isAnonymous = try r.readBit() == 1
        let hasAttributes = try r.readBit() == 1
        let isXref = try r.readBit() == 1
        let isOverlaid = try r.readBit() == 1
        let isLoaded = try r.readBit() == 1

        let base = try r.read3BD()
        let xrefPath = try r.readTV()

        guard !name.isEmpty else {
            throw DWGError.malformed("block header with an empty name")
        }

        return DWGBlockHeader(
            handle: header.handle,
            name: name,
            isAnonymous: isAnonymous,
            hasAttributes: hasAttributes,
            isExternalReference: isXref,
            isOverlaidReference: isOverlaid,
            isLoaded: isLoaded,
            basePoint: DWGPoint(x: base.x, y: base.y, z: base.z),
            xrefPath: xrefPath
        )
    }
}
