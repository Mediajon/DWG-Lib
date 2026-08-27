import Foundation

/// A decoded HATCH entity (object type 78) — a filled or patterned region.
///
/// The most intricate entity in the format: a hatch is a set of boundary paths
/// (each a run of lines, arcs, elliptical arcs or splines — or a polyline),
/// plus either a solid fill or a pattern built from definition lines.
///
/// Validated against two real hatches, both pattern "ANSI31":
/// - handle 0x250 — associative, boundary area 10.3098
/// - handle 0x24E — non-associative, boundary area 7.2388
///
/// both matching AutoCAD's reported areas exactly, with the pattern definition
/// decoding to a single line at 0.785398 rad (45°) offset (-0.08839, 0.08839) —
/// ANSI31's familiar diagonal.
struct DWGHatch {

    /// One segment of a boundary path.
    enum Segment {
        case line(start: DWGPoint, end: DWGPoint)
        case arc(center: DWGPoint, radius: Double, startAngle: Double, endAngle: Double, counterClockwise: Bool)
        case ellipticalArc(center: DWGPoint, majorAxisEnd: DWGPoint, axisRatio: Double,
                           startAngle: Double, endAngle: Double, counterClockwise: Bool)
        case spline(degree: Int, isRational: Bool, isPeriodic: Bool,
                    knots: [Double], controlPoints: [(point: DWGPoint, weight: Double)])
    }

    /// A vertex of a polyline-form boundary.
    struct PolylineVertex {
        var point: DWGPoint
        var bulge: Double
    }

    /// One closed loop bounding the hatched region.
    struct BoundaryPath {
        var flags: Int
        /// Populated when the path is stored as explicit segments.
        var segments: [Segment] = []
        /// Populated when the path is stored as a polyline.
        var polyline: [PolylineVertex] = []
        var isPolylineClosed = false
        /// How many source entities this path was derived from. The handles
        /// themselves live in the entity's handle-reference section, not here.
        var boundaryObjectCount = 0

        var isPolyline: Bool { (flags & 0x02) != 0 }
        var isExternal: Bool { (flags & 0x01) != 0 }
    }

    /// One line of a hatch pattern definition — a family of parallel lines.
    struct PatternLine {
        var angle: Double
        var basePoint: DWGPoint
        var offset: DWGPoint
        var dashes: [Double]
    }

    let handle: Int
    let elevation: Double
    let extrusion: DWGPoint
    let patternName: String
    let isSolidFill: Bool
    let isAssociative: Bool
    let paths: [BoundaryPath]
    let style: Int
    let patternType: Int
    let patternAngle: Double
    let patternScale: Double
    let isDoubleHatch: Bool
    let patternLines: [PatternLine]
    let seedPoints: [DWGPoint]
    let color: Int

    /// Decodes a HATCH, with the reader positioned immediately after the common
    /// entity header.
    ///
    ///     BD   elevation
    ///     3BD  extrusion
    ///     TV   pattern name
    ///     B    solid fill
    ///     B    associative
    ///     BL   path count
    ///     ..   each path (see below)
    ///     BS   style          BS  pattern type
    ///     ..   pattern definition, when not a solid fill
    ///     BL   seed-point count, then 2RD each
    ///
    /// Each path is either a polyline (flag bit 1) or a run of typed segments:
    /// 1 = line, 2 = arc, 3 = elliptical arc, 4 = spline. Every path ends with a
    /// count of the entities it was derived from — **a count only**: the handles
    /// are stored with the entity's other references at the very end of the
    /// object. Reading them here instead misaligns everything that follows.
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader, version: DWGVersion) throws -> DWGHatch {
        // R2004 gave hatches gradient fills, adding a block at the very start of
        // the body that is always present — its first value simply says whether a
        // gradient is in use. Skipping it (as a reader written for R2000 would)
        // means every field afterwards, including the boundary-path count, is read
        // from the wrong place: the count comes out as millions and the parse is
        // lost. Real exporters emit solid-filled shapes — including outlined text
        // rendered as filled glyphs — as hatches, so this matters for ordinary
        // files, not just ones that actually use gradients.
        if version != .r2000 {
            let isGradient = try r.readBL()
            _ = try r.readBL()                  // reserved
            _ = try r.readBD()                  // gradient angle
            _ = try r.readBD()                  // gradient shift
            _ = try r.readBL()                  // single-colour gradient
            _ = try r.readBD()                  // gradient tint
            let colorCount = try r.readBL()
            guard colorCount >= 0, colorCount < 10_000 else {
                throw DWGError.invalidValue("hatch gradient colour count \(colorCount)")
            }
            for _ in 0..<colorCount {
                _ = try r.readBD()              // colour value
                _ = try r.readBL()              // rgb
                _ = try r.readRC()              // colour byte
            }
            _ = isGradient
            // The gradient name is a text value; from R2007 it lives in the
            // string stream, which the header has already pointed the reader at.
            _ = try r.readTV()
        }

        let elevation = try r.readBD()
        let e = try r.read3BD()
        let patternName = try r.readTV()
        let isSolidFill = try r.readBit() == 1
        let isAssociative = try r.readBit() == 1

        let pathCount = try r.readBL()
        guard pathCount >= 0, pathCount < 100_000 else {
            throw DWGError.invalidValue("hatch path count \(pathCount)")
        }

        var paths: [BoundaryPath] = []
        paths.reserveCapacity(pathCount)

        for _ in 0..<pathCount {
            let flags = try r.readBL()
            var path = BoundaryPath(flags: flags)

            if (flags & 0x02) != 0 {
                let hasBulges = try r.readBit() == 1
                path.isPolylineClosed = try r.readBit() == 1
                let count = try r.readBL()
                guard count >= 0, count < 1_000_000 else {
                    throw DWGError.invalidValue("hatch polyline vertex count \(count)")
                }
                for _ in 0..<count {
                    let x = try r.readRD()
                    let y = try r.readRD()
                    let bulge = hasBulges ? try r.readBD() : 0
                    path.polyline.append(PolylineVertex(point: DWGPoint(x: x, y: y), bulge: bulge))
                }
            } else {
                let count = try r.readBL()
                guard count >= 0, count < 1_000_000 else {
                    throw DWGError.invalidValue("hatch segment count \(count)")
                }
                for _ in 0..<count {
                    path.segments.append(try parseSegment(&r, version: version))
                }
            }

            path.boundaryObjectCount = try r.readBL()
            paths.append(path)
        }

        let style = try r.readBS()
        let patternType = try r.readBS()

        var patternAngle = 0.0
        var patternScale = 1.0
        var isDoubleHatch = false
        var patternLines: [PatternLine] = []

        if !isSolidFill {
            patternAngle = try r.readBD()
            patternScale = try r.readBD()
            isDoubleHatch = try r.readBit() == 1
            let lineCount = try r.readBS()
            guard lineCount >= 0, lineCount < 10_000 else {
                throw DWGError.invalidValue("hatch definition-line count \(lineCount)")
            }
            for _ in 0..<lineCount {
                let angle = try r.readBD()
                let bx = try r.readBD()
                let by = try r.readBD()
                let ox = try r.readBD()
                let oy = try r.readBD()
                let dashCount = try r.readBS()
                guard dashCount >= 0, dashCount < 10_000 else {
                    throw DWGError.invalidValue("hatch dash count \(dashCount)")
                }
                var dashes: [Double] = []
                dashes.reserveCapacity(dashCount)
                for _ in 0..<dashCount { dashes.append(try r.readBD()) }
                patternLines.append(PatternLine(
                    angle: angle,
                    basePoint: DWGPoint(x: bx, y: by),
                    offset: DWGPoint(x: ox, y: oy),
                    dashes: dashes
                ))
            }
        }

        let seedCount = try r.readBL()
        guard seedCount >= 0, seedCount < 100_000 else {
            throw DWGError.invalidValue("hatch seed-point count \(seedCount)")
        }
        var seedPoints: [DWGPoint] = []
        seedPoints.reserveCapacity(seedCount)
        for _ in 0..<seedCount {
            let x = try r.readRD()
            let y = try r.readRD()
            seedPoints.append(DWGPoint(x: x, y: y))
        }

        return DWGHatch(
            handle: header.handle,
            elevation: elevation,
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            patternName: patternName,
            isSolidFill: isSolidFill,
            isAssociative: isAssociative,
            paths: paths,
            style: style,
            patternType: patternType,
            patternAngle: patternAngle,
            patternScale: patternScale,
            isDoubleHatch: isDoubleHatch,
            patternLines: patternLines,
            seedPoints: seedPoints,
            color: header.color
        )
    }

    // MARK: - Segments

    private static func parseSegment(_ r: inout DWGBitReader, version: DWGVersion) throws -> Segment {
        let type = try r.readRC()
        switch type {
        case 1:
            let x0 = try r.readRD(), y0 = try r.readRD()
            let x1 = try r.readRD(), y1 = try r.readRD()
            return .line(start: DWGPoint(x: x0, y: y0), end: DWGPoint(x: x1, y: y1))

        case 2:
            let cx = try r.readRD(), cy = try r.readRD()
            let radius = try r.readBD()
            let start = try r.readBD()
            let end = try r.readBD()
            let ccw = try r.readBit() == 1
            return .arc(center: DWGPoint(x: cx, y: cy), radius: radius,
                        startAngle: start, endAngle: end, counterClockwise: ccw)

        case 3:
            let cx = try r.readRD(), cy = try r.readRD()
            let mx = try r.readRD(), my = try r.readRD()
            let ratio = try r.readBD()
            let start = try r.readBD()
            let end = try r.readBD()
            let ccw = try r.readBit() == 1
            return .ellipticalArc(center: DWGPoint(x: cx, y: cy),
                                  majorAxisEnd: DWGPoint(x: mx, y: my), axisRatio: ratio,
                                  startAngle: start, endAngle: end, counterClockwise: ccw)

        case 4:
            let degree = try r.readBL()
            let isRational = try r.readBit() == 1
            let isPeriodic = try r.readBit() == 1
            let knotCount = try r.readBL()
            let controlCount = try r.readBL()
            guard knotCount >= 0, knotCount < 1_000_000,
                  controlCount >= 0, controlCount < 1_000_000 else {
                throw DWGError.invalidValue("hatch spline counts \(knotCount)/\(controlCount)")
            }
            var knots: [Double] = []
            knots.reserveCapacity(knotCount)
            for _ in 0..<knotCount { knots.append(try r.readBD()) }

            var controlPoints: [(point: DWGPoint, weight: Double)] = []
            controlPoints.reserveCapacity(controlCount)
            for _ in 0..<controlCount {
                let x = try r.readRD(), y = try r.readRD()
                let w = isRational ? try r.readBD() : 1
                controlPoints.append((DWGPoint(x: x, y: y), w))
            }
            // R2010 added fit points to a hatch's spline edge, after the control
            // points. Without stepping over them the next boundary path reads
            // from the wrong place — one glyph of outlined text (a letter with a
            // hole, like "e", which needs two paths) loses its second path and
            // fails to fill.
            if version.usesObjectTypeCode {
                let fitCount = try r.readBL()
                guard fitCount >= 0, fitCount < 1_000_000 else {
                    throw DWGError.invalidValue("hatch spline fit-point count \(fitCount)")
                }
                for _ in 0..<fitCount {
                    _ = try r.readRD()
                    _ = try r.readRD()
                }
            }
            return .spline(degree: degree, isRational: isRational, isPeriodic: isPeriodic,
                           knots: knots, controlPoints: controlPoints)

        default:
            throw DWGError.invalidValue("unknown hatch path segment type \(type)")
        }
    }
}
