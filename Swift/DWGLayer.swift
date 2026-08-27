import Foundation

/// A decoded LAYER table entry (object type 51).
///
/// Layers carry no geometry, but they matter for rendering: entities whose
/// colour is 256 ("ByLayer" — the overwhelmingly common case) take their colour
/// from here, and a frozen or switched-off layer should not be drawn at all.
///
/// Verified against real drawings: names decode as "0", "Defpoints" and
/// "some layer", matching AutoCAD. The plot flag was confirmed by comparing
/// those entries — "Defpoints" is AutoCAD's conventional never-plotted layer and
/// is the only one with the bit clear.
struct DWGLayer {
    let handle: Int
    let name: String
    let isFrozen: Bool
    /// False when the layer is switched off (stored as a negative colour).
    let isOn: Bool
    let isFrozenInNewViewports: Bool
    let isLocked: Bool
    /// False for layers excluded from plotting, e.g. "Defpoints".
    let isPlottable: Bool
    /// AutoCAD Color Index, 1...255 (7 is the default black/white).
    let colorIndex: Int
    /// Encoded lineweight, taken from the upper bits of the flags word.
    let lineweight: Int

    /// Lineweight in hundredths of a millimetre, or a negative value when the
    /// layer defers to the drawing default. Uses the same convention as DXF
    /// group code 370 so both formats can share one renderer.
    var lineWeightHundredthsOfMM: Double {
        DWGLineweight.hundredthsOfMM(fromEncoded: lineweight)
    }

    /// True when entities on this layer should be drawn.
    var isVisible: Bool { isOn && !isFrozen }

    private enum Flag {
        static let frozen             = 0x01
        static let frozenNewViewports = 0x04
        static let locked             = 0x08
        static let plotting           = 0x10
    }

    /// Decodes a LAYER, with the reader positioned immediately after the
    /// common **object** header (not the entity header).
    ///
    ///     TV  entry name
    ///     B   64-flag (an internal bookkeeping bit)
    ///     BS  xref index + 1
    ///     B   xref-dependent flag
    ///     BS  values — frozen / locked / plotting flags, plus lineweight in
    ///         bits 5 and up
    ///     BS  colour — negative means the layer is switched off
    static func parse(_ r: inout DWGBitReader, header: DWGObjectHeader, version: DWGVersion) throws -> DWGLayer {
        // The name is read the same way in every version — but from R2010 the
        // reader has been pointed at the string stream, so `readTV` pulls it
        // from there rather than inline, and the fields below shift accordingly.
        let name = try r.readTV()

        let values: Int
        let rawColor: Int

        if version.usesObjectTypeCode {
            // R2010 trimmed the layer's inline fields. With the name relocated to
            // the string stream, what remains before the flags is just two bits:
            // the 64-flag and the xref-dependent flag. The inline xref-index that
            // earlier versions carried is gone. Reading the old, longer layout
            // here shifts the flags word, its plot bit lands wrong, and every
            // entity on the layer is dropped — the whole drawing renders blank
            // while still reporting the right entity and layer counts.
            _ = try r.readBit()          // 64-flag
            _ = try r.readBit()          // xref dependent
            values = try r.readBS()
            // The colour is a full colour object here rather than a plain index.
            // Only the plot flag matters for whether geometry is drawn, so the
            // index is taken as its ByLayer default rather than decoded in full.
            _ = try r.readBS()           // colour index / flags
            rawColor = 7
        } else {
            _ = try r.readBit()          // 64-flag
            _ = try r.readBS()           // xref index + 1
            _ = try r.readBit()          // xref dependent
            values = try r.readBS()

            // R2004 gained true-colour support and writes an extra colour field
            // ahead of the index — zero in these drawings, which use plain
            // indexed colours. Reading past it takes the placeholder as the
            // colour, so every layer comes out as 0.
            if version != .r2000 {
                _ = try r.readBS()
            }
            rawColor = try r.readBS()
        }

        // A layer should always have a name. If one still comes through empty,
        // fall back to a placeholder rather than discarding the layer — losing
        // it would leave its entities unplottable and blank the drawing, which
        // is a far worse outcome than an oddly-named layer.
        let resolvedName = name.isEmpty ? "layer-\(header.handle)" : name

        return DWGLayer(
            handle: header.handle,
            name: resolvedName,
            isFrozen: (values & Flag.frozen) != 0,
            isOn: rawColor >= 0,
            isFrozenInNewViewports: (values & Flag.frozenNewViewports) != 0,
            isLocked: (values & Flag.locked) != 0,
            isPlottable: (values & Flag.plotting) != 0,
            colorIndex: abs(rawColor),
            lineweight: (values >> 5) & 0x1F
        )
    }
}
