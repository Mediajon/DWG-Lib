import Foundation

/// A decoded MTEXT entity (object type 44) — multi-line, word-wrapped text.
/// Far more common than plain TEXT in real drawings.
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x229,
/// insertion (28.6865, 0.305266), height 0.2, rectangle width 7.34694,
/// attachment 1, drawing direction 5, string "tsome text".
///
/// Note MTEXT has no rotation field: the text's direction comes from the
/// `xAxisDirection` vector, so rotation is `atan2(y, x)` of that vector.
struct DWGMText {

    /// Where `insertionPoint` sits relative to the text block.
    enum Attachment: Int {
        case topLeft = 1, topCenter = 2, topRight = 3
        case middleLeft = 4, middleCenter = 5, middleRight = 6
        case bottomLeft = 7, bottomCenter = 8, bottomRight = 9
    }

    let handle: Int
    let insertionPoint: DWGPoint
    let extrusion: DWGPoint
    /// Direction of the text's local X axis; encodes rotation.
    let xAxisDirection: DWGPoint
    /// Width of the wrapping rectangle. 0 means no wrapping.
    let rectangleWidth: Double
    let textHeight: Double
    let attachment: Attachment
    /// 1 = left-to-right, 3 = top-to-bottom, 5 = by style.
    let drawingDirection: Int
    let extentsHeight: Double
    let extentsWidth: Double
    /// The raw string, which may contain MTEXT formatting codes such as
    /// `\P` (paragraph break) or `{\fArial|b1;…}` (inline font runs).
    let text: String
    /// 1 = at least, 2 = exact.
    let lineSpacingStyle: Int
    let lineSpacingFactor: Double
    let color: Int

    /// Rotation in radians, derived from the x-axis direction vector.
    var rotation: Double { atan2(xAxisDirection.y, xAxisDirection.x) }

    /// Decodes an MTEXT, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  insertion point
    ///     3BD  extrusion
    ///     3BD  x-axis direction
    ///     BD   rectangle width
    ///     BD   text height
    ///     BS   attachment
    ///     BS   drawing direction
    ///     BD   extents height
    ///     BD   extents width
    ///     TV   the string
    ///     BS   line-spacing style
    ///     BD   line-spacing factor
    ///     B    unused, but must be consumed
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader, version: DWGVersion) throws -> DWGMText {
        let ins = try r.read3BD()
        let e = try r.read3BD()
        let xdir = try r.read3BD()
        let rectangleWidth = try r.readBD()

        // R2007 added a rectangle *height* alongside the existing width. Missing
        // it makes `textHeight` read the height field instead — which is zero for
        // a single-line box — and a zero text height collapses the entity's
        // bounds to a point, so a drawing whose only content is one MTEXT renders
        // as an empty page while still reporting that it parsed an entity.
        if version.hasMaterialAndShadowFlags {
            _ = try r.readBD()          // rectangle height
        }

        let textHeight = try r.readBD()
        let attachmentRaw = try r.readBS()
        let drawingDirection = try r.readBS()
        let extentsHeight = try r.readBD()
        let extentsWidth = try r.readBD()
        let text = try r.readTV()
        let lineSpacingStyle = try r.readBS()
        let lineSpacingFactor = try r.readBD()
        // One further bit closes the record. Its meaning isn't needed, but it
        // must be consumed: skipping it leaves the reader a single bit short of
        // the handle section, so every reference an MTEXT makes — its layer, and
        // its owner — decodes as plausible nonsense. Confirmed against a drawing
        // whose dimension labels only resolve to their parent blocks with it.
        _ = try r.readBit()

        guard textHeight.isFinite, textHeight >= 0 else {
            throw DWGError.invalidValue("mtext height \(textHeight)")
        }

        return DWGMText(
            handle: header.handle,
            insertionPoint: DWGPoint(x: ins.x, y: ins.y, z: ins.z),
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            xAxisDirection: DWGPoint(x: xdir.x, y: xdir.y, z: xdir.z),
            rectangleWidth: rectangleWidth,
            textHeight: textHeight,
            attachment: Attachment(rawValue: attachmentRaw) ?? .topLeft,
            drawingDirection: drawingDirection,
            extentsHeight: extentsHeight,
            extentsWidth: extentsWidth,
            text: text,
            lineSpacingStyle: lineSpacingStyle,
            lineSpacingFactor: lineSpacingFactor,
            color: header.color
        )
    }
}
