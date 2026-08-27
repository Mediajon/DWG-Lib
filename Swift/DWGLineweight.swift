import Foundation

/// Converts DWG's encoded lineweights into real widths.
///
/// A drawing doesn't store a lineweight as a width — it stores an *index* into
/// a fixed table of 24 standard widths, plus a few values meaning "inherit".
/// That keeps a lineweight in a single byte, but it has to be expanded before
/// anything can be drawn.
///
/// Results are given in hundredths of a millimetre, matching DXF group code 370,
/// so both formats can feed one renderer. Negative values are inherited rather
/// than measured: -1 ByLayer, -2 ByBlock, -3 the drawing default.
///
/// Verified against real drawings: entity values decode to 0.00 mm, 0.35 mm,
/// ByBlock and ByLwDefault — which is exactly the mix AutoCAD reports.
enum DWGLineweight {

    /// The 24 standard widths, in hundredths of a millimetre.
    private static let table: [Double] = [
        0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50,
        53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211
    ]

    static let byLayer: Double = -1
    static let byBlock: Double = -2
    static let byDefault: Double = -3

    /// Expands an encoded lineweight.
    ///
    /// - `0...23` index the standard table.
    /// - `0x1C` ByLayer, `0x1D` ByBlock, `0x1E` the drawing default.
    /// - Anything else — including the all-ones value layers use to mean
    ///   "unset" — falls back to the default.
    static func hundredthsOfMM(fromEncoded value: Int) -> Double {
        switch value {
        case 0..<table.count: return table[value]
        case 0x1C: return byLayer
        case 0x1D: return byBlock
        case 0x1E: return byDefault
        default:   return byDefault
        }
    }
}
