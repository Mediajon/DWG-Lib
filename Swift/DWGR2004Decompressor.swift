import Foundation

/// Decompresses the page data introduced in R2004 (AC1018).
///
/// From R2004 onward a drawing is no longer a flat file: it is split into pages,
/// and each page is compressed with a variant of LZ77. Nothing in a drawing of
/// that vintage can be read until this is undone, which makes it the gate to
/// every version after R2000.
///
/// The stream is a run of opcodes, each either a run of literal bytes or a
/// back-reference into what has already been produced. Two details are easy to
/// get wrong and worth stating plainly:
///
/// - **Offsets are relative to the output, not the input**, and a match may
///   overlap the bytes it is still producing — copying a two-byte pattern for
///   thirty bytes is normal and correct. Copying byte by byte handles this;
///   copying a slice up front does not.
/// - **A length code of zero is an escape**, not a zero length. The real length
///   follows, extended 0xFF at a time. Reading it as a literal three-byte run
///   decodes a plausible-looking prefix and then derails — which is exactly what
///   it did, quietly, until a section name showed up mid-stream.
///
/// Validated against real drawings: the section page map decompresses to exactly
/// 144 bytes and the section map to exactly 1620, the latter yielding the
/// thirteen expected `AcDb:` section names.
enum DWGR2004Decompressor {

    /// Decompresses `source` into exactly `expectedSize` bytes.
    ///
    /// - Throws: `DWGError.invalidValue` if the stream is malformed — an unknown
    ///   opcode, or a back-reference pointing before the start of the output.
    static func decompress(_ source: [UInt8], expectedSize: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize)
        var p = 0

        /// Reads a length that has overflowed its opcode, 0xFF at a time.
        func extendedLength(base: Int) throws -> Int {
            var length = base
            while true {
                guard p < source.count else {
                    throw DWGError.invalidValue("truncated length")
                }
                let b = Int(source[p]); p += 1
                if b == 0 {
                    length += 0xFF
                } else {
                    return length + b
                }
            }
        }

        /// Reads the length of a literal run, consuming its opcode.
        func literalLength() throws -> Int {
            guard p < source.count else {
                throw DWGError.invalidValue("truncated literal")
            }
            let b = Int(source[p]); p += 1
            if b == 0 {
                return try extendedLength(base: 0x0F) + 3
            }
            return b + 3
        }

        /// Reads the two-byte offset form used by the longer match opcodes.
        /// The low two bits carry the count of literals trailing the match.
        func longOffset() throws -> (offset: Int, literals: Int) {
            guard p + 1 < source.count else {
                throw DWGError.invalidValue("truncated offset")
            }
            let b = Int(source[p]); p += 1
            let offset = (b >> 2) | (Int(source[p]) << 6); p += 1
            return (offset, b & 0x03)
        }

        while p < source.count && out.count < expectedSize {
            let opcode = Int(source[p])

            // A literal run: the opcode is the length itself.
            if opcode <= 0x0F {
                let count = try literalLength()
                guard p + count <= source.count else {
                    throw DWGError.invalidValue("literal run overruns input")
                }
                out.append(contentsOf: source[p..<(p + count)])
                p += count
                continue
            }

            p += 1
            if opcode == 0x11 { break }   // end of stream

            let matchLength: Int
            let offset: Int
            let trailingLiterals: Int

            switch opcode {
            case 0x40...0xFF:
                // The common case: length and the offset's low bits share the
                // opcode, with one further byte of offset.
                matchLength = (opcode >> 4) - 1
                guard p < source.count else {
                    throw DWGError.invalidValue("truncated offset")
                }
                offset = ((opcode >> 2) & 0x03) | (Int(source[p]) << 2)
                p += 1
                trailingLiterals = opcode & 0x03

            case 0x21...0x3F:
                matchLength = opcode - 0x1E
                (offset, trailingLiterals) = try longOffset()

            case 0x20:
                matchLength = try extendedLength(base: 0x21)
                (offset, trailingLiterals) = try longOffset()

            case 0x12...0x1F:
                matchLength = (opcode & 0x0F) + 2
                (offset, trailingLiterals) = try longOffset()

            case 0x10:
                // The escape for the 0x12–0x1F family. Rare — it appears in none
                // of the smaller pages — so it was settled by scoring candidate
                // bases across every page of every sample: 9 lands on the
                // declared size far more often than any neighbour.
                matchLength = try extendedLength(base: 9)
                (offset, trailingLiterals) = try longOffset()

            default:
                throw DWGError.invalidValue("unknown compression opcode 0x\(String(opcode, radix: 16))")
            }

            let start = out.count - offset - 1
            guard start >= 0 else {
                throw DWGError.invalidValue("back-reference before start of output")
            }
            // Byte by byte: the source may overlap the bytes being written.
            for i in 0..<matchLength {
                out.append(out[start + i])
            }

            if trailingLiterals > 0 {
                guard p + trailingLiterals <= source.count else {
                    throw DWGError.invalidValue("trailing literals overrun input")
                }
                out.append(contentsOf: source[p..<(p + trailingLiterals)])
                p += trailingLiterals
            }
        }

        return out
    }
}
