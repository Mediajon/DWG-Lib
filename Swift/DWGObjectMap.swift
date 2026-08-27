import Foundation

/// The object map: the file's index of every object, mapping each handle to the
/// byte offset where that object's data begins. Nothing else can be located
/// without it, so it is the backbone of the parser.
///
/// Layout (verified against real R2000 files): the section is a run of
/// sub-sections, each one
///
///     RS (big-endian)  size of this sub-section, including its CRC
///     ... repeated:    MC  handle offset   (delta from the previous handle)
///                      MC  location offset (delta from the previous location)
///     RS (big-endian)  CRC
///
/// and a final sub-section of size 2 (a CRC alone) terminates the run.
///
/// Both the handles and the file offsets are stored as *deltas* from the
/// previous entry, which is why the whole index of a 95 KB drawing fits in
/// ~540 bytes. Note the two big-endian shorts: everywhere else in DWG raw
/// integers are little-endian, but the object map's sizes and CRCs are not.
///
/// The two delta streams are encoded differently — handle deltas unsigned,
/// location deltas signed. See `readMC`. With that distinction the decoded
/// handles agree with every object's own self-reported handle across all test
/// files (276/276, 222/222, 336/336).
struct DWGObjectMap {

    /// handle → byte offset of the object's data.
    private(set) var offsets: [Int: Int] = [:]

    /// Entries naming an object that lies outside the stream — deleted objects
    /// the map still lists. Recorded rather than treated as corruption.
    private(set) var staleEntryCount = 0

    var count: Int { offsets.count }
    var handles: [Int] { offsets.keys.sorted() }

    func offset(forHandle handle: Int) -> Int? { offsets[handle] }

    // MARK: - Parsing

    /// Parses an object map that arrives as a section of its own.
    ///
    /// R2000 keeps the map inside the file and points at it with a locator;
    /// R2004 and later store it as a named, compressed section that has already
    /// been extracted by the time it gets here. The bytes are identical in both
    /// cases — only how they're found differs — so this just describes the whole
    /// buffer as the region to read.
    static func parse(mapData: Data, objectDataSize: Int) throws -> DWGObjectMap {
        try parse(
            data: mapData,
            locator: DWGSectionLocator(number: 0, seeker: 0, size: mapData.count),
            objectDataSize: objectDataSize
        )
    }

    /// - Parameter objectDataSize: the size of the buffer the recorded offsets
    ///   point into. In R2000 that is the file itself, so it and the map are the
    ///   same bytes; from R2004 the object stream is a separate section and the
    ///   map's own buffer says nothing about whether an offset is valid. Passing
    ///   it in keeps the map from judging a stream it cannot see.
    static func parse(data: Data, locator: DWGSectionLocator, objectDataSize: Int) throws -> DWGObjectMap {
        var map = DWGObjectMap()
        let bytes = [UInt8](data)
        var p = locator.seeker
        let end = locator.seeker + locator.size

        guard end <= bytes.count else {
            throw DWGError.malformed("object map section runs past the end of the file")
        }

        var lastHandle = 0
        var lastLocation = 0

        while p + 2 <= end {
            // Sub-section size — big-endian, unlike most DWG integers.
            let sectionSize = Int(bytes[p]) << 8 | Int(bytes[p + 1])
            p += 2

            // A sub-section holding nothing but a CRC ends the map.
            if sectionSize <= 2 { break }

            let stop = p + sectionSize - 2
            guard stop <= end else {
                throw DWGError.malformed("object map sub-section overruns the section")
            }

            while p < stop {
                let (handleDelta, p1) = try readMC(bytes, p, limit: stop, signed: false)
                let (locationDelta, p2) = try readMC(bytes, p1, limit: stop, signed: true)
                p = p2
                lastHandle += handleDelta
                lastLocation += locationDelta

                // A real drawing can carry a stale entry — a handle whose object
                // was deleted, still listed, pointing off the end of the stream.
                // The deltas are a running chain, so the entry is dropped while
                // the position keeps accumulating: the next object is described
                // relative to this one whether or not this one exists. Refusing
                // the whole file over it would discard several hundred perfectly
                // good objects for the sake of one that isn't there.
                guard lastLocation >= 0, lastLocation < objectDataSize else {
                    map.staleEntryCount += 1
                    continue
                }
                map.offsets[lastHandle] = lastLocation
            }

            p += 2   // sub-section CRC
        }

        guard !map.offsets.isEmpty else {
            throw DWGError.malformed("object map is empty")
        }
        return map
    }

    /// Modular char, byte-aligned (as used in the object map).
    /// Seven data bits per byte; the high bit continues the value.
    ///
    /// The two delta streams differ, and getting this wrong is subtle:
    ///
    /// - **Handle deltas are unsigned.** Handles only ever increase, so there is
    ///   no sign bit and bit 6 is ordinary data.
    /// - **Location deltas are signed**, because objects are not laid out in
    ///   handle order and an offset may jump backwards. Here bit 6 of the final
    ///   byte marks a negative value.
    ///
    /// Reading handle deltas as signed corrupts any delta with bit 6 set — the
    /// running handle then drifts by a fixed amount for the rest of the file,
    /// so objects are filed under the wrong handles (and entities appear to go
    /// missing) while their offsets still look perfectly valid.
    private static func readMC(_ bytes: [UInt8], _ start: Int, limit: Int, signed: Bool) throws -> (Int, Int) {
        var value = 0
        var shift = 0
        var p = start
        for _ in 0..<5 {
            guard p < limit else { throw DWGError.malformed("modular char runs past sub-section") }
            let byte = bytes[p]
            p += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                if signed, byte & 0x40 != 0 {
                    value &= ~(0x40 << shift)
                    return (-value, p)
                }
                return (value, p)
            }
            shift += 7
        }
        throw DWGError.malformed("modular char longer than 5 bytes")
    }
}
