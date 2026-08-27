import Foundation

/// Any entity the parser can decode, as a single value.
enum DWGEntity {
    case line(DWGLine)
    case circle(DWGCircle)
    case arc(DWGArc)
    case point(DWGPointEntity)
    case lwpolyline(DWGLWPolyline)
    case polyline2D(DWGPolyline2D)
    case vertex2D(DWGVertex2D)
    case text(DWGText)
    case mtext(DWGMText)
    case ellipse(DWGEllipse)
    case spline(DWGSpline)
    case infiniteLine(DWGInfiniteLine)
    case hatch(DWGHatch)
    case insert(DWGInsert)
    case polyline3D(DWGPolyline3D)
    case vertex3D(DWGVertex3D)
    case mline(DWGMLine)
    case leader(DWGLeader)
    case face3D(DWG3DFace)
    case solid(DWGSolid)
    case polylineMesh(DWGPolylineMesh)
    case vertexMesh(DWGVertexMesh)
    /// Marks the end of a POLYLINE_2D's vertex run. Carries no data.
    case seqEnd

    var typeName: String {
        switch self {
        case .line:         return "LINE"
        case .circle:       return "CIRCLE"
        case .arc:          return "ARC"
        case .point:        return "POINT"
        case .lwpolyline:   return "LWPOLYLINE"
        case .polyline2D:   return "POLYLINE"
        case .vertex2D:     return "VERTEX"
        case .text:         return "TEXT"
        case .mtext:        return "MTEXT"
        case .ellipse:      return "ELLIPSE"
        case .spline:       return "SPLINE"
        case .infiniteLine: return "XLINE"
        case .hatch:        return "HATCH"
        case .insert:       return "INSERT"
        case .polyline3D:   return "POLYLINE"
        case .vertex3D:     return "VERTEX"
        case .mline:        return "MLINE"
        case .leader:       return "LEADER"
        case .face3D:       return "3DFACE"
        case let .solid(s): return s.kind == .trace ? "TRACE" : "SOLID"
        case .polylineMesh: return "POLYLINE"
        case .vertexMesh:   return "VERTEX"
        case .seqEnd:       return "SEQEND"
        }
    }

    /// False for entities that exist only as structure (vertices are drawn as
    /// part of their parent polyline; SEQEND is a marker).
    var isDrawable: Bool {
        switch self {
        case .vertex2D, .vertexMesh, .vertex3D, .seqEnd: return false
        default: return true
        }
    }
}

/// A decoded entity together with the context needed to place and colour it.
///
/// The entity structs themselves hold only their own geometry; ownership and
/// layer come from the handle-reference section, so they live here.
struct DWGEntityRecord {
    let handle: Int
    let entity: DWGEntity
    /// Handle of the entity's layer, for resolving ByLayer colour and
    /// visibility.
    let layerHandle: Int?
    /// Explicit owner, present only when `entityMode` is 0 — typically the
    /// block that contains this entity.
    let ownerHandle: Int?
    /// 0 = an explicit owner handle is stored; 1 = paper space; 2 = model space.
    let entityMode: UInt8
    /// 256 means ByLayer, which is the overwhelmingly common case.
    let color: Int
    /// Encoded lineweight from the entity header. See `DWGLineweight`.
    let lineweight: UInt8

    /// Lineweight in hundredths of a millimetre, or negative when inherited.
    var lineWeightHundredthsOfMM: Double {
        DWGLineweight.hundredthsOfMM(fromEncoded: Int(lineweight))
    }

    /// True for entities that belong directly to the drawing rather than to a
    /// block definition. Block contents are drawn only through their INSERT, so
    /// drawing them directly would duplicate geometry at the wrong place.
    var isModelSpace: Bool { entityMode == 2 }

    var isByLayerColor: Bool { color == 256 }
}
