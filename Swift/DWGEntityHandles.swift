import Foundation

/// The handle references that close out every entity, after its geometry.
///
/// This is how a DWG is wired together: an entity doesn't embed its layer or
/// its block — it points at them by handle. Resolving these is what lets us
/// colour an entity by its layer, or find the block an INSERT instantiates.
///
/// The section is *positional*, with no tags: which handles are present depends
/// entirely on flags carried in the entity header. Read them in the wrong order
/// and you get plausible-looking nonsense.
///
///     H   owner            (only when entity mode is 0)
///     H   reactors × the header's reactor count
///     H   extension dictionary
///     H   previous entity  (only when the header has links)
///     H   next entity      (only when the header has links)
///     H   layer
///     H   linetype         (only when linetype flags == 3)
///     H   plotstyle        (only when plotstyle flags == 3)
///
/// Entity-specific handles (such as an INSERT's block header) follow these.
///
/// References may be **relative**: codes 6, 8, 10 and 12 store an offset from
/// the referring object's own handle rather than a handle, so every reference is
/// put through `resolved(against:)`. See `DWGBitReader.Handle`.
///
/// Verified against a real INSERT: the layer resolved to handle 0x10 — the "0"
/// layer — and the next handle was 0x157, the "some block" BLOCK_HEADER, both
/// matching AutoCAD. Verified again on block contents, whose owners are stored
/// relative (e.g. entity 0x187 owner code 12 value 3 → block 0x184).
struct DWGEntityHandles {
    var owner: Int?
    var reactors: [Int] = []
    var extensionDictionary: Int?
    var previousEntity: Int?
    var nextEntity: Int?
    var layer: Int?
    var linetype: Int?
    var plotstyle: Int?

    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGEntityHandles {
        var handles = DWGEntityHandles()
        let self_ = header.handle

        // Go to where the object says its handles are, rather than carrying on
        // from wherever the body finished. The two agree often enough that
        // reading straight on appears to work — every coordinate decodes, and
        // only the references come out as nonsense — so the discrepancy hides
        // until something actually follows a handle somewhere.
        try r.seek(toBit: header.handleStreamStart)

        if header.hasOwnerHandle {
            handles.owner = try r.readHandle().resolved(against: self_)
        }

        for _ in 0..<header.reactorCount {
            if let v = try r.readHandle().resolved(against: self_) {
                handles.reactors.append(v)
            }
        }

        if header.hasExtensionDictionary {
            handles.extensionDictionary = try r.readHandle().resolved(against: self_)
        }

        if header.hasLinks {
            handles.previousEntity = try r.readHandle().resolved(against: self_)
            handles.nextEntity = try r.readHandle().resolved(against: self_)
        }

        handles.layer = try r.readHandle().resolved(against: self_)

        if header.linetypeFlags == 3 {
            handles.linetype = try r.readHandle().resolved(against: self_)
        }
        if header.plotstyleFlags == 3 {
            handles.plotstyle = try r.readHandle().resolved(against: self_)
        }

        return handles
    }
}
