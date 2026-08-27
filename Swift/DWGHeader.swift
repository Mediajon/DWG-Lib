import Foundation

/// A section-locator record: where one of the file's top-level sections lives.
struct DWGSectionLocator {
    let number: Int
    let seeker: Int    // byte offset from the start of the file
    let size: Int      // length in bytes

    var range: Range<Int> { seeker..<(seeker + size) }
}

/// Well-known section numbers in an R2000 file.
enum DWGSection: Int {
    case headerVariables = 0
    case classes         = 1
    case objectMap       = 2
    case objFreeSpace    = 3
    case template        = 4
    case auxHeader       = 5

    var displayName: String {
        switch self {
        case .headerVariables: return "Header variables"
        case .classes:         return "Class section"
        case .objectMap:       return "Object map"
        case .objFreeSpace:    return "Object free space"
        case .template:        return "Template"
        case .auxHeader:       return "AuxHeader"
        }
    }
}

/// The R2000 (AC1015) file header.
///
/// Layout, verified byte-for-byte against real files:
///
///     0x00  6   version signature ("AC1015")
///     0x06  5   zeros
///     0x0B  1   maintenance release version
///     0x0C  1   marker byte (0x01)
///     0x0D  RL  image (preview) seeker
///     0x11  RS  unknown
///     0x13  RS  code page
///     0x15  RL  number of section-locator records
///     0x19  ..  records: RC number, RL seeker, RL size  (9 bytes each)
///           RS  CRC
///           16  end sentinel
///
/// The 16-byte sentinel that closes the header is the parser's main integrity
/// check: if it appears exactly where the record count says it should, the
/// header was read correctly.
struct DWGFileHeader {

    /// Marks the end of the file header. Its presence at the computed position
    /// confirms the header (and the record count) was parsed correctly.
    static let endSentinel: [UInt8] = [
        0x95, 0xA0, 0x4E, 0x28, 0x99, 0x82, 0x1A, 0xE5,
        0x5E, 0x41, 0xE0, 0x5F, 0x9D, 0x3A, 0x4D, 0x00
    ]

    let version: DWGVersion
    let maintenanceRelease: UInt8
    let imageSeeker: Int
    let codePage: Int
    let locators: [Int: DWGSectionLocator]

    /// Convenience accessor for a known section.
    func locator(_ section: DWGSection) -> DWGSectionLocator? {
        locators[section.rawValue]
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> DWGFileHeader {
        guard let version = DWGVersion.detect(from: data) else {
            let sig = DWGVersion.rawSignature(from: data) ?? "<unreadable>"
            throw DWGError.unsupportedVersion(sig)
        }
        guard version.isSupported else {
            throw DWGError.unsupportedVersion("\(version.displayName) (\(version.signature))")
        }

        var reader = DWGBitReader(data)

        try reader.seek(toByte: 0x0B)
        let maintenance = try reader.readRC()
        _ = try reader.readRC()                       // marker byte (0x01)
        let imageSeeker = Int(try reader.readRL())
        _ = try reader.readRS()                       // unknown
        let codePage = Int(try reader.readRS())
        let recordCount = Int(try reader.readRL())

        // A plausible file has a handful of sections; anything wild means we
        // misread the header rather than that the file really says so.
        guard (1...16).contains(recordCount) else {
            throw DWGError.malformed("section-locator count \(recordCount) out of range")
        }

        var locators: [Int: DWGSectionLocator] = [:]
        for _ in 0..<recordCount {
            let number = Int(try reader.readRC())
            let seeker = Int(try reader.readRL())
            let size = Int(try reader.readRL())
            guard seeker >= 0, size >= 0, seeker + size <= data.count else {
                throw DWGError.malformed("section \(number) lies outside the file")
            }
            locators[number] = DWGSectionLocator(number: number, seeker: seeker, size: size)
        }

        _ = try reader.readRS()                       // header CRC

        // Integrity check: the sentinel must sit exactly here.
        let sentinel = try reader.readBytes(16)
        guard sentinel == endSentinel else {
            throw DWGError.malformed("header end sentinel not found — file header layout unrecognised")
        }

        guard locators[DWGSection.objectMap.rawValue] != nil else {
            throw DWGError.malformed("no object map section")
        }

        return DWGFileHeader(
            version: version,
            maintenanceRelease: maintenance,
            imageSeeker: imageSeeker,
            codePage: codePage,
            locators: locators
        )
    }

    /// Diagnostic summary, handy while developing.
    var debugSummary: String {
        var s = "DWG \(version.displayName) (\(version.signature))"
        s += "\n  maintenance release: \(maintenanceRelease)"
        s += "\n  code page: \(codePage)"
        s += "\n  image seeker: 0x\(String(imageSeeker, radix: 16))"
        s += "\n  sections:"
        for key in locators.keys.sorted() {
            let l = locators[key]!
            let name = DWGSection(rawValue: key)?.displayName ?? "Section \(key)"
            s += "\n    \(key) \(name): offset 0x\(String(l.seeker, radix: 16)), size \(l.size)"
        }
        return s
    }
}
