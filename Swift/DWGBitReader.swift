import Foundation

/// Errors thrown by the DWG reader.
enum DWGError: LocalizedError {
    case outOfBounds(bit: Int, of: Int)
    case invalidValue(String)
    case unsupportedVersion(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .outOfBounds(bit, total):
            return "DWG: read past end of data (bit \(bit) of \(total))"
        case let .invalidValue(msg):
            return "DWG: invalid value — \(msg)"
        case let .unsupportedVersion(v):
            return "DWG: unsupported version \(v)"
        case let .malformed(msg):
            return "DWG: malformed file — \(msg)"
        }
    }
}

/// Bit-level reader for DWG files.
///
/// DWG is bit-packed rather than byte-aligned: a value can begin part-way
/// through a byte, and the format defines its own type vocabulary (raw values,
/// plus variable-width "bit" encodings that use a 2-bit prefix to say how many
/// bits actually follow). Everything in the parser is built on this type.
///
/// Conventions (per the ODA Open Design Specification):
/// - Bits are consumed MSB-first within each byte.
/// - Raw multi-byte integers are little-endian.
/// - Handles carry their offset bytes big-endian.
///
/// This implementation is clean-room: written from the published specification
/// only, so it carries no third-party licence obligations.
struct DWGBitReader {

    private let bytes: [UInt8]

    /// Current read position, in bits from the start of the data.
    private(set) var bitPosition: Int = 0

    /// Independent read position for the string stream (R2010+).
    ///
    /// From R2010 an object's text is not stored inline where each string field
    /// sits, but gathered into a stream at the tail of the object's data. While
    /// that stream is active, `readTV` reads from here and leaves `bitPosition`
    /// alone, so the two advance independently: numbers from one cursor, text
    /// from the other. When nil (R2000/R2004) `readTV` reads inline as before.
    private var stringPosition: Int? = nil

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: - Position

    var bitCount: Int { bytes.count * 8 }
    var byteCount: Int { bytes.count }
    var isAtEnd: Bool { bitPosition >= bitCount }

    /// Bits remaining until the end of the data.
    var bitsRemaining: Int { max(0, bitCount - bitPosition) }

    mutating func seek(toBit bit: Int) throws {
        guard bit >= 0, bit <= bitCount else { throw DWGError.outOfBounds(bit: bit, of: bitCount) }
        bitPosition = bit
    }

    mutating func seek(toByte byte: Int) throws {
        try seek(toBit: byte * 8)
    }

    mutating func skip(bits: Int) throws {
        try seek(toBit: bitPosition + bits)
    }

    /// Advances to the next byte boundary (no-op if already aligned).
    mutating func alignToByte() {
        let r = bitPosition % 8
        if r != 0 { bitPosition += 8 - r }
    }

    // MARK: - Primitives

    /// Reads a single bit. Spec type: `B`.
    mutating func readBit() throws -> UInt8 {
        guard bitPosition < bitCount else { throw DWGError.outOfBounds(bit: bitPosition, of: bitCount) }
        let byte = bytes[bitPosition >> 3]
        let shift = 7 - (bitPosition & 7)      // MSB-first
        bitPosition += 1
        return (byte >> shift) & 1
    }

    /// Reads `n` bits (n <= 64), MSB-first.
    mutating func readBits(_ n: Int) throws -> UInt64 {
        guard n >= 0, n <= 64 else { throw DWGError.invalidValue("readBits(\(n))") }
        guard bitPosition + n <= bitCount else {
            throw DWGError.outOfBounds(bit: bitPosition + n, of: bitCount)
        }
        var value: UInt64 = 0
        for _ in 0..<n {
            let byte = bytes[bitPosition >> 3]
            let shift = 7 - (bitPosition & 7)
            value = (value << 1) | UInt64((byte >> shift) & 1)
            bitPosition += 1
        }
        return value
    }

    /// Reads two bits. Spec type: `BB` (used as a code prefix).
    mutating func readBB() throws -> UInt8 {
        UInt8(try readBits(2))
    }

    // MARK: - Raw values

    /// Raw char (8 bits). Spec type: `RC`.
    mutating func readRC() throws -> UInt8 {
        UInt8(try readBits(8))
    }

    /// Raw short (16 bits, little-endian). Spec type: `RS`.
    mutating func readRS() throws -> UInt16 {
        let lo = UInt16(try readRC())
        let hi = UInt16(try readRC())
        return lo | (hi << 8)
    }

    /// Raw long (32 bits, little-endian). Spec type: `RL`.
    mutating func readRL() throws -> UInt32 {
        let lo = UInt32(try readRS())
        let hi = UInt32(try readRS())
        return lo | (hi << 16)
    }

    /// Raw double (64 bits, IEEE 754, little-endian). Spec type: `RD`.
    mutating func readRD() throws -> Double {
        let lo = UInt64(try readRL())
        let hi = UInt64(try readRL())
        return Double(bitPattern: lo | (hi << 32))
    }

    /// Two raw doubles. Spec type: `2RD`.
    mutating func read2RD() throws -> (x: Double, y: Double) {
        (try readRD(), try readRD())
    }

    /// Three raw doubles. Spec type: `3RD`.
    mutating func read3RD() throws -> (x: Double, y: Double, z: Double) {
        (try readRD(), try readRD(), try readRD())
    }

    // MARK: - Variable-width ("bit") values

    /// Bitshort. Spec type: `BS`.
    /// Prefix 00 → full 16-bit short; 01 → one byte; 10 → 0; 11 → 256.
    mutating func readBS() throws -> Int {
        switch try readBB() {
        case 0: return Int(try readRS())
        case 1: return Int(try readRC())
        case 2: return 0
        default: return 256
        }
    }

    /// Bitlong. Spec type: `BL`.
    /// Prefix 00 → full 32-bit long; 01 → one byte; 10 → 0; 11 → unused.
    mutating func readBL() throws -> Int {
        switch try readBB() {
        case 0: return Int(try readRL())
        case 1: return Int(try readRC())
        case 2: return 0
        default: throw DWGError.invalidValue("bitlong prefix 11 is unused")
        }
    }

    /// Bitdouble. Spec type: `BD`.
    /// Prefix 00 → full 64-bit double; 01 → 1.0; 10 → 0.0; 11 → unused.
    /// (Encoding 0.0 and 1.0 in two bits is why DWG files are compact.)
    mutating func readBD() throws -> Double {
        switch try readBB() {
        case 0: return try readRD()
        case 1: return 1.0
        case 2: return 0.0
        default: throw DWGError.invalidValue("bitdouble prefix 11 is unused")
        }
    }

    /// Two bitdoubles. Spec type: `2BD`.
    mutating func read2BD() throws -> (x: Double, y: Double) {
        (try readBD(), try readBD())
    }

    /// Three bitdoubles. Spec type: `3BD`.
    mutating func read3BD() throws -> (x: Double, y: Double, z: Double) {
        (try readBD(), try readBD(), try readBD())
    }

    /// Bitdouble-with-default. Spec type: `DD`.
    /// Patches part of `defaultValue` rather than restating it — consecutive
    /// coordinates usually share a sign and exponent, so only the differing
    /// mantissa bytes are stored.
    ///
    /// - `00` → use the default unchanged
    /// - `01` → read 4 bytes; they replace bytes 0-3 (the low mantissa)
    /// - `10` → read 6 bytes; the **first two** replace bytes 4-5 and the
    ///          **next four** replace bytes 0-3, keeping bytes 6-7 (sign and
    ///          exponent) from the default. Note the order: the higher-order
    ///          pair arrives first.
    /// - `11` → a full raw double
    ///
    /// The `10` layout was derived from real drawings: decoding a regular
    /// decagon this way reproduces AutoCAD's reported area and perimeter
    /// exactly, and makes every circumradius agree to seven decimal places.
    mutating func readDD(default defaultValue: Double) throws -> Double {
        switch try readBB() {
        case 0:
            return defaultValue
        case 1:
            let low = UInt64(try readRL())
            let pattern = (defaultValue.bitPattern & 0xFFFF_FFFF_0000_0000) | low
            return Double(bitPattern: pattern)
        case 2:
            let hi0 = UInt64(try readRC())      // → byte 4
            let hi1 = UInt64(try readRC())      // → byte 5
            let lo0 = UInt64(try readRC())      // → byte 0
            let lo1 = UInt64(try readRC())      // → byte 1
            let lo2 = UInt64(try readRC())      // → byte 2
            let lo3 = UInt64(try readRC())      // → byte 3
            var pattern = defaultValue.bitPattern & 0xFFFF_0000_0000_0000
            pattern |= lo0 | (lo1 << 8) | (lo2 << 16) | (lo3 << 24)
            pattern |= (hi0 << 32) | (hi1 << 40)
            return Double(bitPattern: pattern)
        default:
            return try readRD()
        }
    }

    /// Bit extrusion. Spec type: `BE`.
    /// R2000+: a single bit set means the common (0,0,1) extrusion.
    mutating func readBE() throws -> (x: Double, y: Double, z: Double) {
        if try readBit() == 1 {
            return (0, 0, 1)
        }
        return try read3BD()
    }

    /// Bit thickness. Spec type: `BT`.
    /// R2000+: a single bit set means zero thickness.
    mutating func readBT() throws -> Double {
        if try readBit() == 1 {
            return 0
        }
        return try readBD()
    }

    // MARK: - Modular values

    /// Modular char (signed, variable length). Spec type: `MC`.
    /// Seven data bits per byte; the high bit continues; bit 6 of the final
    /// byte marks a negative value.
    mutating func readMC() throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<4 {
            let byte = try readRC()
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                if byte & 0x40 != 0 {          // negative
                    value &= ~(0x40 << shift)
                    return -value
                }
                return value
            }
            shift += 7
        }
        throw DWGError.invalidValue("modular char longer than 4 bytes")
    }

    /// Modular char (unsigned variant, no sign bit). Spec type: `UMC`.
    mutating func readUMC() throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<5 {
            let byte = try readRC()
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw DWGError.invalidValue("unsigned modular char too long")
    }

    /// Modular short. Spec type: `MS`.
    /// Fifteen data bits per short; the high bit continues.
    /// Reads an object type as R2010 and later encode it.
    ///
    /// Earlier versions spend a fixed field on the type. R2010 leads with a
    /// two-bit code saying how much space the type actually needs, which keeps
    /// the common types down to a single byte.
    mutating func readObjectTypeCode() throws -> Int {
        let code = try readBB()
        switch code {
        case 0:
            return Int(try readRC())
        case 1:
            // The same single byte, shifted up into the range reserved for the
            // types that follow the built-in ones.
            return Int(try readRC()) + 0x1F0
        case 2:
            let low = Int(try readRC())
            let high = Int(try readRC())
            return low | (high << 8)
        default:
            throw DWGError.invalidValue("reserved object type code")
        }
    }

    mutating func readMS() throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<2 {
            let word = try readRS()
            value |= Int(word & 0x7FFF) << shift
            if word & 0x8000 == 0 { return value }
            shift += 15
        }
        throw DWGError.invalidValue("modular short too long")
    }

    // MARK: - Handles

    /// A handle reference: a 4-bit code plus an offset.
    struct Handle: Equatable, CustomStringConvertible {
        let code: UInt8
        let value: Int

        var description: String { "H(code: \(code), value: 0x\(String(value, radix: 16)))" }

        /// True when the stored value is an offset from the referring object's
        /// own handle rather than a handle in its own right.
        var isRelative: Bool { code == 0x6 || code == 0x8 || code == 0xA || code == 0xC }

        /// Resolves this reference against the handle of the object that holds
        /// it, returning nil for a null reference.
        ///
        /// Most references point at something a handful of handles away — an
        /// owner, or the next entity in a chain — so the format stores the
        /// *difference* rather than the handle, which usually fits in one byte:
        ///
        /// - `6` → owner + 1
        /// - `8` → owner - 1
        /// - `A` → owner + value
        /// - `C` → owner - value
        ///
        /// Codes 2 to 5 hold an ordinary absolute handle.
        ///
        /// Skipping this step is quietly destructive: absolute references still
        /// resolve correctly, so layers and block lookups keep working while
        /// ownership silently points at nonsense — for instance a block's
        /// contents appearing to belong to handle 0x3.
        func resolved(against owner: Int) -> Int? {
            let handle: Int
            switch code {
            case 0x6: handle = owner + 1
            case 0x8: handle = owner - 1
            case 0xA: handle = owner + value
            case 0xC: handle = owner - value
            default:  handle = value
            }
            return handle <= 0 ? nil : handle
        }
    }

    /// Reads a handle reference. Spec type: `H`.
    /// First byte splits into a 4-bit code and a 4-bit counter; the counter
    /// gives how many offset bytes follow (big-endian).
    mutating func readHandle() throws -> Handle {
        let first = try readRC()
        let code = (first >> 4) & 0xF
        let counter = Int(first & 0xF)
        guard counter <= 8 else { throw DWGError.invalidValue("handle counter \(counter)") }
        var value = 0
        for _ in 0..<counter {
            value = (value << 8) | Int(try readRC())
        }
        return Handle(code: code, value: value)
    }

    // MARK: - Text

    /// Variable text. Spec type: `TV` (R2000: a bitshort length + raw bytes).
    ///
    /// The stored length *includes* the terminating NUL, so it is trimmed here
    /// — verified against a drawing whose text is "some text" (length 10).
    /// Bytes are interpreted in the drawing's code page; we accept UTF-8 and
    /// fall back to Latin-1 so no byte sequence causes a hard failure.
    /// Locates and activates the R2010 string stream for an object.
    ///
    /// The object's data section ends just before its handle stream. The final
    /// bit of that section flags whether a string stream is present; if it is,
    /// the 16 bits before the flag give the stream's size (extended by a further
    /// 16 bits when the high bit is set), and the strings occupy that many bits
    /// ending there. This sets the string cursor to the start of that run.
    ///
    /// - Parameters:
    ///   - objectStartBit: the object's first bit (its MS size field).
    ///   - dataEndBit: the first bit of the handle stream (where the data ends).
    mutating func activateStringStream(objectStartBit: Int, dataEndBit: Int) throws {
        let flagBit = dataEndBit - 1
        guard flagBit > objectStartBit else { setStringStream(at: nil); return }

        let mainPosition = bitPosition
        try seek(toBit: flagBit)
        let present = try readBit() == 1
        if !present {
            try seek(toBit: mainPosition)
            setStringStream(at: nil)
            return
        }

        var endpos = flagBit - 16
        try seek(toBit: endpos)
        var size = Int(try readRS())
        if size & 0x8000 != 0 {
            size &= 0x7FFF
            endpos -= 16
            try seek(toBit: endpos)
            size += Int(try readRS()) << 15
        }

        try seek(toBit: mainPosition)
        setStringStream(at: endpos - size)
    }

    /// Directs `readTV` to a string stream, or back inline when `bit` is nil.
    mutating func setStringStream(at bit: Int?) {
        stringPosition = bit
    }

    mutating func readTV() throws -> String {
        if stringPosition != nil {
            return try readTVFromStringStream()
        }
        return try readTVInline()
    }

    /// Reads a text value inline: a length, then that many single bytes.
    /// Used by R2000 and R2004, where text sits where its field is.
    private mutating func readTVInline() throws -> String {
        let length = try readBS()
        guard length >= 0 else { throw DWGError.invalidValue("text length \(length)") }
        if length == 0 { return "" }
        var buffer = [UInt8]()
        buffer.reserveCapacity(length)
        for _ in 0..<length {
            buffer.append(try readRC())
        }
        while buffer.last == 0 { buffer.removeLast() }
        if buffer.isEmpty { return "" }
        if let s = String(bytes: buffer, encoding: .utf8) { return s }
        return String(bytes: buffer, encoding: .isoLatin1) ?? ""
    }

    /// Reads a text value from the R2010 string stream: a length in characters,
    /// then that many little-endian UTF-16 units. Only the string cursor moves.
    private mutating func readTVFromStringStream() throws -> String {
        guard let saved = stringPosition else { return "" }
        let mainPosition = bitPosition
        try seek(toBit: saved)

        let length = try readBS()
        guard length >= 0, length < 1_000_000 else {
            try seek(toBit: mainPosition)
            throw DWGError.invalidValue("string length \(length)")
        }
        var units = [UInt16]()
        units.reserveCapacity(length)
        for _ in 0..<length {
            let lo = UInt16(try readRC())
            let hi = UInt16(try readRC())
            units.append(lo | (hi << 8))
        }

        stringPosition = bitPosition        // advance the string cursor
        try seek(toBit: mainPosition)       // restore the main cursor
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Raw byte access

    /// Reads `count` raw bytes from the current position.
    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw DWGError.invalidValue("readBytes(\(count))") }
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(try readRC())
        }
        return out
    }

    /// Byte-aligned peek that does not move the read position.
    func peekBytes(at byteOffset: Int, count: Int) throws -> [UInt8] {
        guard byteOffset >= 0, byteOffset + count <= bytes.count else {
            throw DWGError.outOfBounds(bit: (byteOffset + count) * 8, of: bitCount)
        }
        return Array(bytes[byteOffset..<(byteOffset + count)])
    }
}
