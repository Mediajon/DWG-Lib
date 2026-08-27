import Foundation

/// Fixed DWG object types.
///
/// Values below 500 are fixed by the format. 500 and above are class-defined
/// and must be resolved through the file's Class section (not yet implemented),
/// so they deliberately have no cases here.
enum DWGObjectType: Int {
    case text            = 1
    case attrib          = 2
    case attdef          = 3
    case block           = 4
    case endblk          = 5
    case seqend          = 6
    case insert          = 7
    case minsert         = 8
    case vertex2D        = 10
    case vertex3D        = 11
    case vertexMesh      = 12
    case polyline2D      = 15
    case polyline3D      = 16
    case arc             = 17
    case circle          = 18
    case line            = 19
    case point           = 27
    case face3D          = 28
    case polylineMesh    = 30
    case solid           = 31
    case trace           = 32
    case viewport        = 34
    case ellipse         = 35
    case spline          = 36
    case ray             = 40
    case xline           = 41
    case dictionary      = 42
    case mtext           = 44
    case leader          = 45
    case mline           = 47
    case blockControl    = 48
    case blockHeader     = 49
    case layerControl    = 50
    case layer           = 51
    case styleControl    = 52
    case style           = 53
    case ltypeControl    = 56
    case ltype           = 57
    case viewControl     = 60
    case view            = 61
    case ucsControl      = 62
    case ucs             = 63
    case vportControl    = 64
    case vport           = 65
    case appidControl    = 66
    case appid           = 67
    case dimstyleControl = 68
    case dimstyle        = 69
    case vpEntHdrControl = 70
    case vpEntHdr        = 71
    case group           = 72
    case mlinestyle      = 73
    case lwpolyline      = 77
    case hatch           = 78
    case xrecord         = 79
    case placeholder     = 80
    case layout          = 82

    /// True for types this parser can decode into geometry today.
    /// Extend as each decoder lands.
    var isImplemented: Bool {
        switch self {
        case .line, .circle, .arc, .point, .lwpolyline, .text, .mtext, .ellipse,
             .spline, .ray, .xline, .layer, .insert, .blockHeader,
             .polyline2D, .vertex2D, .seqend, .hatch,
             .face3D, .solid, .trace, .polylineMesh, .vertexMesh,
             .polyline3D, .vertex3D, .mline, .mlinestyle, .leader:
            return true
        default:
            return false
        }
    }

    /// True for types that represent drawable geometry (whether or not we can
    /// decode them yet) — useful for reporting what a file contains.
    var isDrawable: Bool {
        switch self {
        case .line, .circle, .arc, .point, .lwpolyline, .polyline2D, .polyline3D,
             .text, .mtext, .ellipse, .spline, .insert, .solid, .trace, .face3D,
             .polylineMesh, .hatch, .ray, .xline, .leader:
            return true
        default:
            return false
        }
    }
}
