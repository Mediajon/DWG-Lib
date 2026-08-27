import Foundation

/// Reads the file container introduced in R2004 (AC1018).
///
/// R2000 and earlier are flat: the object stream sits in the file and offsets
/// point straight at it. From R2004 a drawing is a small archive instead —
/// obfuscated headers, compressed pages, and a two-level map describing where
/// each named section's pages live. None of that changes what an *object* looks
/// like, so once the two sections below are recovered the existing R2000
/// decoders read them unaltered.
///
/// Validated end to end: `Line.dwg` saved as AC1018 decodes to handle 0x1CA
/// running (21.6078, 2.81192) to (11.0307, 16.6375) — byte-identical to the
/// same drawing saved as AC1015, and to AutoCAD's own property dump.
///
/// The route in is:
///
/// 1. Deobfuscate the 0x6C-byte header at 0x80 and read the page map's address.
/// 2. Decompress the **section page map**: every page's id and size. Pages are
///    laid out end to end from 0x100, so their addresses are the running total.
/// 3. Decompress the **section map**: the named sections and which pages hold
///    them.
/// 4. Concatenate each section's pages, decompressing as needed.
struct DWGR2004Container {

    /// The object stream — what `AcDb:Handles` offsets are relative to.
    let objects: [UInt8]
    /// The object map, in the same format R2000 uses.
    let handles: [UInt8]

    // MARK: - Obfuscation

    /// The file header is XORed with a keystream from a linear congruential
    /// generator. It isn't security — the constants are published — just enough
    /// to stop the header being edited by hand.
    private static func keystream(count: Int) -> [UInt8] {
        var seed: UInt32 = 1
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            seed = seed &* 0x343F_D
            seed = seed &+ 0x269E_C3
            out.append(UInt8((seed >> 0x10) & 0xFF))
        }
        return out
    }

    /// Data pages are masked with a value derived from where the page sits, so
    /// the mask differs for every page and can't be lifted from one and reused.
    private static func dataPageMask(pageAddress: Int) -> UInt32 {
        0x4164_536B ^ UInt32(truncatingIfNeeded: pageAddress)
    }

    private static let systemPageMarker: UInt32 = 0x4163_0E3B   // section page map
    private static let sectionMapMarker: UInt32 = 0x4163_003B   // section map
    private static let dataPageMarker: UInt32 = 0x4163_043B     // ordinary data

    // MARK: - Little-endian scalars

    private static func u32(_ d: [UInt8], _ i: Int) throws -> UInt32 {
        guard i + 4 <= d.count else { throw DWGError.invalidValue("read past end") }
        return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
    }

    private static func u64(_ d: [UInt8], _ i: Int) throws -> UInt64 {
        guard i + 8 <= d.count else { throw DWGError.invalidValue("read past end") }
        var v: UInt64 = 0
        for k in (0..<8).reversed() { v = (v << 8) | UInt64(d[i + k]) }
        return v
    }

    // MARK: - Reading

    static func read(_ data: [UInt8]) throws -> DWGR2004Container {
        guard data.count > 0x100 else { throw DWGError.invalidValue("file too short") }

        // ---- 1. the obfuscated file header ----
        let headerSize = 0x6C
        let key = keystream(count: headerSize)
        var header: [UInt8] = []
        header.reserveCapacity(headerSize)
        for i in 0..<headerSize {
            header.append(data[0x80 + i] ^ key[i])
        }
        guard header.starts(with: Array("AcFssFcAJMB".utf8)) else {
            throw DWGError.invalidValue("R2004 header signature not found")
        }

        // The header is a fixed sequence of 4- and 8-byte fields after the
        // 12-byte identifier, and it is read in order rather than by offset.
        // Only two values are wanted, but several of the fields in between are
        // constants of a similar magnitude — 0x20, 0x80, 0x40 — so an offset
        // that is wrong by one field still reads a plausible number and fails
        // much later, as a nonsensical page address. Walking the fields makes
        // the position self-evident.
        var p = 12
        func rl() throws -> Int { defer { p += 4 }; return Int(try u32(header, p)) }
        func rll() throws -> Int { defer { p += 8 }; return Int(try u64(header, p)) }

        _ = try rl()            // unknown, zero
        _ = try rl()            // header size, 0x6C
        _ = try rl()            // file version, 4
        _ = try rl()            // root tree node gap
        _ = try rl()            // lowermost left tree node gap
        _ = try rl()            // lowermost right tree node gap
        _ = try rl()            // unknown, one
        _ = try rl()            // last section page id
        _ = try rll()           // last section page end address
        _ = try rll()           // second header address
        _ = try rl()            // gap amount
        _ = try rl()            // section page amount
        _ = try rl()            // 0x20
        _ = try rl()            // 0x80
        _ = try rl()            // 0x40
        _ = try rl()            // section page map id
        let sectionPageMapAddress = try rll()
        let sectionMapId = try rl()

        // ---- 2. the section page map ----
        let pageMapAddress = sectionPageMapAddress + 0x100
        let pageMapBytes = try readSystemPage(data, at: pageMapAddress, expecting: systemPageMarker)

        // Pages sit end to end from 0x100, so an address is the running total of
        // everything before it — the map stores sizes, never addresses.
        //
        // A page can also be a gap: space freed when the drawing was edited,
        // marked by a negative page number. Its size still advances the running
        // address, but it names no real page and carries four extra fields — the
        // free-list tree it belongs to (parent, left, right, and a spare) — that
        // must be stepped over. Earlier drawings simply had no gaps, so a reader
        // that assumed none worked until a file that had been edited came along:
        // the gap's size, read as unsigned and added blindly, threw every later
        // page's address past the end of the file.
        var pageAddresses: [Int: (address: Int, size: Int)] = [:]
        var cursor = 0x100
        var i = 0
        while i + 8 <= pageMapBytes.count {
            let number = Int(Int32(bitPattern: try u32(pageMapBytes, i)))
            let size = Int(Int32(bitPattern: try u32(pageMapBytes, i + 4)))
            i += 8

            let span = abs(size)
            if number > 0 {
                pageAddresses[number] = (cursor, span)
            } else {
                // A gap entry: skip its free-list fields (parent, left, right, spare).
                i += 16
            }
            cursor += span
        }

        // ---- 3. the section map ----
        guard let sectionMapPage = pageAddresses[sectionMapId] else {
            throw DWGError.invalidValue("section map page \(sectionMapId) missing")
        }
        let sectionMapBytes = try readSystemPage(data, at: sectionMapPage.address, expecting: sectionMapMarker)
        let sections = try parseSectionMap(sectionMapBytes)

        // ---- 4. the two sections that matter ----
        let objects = try readSection(named: "AcDb:AcDbObjects", from: data, sections: sections, pages: pageAddresses)
        let handles = try readSection(named: "AcDb:Handles", from: data, sections: sections, pages: pageAddresses)

        return DWGR2004Container(objects: objects, handles: handles)
    }

    // MARK: - Pages

    /// Reads one of the two system pages, whose header is in the clear.
    private static func readSystemPage(_ data: [UInt8], at address: Int, expecting marker: UInt32) throws -> [UInt8] {
        guard address + 20 <= data.count else { throw DWGError.invalidValue("page past end of file") }
        let type = try u32(data, address)
        guard type == marker else {
            throw DWGError.invalidValue("page at \(address) is type \(String(type, radix: 16))")
        }
        let decompressedSize = Int(try u32(data, address + 4))
        let compressedSize = Int(try u32(data, address + 8))
        guard address + 20 + compressedSize <= data.count else {
            throw DWGError.invalidValue("page overruns file")
        }
        let payload = Array(data[(address + 20)..<(address + 20 + compressedSize)])
        let out = try DWGR2004Decompressor.decompress(payload, expectedSize: decompressedSize)
        // A trailing match may overrun the target; the declared size is the truth.
        return Array(out.prefix(decompressedSize))
    }

    private struct SectionDescriptor {
        var size: Int
        var maxDecompressedSize: Int
        var isCompressed: Bool
        var pages: [(number: Int, dataSize: Int, startOffset: Int)]
    }

    private static func parseSectionMap(_ d: [UInt8]) throws -> [String: SectionDescriptor] {
        var p = 0
        func rl() throws -> Int { defer { p += 4 }; return Int(try u32(d, p)) }
        func rll() throws -> Int { defer { p += 8 }; return Int(try u64(d, p)) }

        let count = try rl()
        _ = try rl(); _ = try rl(); _ = try rl(); _ = try rl()

        var out: [String: SectionDescriptor] = [:]
        for _ in 0..<count {
            let size = try rll()
            let pageCount = try rl()
            let maxDecompressed = try rl()
            _ = try rl()
            let compressed = try rl()
            _ = try rl()   // section id
            _ = try rl()   // encrypted
            guard p + 64 <= d.count else { throw DWGError.invalidValue("section name past end") }
            let nameBytes = Array(d[p..<(p + 64)]); p += 64
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)

            var pages: [(number: Int, dataSize: Int, startOffset: Int)] = []
            for _ in 0..<pageCount {
                let number = try rl()
                let dataSize = try rl()
                let startOffset = try rll()
                pages.append((number, dataSize, startOffset))
            }
            out[name] = SectionDescriptor(
                size: size,
                maxDecompressedSize: maxDecompressed,
                isCompressed: compressed == 2,
                pages: pages.sorted { $0.startOffset < $1.startOffset }
            )
        }
        return out
    }

    private static func readSection(named name: String,
                                    from data: [UInt8],
                                    sections: [String: SectionDescriptor],
                                    pages: [Int: (address: Int, size: Int)]) throws -> [UInt8] {
        guard let section = sections[name] else {
            throw DWGError.invalidValue("section \(name) missing")
        }
        var out: [UInt8] = []
        out.reserveCapacity(section.size)

        for page in section.pages {
            guard let located = pages[page.number] else {
                throw DWGError.invalidValue("\(name): page \(page.number) missing")
            }
            let address = located.address
            guard address + 32 <= data.count else {
                throw DWGError.invalidValue("\(name): page past end of file")
            }

            // A data page's header is masked; unmasking it also proves the page
            // is the one the map promised.
            let mask = dataPageMask(pageAddress: address)
            let type = try u32(data, address) ^ mask
            let dataSize = Int(try u32(data, address + 8) ^ mask)
            guard type == dataPageMarker else {
                throw DWGError.invalidValue("\(name): page \(page.number) is not a data page")
            }
            guard dataSize == page.dataSize else {
                throw DWGError.invalidValue("\(name): page \(page.number) size disagrees with the map")
            }
            guard address + 32 + dataSize <= data.count else {
                throw DWGError.invalidValue("\(name): page overruns file")
            }

            let payload = Array(data[(address + 32)..<(address + 32 + dataSize)])
            let wanted = min(section.maxDecompressedSize, section.size - page.startOffset)
            let chunk: [UInt8] = section.isCompressed
                ? try DWGR2004Decompressor.decompress(payload, expectedSize: wanted)
                : payload
            guard chunk.count >= wanted else {
                throw DWGError.invalidValue("\(name): page \(page.number) short by \(wanted - chunk.count) bytes")
            }
            out.append(contentsOf: chunk.prefix(wanted))
        }
        return out
    }
}
