import Foundation

/// The header carried by non-entity **objects** — layers, styles, linetypes,
/// block headers, dictionaries and so on.
///
/// This is deliberately *not* `DWGEntityHeader`. Objects have no graphics flag,
/// entity mode, colour, linetype scale, invisibility or lineweight, so their
/// header is much shorter:
///
///     MS  object size, in bytes
///     BS  object type
///     RL  object size, in bits
///     H   object handle
///     ..  extended entity data: [BS size, H app handle, bytes]… until size 0
///     BL  number of reactors
///
/// Applying the entity header to an object (or vice versa) misaligns every
/// field that follows — that difference is why a naive scan of a DWG shows a
/// large number of objects whose handles appear not to match.
///
/// Verified by decoding real layer tables: the names come out as "0",
/// "Defpoints" and "some layer" exactly as AutoCAD reports them.
struct DWGObjectHeader {
    let objectSize: Int
    let type: Int
    let bitSize: Int
    let handle: Int
    let reactorCount: Int
    /// True when an extension-dictionary handle follows the object's data.
    let hasExtensionDictionary: Bool

    var objectType: DWGObjectType? { DWGObjectType(rawValue: type) }

    static func parse(_ r: inout DWGBitReader, version: DWGVersion) throws -> DWGObjectHeader {
        let objectSize = try r.readMS()
        let dataStartBit = r.bitPosition   // after the size field; bitSize is measured from here

        let type: Int
        let bitSize: Int
        var handleStreamStart = 0
        if version.usesObjectTypeCode {
            // As for entities: R2010 records the handle stream's size rather
            // than its start, and encodes the type as a short code. The size is
            // measured from *after* this size field, so the handle stream — and
            // with it the end of the data — is found from the position after the
            // UMC, not after MS. Measuring from the wrong one lands eight bits
            // short and the string-stream flag reads as absent.
            let handleStreamSize = try r.readUMC()
            let afterPrefix = r.bitPosition
            type = try r.readObjectTypeCode()
            bitSize = objectSize * 8 - handleStreamSize
            handleStreamStart = afterPrefix + bitSize
        } else {
            type = try r.readBS()
            bitSize = Int(try r.readRL())
        }

        // From R2010, activate the object's string stream so that every text
        // field below reads from the tail of the data instead of inline. The
        // data ends where the handle stream begins.
        if version.usesObjectTypeCode {
            try r.activateStringStream(objectStartBit: dataStartBit,
                                       dataEndBit: handleStreamStart)
        }

        let handle = try r.readHandle()

        // Extended entity data — stepped over, not interpreted.
        var chunks = 0
        while true {
            let size = try r.readBS()
            if size == 0 { break }
            guard size > 0, size < 1_000_000 else {
                throw DWGError.malformed("implausible EED chunk size \(size)")
            }
            _ = try r.readHandle()
            try r.skip(bits: size * 8)
            chunks += 1
            guard chunks < 1_000 else {
                throw DWGError.malformed("EED run did not terminate")
            }
        }

        let reactorCount = try r.readBL()
        guard reactorCount >= 0, reactorCount < 100_000 else {
            throw DWGError.malformed("implausible reactor count \(reactorCount)")
        }

        // R2004 records whether an extension dictionary follows. Entities had a
        // bit to spare for this — R2000's "no links" flag, which R2004 stopped
        // needing — but a plain object has no such bit, so one is added here and
        // the header is genuinely a bit longer than R2000's.
        //
        // Getting this wrong does not fail loudly: it shifts everything after by
        // one bit, so a layer decodes with a garbled name and a plot flag of
        // false, and every entity on it is then silently dropped as unplottable.
        // The drawing renders blank while reporting that it parsed fine.
        let hasExtensionDictionary: Bool
        switch version {
        case .r2000:
            hasExtensionDictionary = true
        default:
            hasExtensionDictionary = try r.readBit() == 0
        }

        // R2013 added one more flag bit after the extension-dictionary flag, in
        // objects just as in entities. Missing it shifts the object's body by a
        // bit — a layer's flags land wrong, and its plot bit with them.
        if version.hasExtraObjectFlagBit {
            _ = try r.readBit()
        }

        return DWGObjectHeader(
            objectSize: objectSize,
            type: type,
            bitSize: bitSize,
            handle: handle.value,
            reactorCount: reactorCount,
            hasExtensionDictionary: hasExtensionDictionary
        )
    }
}
