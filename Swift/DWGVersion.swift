import Foundation

/// DWG file format versions, identified by the six-byte signature at the start
/// of every DWG file (e.g. "AC1015" for AutoCAD 2000).
///
/// The format changes with almost every AutoCAD release, so the version gates
/// everything the parser does. Implemented so far: **R2000 (AC1015)**,
/// **R2004 (AC1018)** and **R2010 (AC1024)**.
///
/// The releases are not a straight line. R2004 introduced a container of
/// compressed pages; R2007 replaced it with a Reed-Solomon design that was then
/// abandoned, and R2010 went back to R2004's container while changing how
/// objects describe themselves. So R2007 is an island, and the useful
/// distinctions are drawn per-feature below rather than as "version X and
/// later".
enum DWGVersion: String, CaseIterable {
    case r10   = "AC1006"
    case r11   = "AC1009"   // also R12
    case r13   = "AC1012"
    case r14   = "AC1014"
    case r2000 = "AC1015"   // ← implemented
    case r2004 = "AC1018"
    case r2007 = "AC1021"
    case r2010 = "AC1024"
    case r2013 = "AC1027"
    case r2018 = "AC1032"

    /// Human-readable release name, for UI and diagnostics.
    var displayName: String {
        switch self {
        case .r10:   return "AutoCAD R10"
        case .r11:   return "AutoCAD R11/R12"
        case .r13:   return "AutoCAD R13"
        case .r14:   return "AutoCAD R14"
        case .r2000: return "AutoCAD 2000"
        case .r2004: return "AutoCAD 2004"
        case .r2007: return "AutoCAD 2007"
        case .r2010: return "AutoCAD 2010"
        case .r2013: return "AutoCAD 2013"
        case .r2018: return "AutoCAD 2018"
        }
    }

    /// Whether our parser can read this version.
    var isSupported: Bool {
        self == .r2000 || self == .r2004 || self == .r2010
            || self == .r2013 || self == .r2018
    }

    /// Whether the drawing is a container of compressed pages rather than a
    /// flat file.
    ///
    /// R2007 is the odd one out: it has a container of its own, built on
    /// Reed-Solomon coding, which AutoCAD then abandoned — R2010 and later went
    /// back to R2004's. So this is deliberately not "R2004 and later".
    var usesR2004Container: Bool {
        switch self {
        case .r2004, .r2010, .r2013, .r2018: return true
        default: return false
        }
    }

    /// Whether objects carry a type code and an explicit handle-stream size.
    ///
    /// R2010 dropped the fixed-width type and the bit-size field. In its place
    /// the type is a short code, and the handle stream's *size* is recorded
    /// instead of where it starts — so the handles occupy the last bits of the
    /// object rather than beginning at a stated offset.
    var usesObjectTypeCode: Bool {
        switch self {
        case .r2010, .r2013, .r2018: return true
        default: return false
        }
    }

    /// Whether every entity carries material and shadow properties (R2007 on).
    var hasMaterialAndShadowFlags: Bool {
        switch self {
        case .r2000, .r2004: return false
        default: return true
        }
    }

    /// Whether every entity carries three visual-style flags (R2010 on).
    var hasVisualStyleFlags: Bool { usesObjectTypeCode }

    /// Whether an extra flag bit sits after the reactor/extension-dictionary
    /// flags (R2013 on).
    ///
    /// R2013 slipped one more bit into the common header of both entities and
    /// objects, just before the colour. Without it the colour reads a bit early
    /// — coming out as a stray value rather than ByLayer — and every field after
    /// shifts, so coordinates decode as enormous nonsense and the drawing's
    /// bounds collapse to nothing.
    var hasExtraObjectFlagBit: Bool {
        switch self {
        case .r2013, .r2018: return true
        default: return false
        }
    }

    /// The signature bytes, as they appear at offset 0.
    var signature: String { rawValue }

    // MARK: - Detection

    /// Reads the six-byte signature and maps it to a version.
    /// Returns nil when the data is too short or the signature is unknown
    /// (i.e. the file is not a DWG we recognise).
    static func detect(from data: Data) -> DWGVersion? {
        guard data.count >= 6 else { return nil }
        let magic = data.prefix(6)
        guard let text = String(bytes: magic, encoding: .ascii) else { return nil }
        return DWGVersion(rawValue: text)
    }

    /// Reads just the file header from disk (rather than loading the whole
    /// drawing) to identify the version. DWG files are commonly large, so this
    /// avoids reading megabytes just to answer "what is this?".
    static func detect(fileAt url: URL) throws -> DWGVersion? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 6) else { return nil }
        return detect(from: head)
    }

    /// The raw signature string, even when it isn't a version we know — useful
    /// for error messages like "unsupported version AC1032".
    static func rawSignature(from data: Data) -> String? {
        guard data.count >= 6 else { return nil }
        return String(bytes: data.prefix(6), encoding: .ascii)
    }
}
