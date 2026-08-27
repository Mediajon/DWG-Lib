import Foundation

/// The header every entity carries before its type-specific data.
///
/// Verified field-by-field against real R2000 files: for a plain LINE this
/// header occupies exactly 108 bits, and every value matched AutoCAD's own
/// property dump for the same object (handle, colour, linetype scale…).
///
///     MS  object size, in bytes
///     BS  object type
///     RL  object size, in bits
///     H   object handle
///     ..  extended entity data: [BS size, H app handle, bytes]… until size 0
///     B   graphics-present flag  (if set: RL bit-length + that many bits)
///     BB  entity mode
///     BL  number of reactors
///     B   "no links" flag
///     BS  entity colour (256 = ByLayer)
///     BD  linetype scale
///     BB  linetype flags
///     BB  plotstyle flags
///     BS  invisibility
///     RC  lineweight
///
/// Every field here is fixed-order and most are variable-width, so a single
/// misread shifts everything after it. That's why unsupported constructs throw
/// rather than being skipped silently.
struct DWGEntityHeader {

    /// Flags carried in R2004's raw colour value.
    private enum Color {
        /// A packed RGB value follows the colour.
        static let trueColorFollows = 0x2000
        /// The other true-colour form (R2013 on): a packed RGB value follows,
        /// its high byte carrying the colour method (0xC2 = ByColor). Real
        /// exporters — Affinity, Illustrator — write colours this way rather
        /// than as ByLayer, so this is the common case in files from the wild,
        /// not an edge case.
        static let rgbColorFollows = 0x8000
    }

    let objectSize: Int
    let type: Int
    let bitSize: Int
    /// Absolute bit position at which this object's handle references begin.
    ///
    /// `bitSize` measures the object's data — everything except the handles —
    /// from just after the leading size field, so the handle stream starts at a
    /// position the object states outright rather than wherever the body happens
    /// to finish. Those two coincide often enough that reading straight on works
    /// by luck, and then a decoder that trusts luck reads an entity's geometry
    /// perfectly and its layer as nonsense.
    let handleStreamStart: Int
    let handle: Int
    let entityMode: UInt8
    let reactorCount: Int
    /// True when previous/next entity handles are written. R2000 records them;
    /// R2004 dropped them.
    let hasLinks: Bool
    /// True when an extension-dictionary handle is written.
    ///
    /// R2000 always writes one, null if unused. R2004 writes it only when it
    /// exists, and reuses R2000's "no links" bit to say so — the layout is
    /// byte-for-byte identical, but that one bit answers a different question
    /// about a different handle. Reading it the old way costs nothing until
    /// something follows a reference: the geometry decodes perfectly and every
    /// entity claims a layer that doesn't exist.
    let hasExtensionDictionary: Bool
    let color: Int
    let linetypeScale: Double
    /// 3 means an explicit linetype handle follows in the handle section.
    let linetypeFlags: UInt8
    /// 3 means an explicit plotstyle handle follows in the handle section.
    let plotstyleFlags: UInt8
    let invisibility: Int
    let lineweight: UInt8

    var objectType: DWGObjectType? { DWGObjectType(rawValue: type) }
    var isByLayerColor: Bool { color == 256 }
    var isVisible: Bool { invisibility == 0 }
    /// True when the entity stores its owner explicitly.
    var hasOwnerHandle: Bool { entityMode == 0 }

    static func parse(_ r: inout DWGBitReader, version: DWGVersion) throws -> DWGEntityHeader {
        let objectSize = try r.readMS()
        // `bitSize` is measured from here — after the size field, before the type.
        let dataStart = r.bitPosition

        let type: Int
        let bitSize: Int
        let handleStreamStart: Int

        if version.usesObjectTypeCode {
            // R2010 states how *large* the handle stream is instead of where it
            // begins, and puts it at the end of the object's declared bytes. The
            // information is the same as R2004's bit-size, measured from the
            // other end — which is why looking for a start position here finds
            // nothing that holds up across entities.
            let handleStreamSize = try r.readUMC()
            let afterPrefix = r.bitPosition
            type = try r.readObjectTypeCode()
            bitSize = objectSize * 8 - handleStreamSize
            handleStreamStart = afterPrefix + bitSize
        } else {
            type = try r.readBS()
            bitSize = Int(try r.readRL())
            handleStreamStart = dataStart + bitSize
        }

        // From R2010, text fields read from the string stream at the tail of
        // the data rather than inline — see DWGObjectHeader for the layout.
        if version.usesObjectTypeCode {
            try r.activateStringStream(objectStartBit: dataStart,
                                       dataEndBit: handleStreamStart)
        }

        let handle = try r.readHandle()

        // Extended entity data: application-specific blobs attached to the
        // entity. We don't interpret them, but we must step over them exactly,
        // since everything after is variable-width. The run is a sequence of
        // [BS size, H application handle, `size` bytes], ending at size == 0.
        var eedChunks = 0
        while true {
            let size = try r.readBS()
            if size == 0 { break }
            guard size > 0, size < 1_000_000 else {
                throw DWGError.malformed("implausible EED chunk size \(size)")
            }
            _ = try r.readHandle()              // application handle
            try r.skip(bits: size * 8)
            eedChunks += 1
            guard eedChunks < 1_000 else {
                throw DWGError.malformed("EED run did not terminate")
            }
        }

        // Proxy graphics: a cached image of the entity we don't need, but whose
        // length we must step over exactly.
        if try r.readBit() == 1 {
            let graphicsBits = Int(try r.readRL())
            guard graphicsBits >= 0, graphicsBits <= r.bitsRemaining else {
                throw DWGError.malformed("implausible proxy-graphics length \(graphicsBits)")
            }
            try r.skip(bits: graphicsBits)
        }

        let entityMode = try r.readBB()
        let reactorCount = try r.readBL()
        guard reactorCount >= 0, reactorCount < 100_000 else {
            throw DWGError.malformed("implausible reactor count \(reactorCount)")
        }

        // One bit, two meanings, decided by version — see `hasExtensionDictionary`.
        let flag = try r.readBit() == 1
        let hasLinks: Bool
        let hasExtensionDictionary: Bool
        switch version {
        case .r2000:
            hasLinks = !flag                 // the bit says "no links"
            hasExtensionDictionary = true    // always written, null when unused
        default:
            hasLinks = false                 // not written from R2004 on
            hasExtensionDictionary = !flag   // the bit says "no extension dictionary"
        }

        // R2013 added one more flag bit here, before the colour.
        if version.hasExtraObjectFlagBit {
            _ = try r.readBit()
        }
        // R2004 gained true colour. The colour is no longer a plain index: it is
        // a raw value whose flag bits say what follows, and 0x2000 means an RGB
        // value comes next. An entity using ByLayer never sets it, so a drawing
        // of simple shapes decodes perfectly and hides this completely — but a
        // drawing with blocks and explicit colours sets it on most entities, and
        // then every coordinate after it is read from the wrong bits. The result
        // is not an error: it is a valid double of about 1e300, which stretches
        // the drawing's bounds so far that the real geometry collapses to
        // nothing and the page renders blank.
        let color = try r.readBS()
        if version != .r2000, (color & Color.rgbColorFollows) != 0 {
            _ = try r.readBL()          // packed RGB (method byte in the high byte)
        }
        if version != .r2000, (color & Color.trueColorFollows) != 0 {
            // A second flag, independent of the RGB one, for a colour handle or
            // transparency reference. Some entities (hatches from real exporters)
            // set both at once, so this is read in addition to the RGB above, not
            // as an alternative to it — treating them as mutually exclusive leaves
            // one field unread and the geometry that follows misaligned.
            _ = try r.readBL()
        }
        let linetypeScale = try r.readBD()
        let linetypeFlags = try r.readBB()
        let plotstyleFlags = try r.readBB()

        // R2007 gave every entity a material and a shadow mode; R2010 added
        // three flags for visual styles. They are read only to step over them —
        // but they must be stepped over, or the invisibility and lineweight that
        // follow are read from the wrong bits.
        if version.hasMaterialAndShadowFlags {
            _ = try r.readBB()          // material flags
            _ = try r.readRC()          // shadow flags
        }
        if version.hasVisualStyleFlags {
            _ = try r.readBit()         // full visual style
            _ = try r.readBit()         // face visual style
            _ = try r.readBit()         // edge visual style
        }
        let invisibility = try r.readBS()
        let lineweight = try r.readRC()

        return DWGEntityHeader(
            objectSize: objectSize,
            type: type,
            bitSize: bitSize,
            handleStreamStart: handleStreamStart,
            handle: handle.value,
            entityMode: entityMode,
            reactorCount: reactorCount,
            hasLinks: hasLinks,
            hasExtensionDictionary: hasExtensionDictionary,
            color: color,
            linetypeScale: linetypeScale,
            linetypeFlags: linetypeFlags,
            plotstyleFlags: plotstyleFlags,
            invisibility: invisibility,
            lineweight: lineweight
        )
    }
}
