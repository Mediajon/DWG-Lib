import Foundation

/// A decoded SPLINE entity (object type 36).
///
/// Splines are stored one of two ways, and the leading "scenario" value says
/// which:
///
/// - **Scenario 1** — the NURBS definition: knots plus control points (with
///   optional weights).
/// - **Scenario 2** — fit points the curve passes through, with tangents; the
///   control points are *derived* by the application, not stored.
///
/// This matters for rendering: a scenario-2 spline has no control points in the
/// file at all, even though AutoCAD will happily report some.
///
/// Validated against `Spline.dwg` (scenario 2, degree 3): all three fit points
/// match AutoCAD's dump exactly, including (28.059, 8.80677) and
/// (40.0613, 6.22149).
struct DWGSpline {

    /// A control point and its weight (1.0 when the spline isn't rational).
    struct ControlPoint {
        var point: DWGPoint
        var weight: Double = 1
    }

    let handle: Int
    let degree: Int
    let isRational: Bool
    let isClosed: Bool
    let isPeriodic: Bool

    /// Scenario 1 data — empty for a fit-point spline.
    let knots: [Double]
    let controlPoints: [ControlPoint]

    /// Scenario 2 data — empty for a control-point spline.
    let fitPoints: [DWGPoint]
    let startTangent: DWGPoint
    let endTangent: DWGPoint
    let fitTolerance: Double

    let color: Int

    /// True when the curve is defined by fit points rather than control points.
    var isFitPointSpline: Bool { !fitPoints.isEmpty }

    /// Decodes a SPLINE, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     BL  scenario (1 = control points, 2 = fit points)
    ///     BL  degree
    ///
    /// then, for scenario 2:
    ///
    ///     BD   fit tolerance
    ///     3BD  start tangent          3BD  end tangent
    ///     BL   fit-point count
    ///     3BD  each fit point
    ///
    /// or, for scenario 1:
    ///
    ///     B    rational   B  closed   B  periodic
    ///     BD   knot tolerance         BD control tolerance
    ///     BL   knot count             BL control-point count
    ///     B    weights present
    ///     BD   each knot
    ///     3BD  each control point, each followed by BD weight when present
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader, version: DWGVersion) throws -> DWGSpline {
        let scenario = try r.readBL()

        // R2013 inserted two fields between the scenario and the degree: a set of
        // spline flags and a knot-parameter selector. Reading them is essential —
        // without it the degree picks up one of these values (typically reading
        // 0), the guard below rejects the entity, and a drawing exported as
        // splines — how most applications write curves and outlined text — comes
        // out empty.
        //
        // The flags also carry the fit/control distinction that older versions
        // put in `scenario`. From R2013 `scenario` reads 1 for both kinds, so it
        // can no longer be trusted to choose the layout; the low bit of the spline
        // flags does. A fit-point spline read as a control-point one walks the
        // wrong fields and blanks — which is why plain AutoCAD-drawn splines (fit
        // points) stayed empty even after control-point splines worked.
        var usesFitPoints = scenario == 2
        if version.hasExtraObjectFlagBit {
            let splineFlags = try r.readBL()
            _ = try r.readBL()          // knot parameter
            usesFitPoints = (splineFlags & 0x1) != 0
        }

        let degree = try r.readBL()

        guard degree > 0, degree < 64 else {
            throw DWGError.invalidValue("spline degree \(degree)")
        }

        if usesFitPoints {
            let fitTolerance = try r.readBD()
            let bt = try r.read3BD()
            let et = try r.read3BD()
            let count = try r.readBL()
            guard count >= 0, count < 1_000_000 else {
                throw DWGError.invalidValue("spline fit-point count \(count)")
            }
            var fitPoints: [DWGPoint] = []
            fitPoints.reserveCapacity(count)
            for _ in 0..<count {
                let p = try r.read3BD()
                fitPoints.append(DWGPoint(x: p.x, y: p.y, z: p.z))
            }
            return DWGSpline(
                handle: header.handle,
                degree: degree,
                isRational: false,
                isClosed: false,
                isPeriodic: false,
                knots: [],
                controlPoints: [],
                fitPoints: fitPoints,
                startTangent: DWGPoint(x: bt.x, y: bt.y, z: bt.z),
                endTangent: DWGPoint(x: et.x, y: et.y, z: et.z),
                fitTolerance: fitTolerance,
                color: header.color
            )
        } else {
            let rational = try r.readBit() == 1
            let closed = try r.readBit() == 1
            let periodic = try r.readBit() == 1
            _ = try r.readBD()                     // knot tolerance
            _ = try r.readBD()                     // control tolerance
            let knotCount = try r.readBL()
            let controlCount = try r.readBL()
            let hasWeights = try r.readBit() == 1
            guard knotCount >= 0, knotCount < 1_000_000,
                  controlCount > 0, controlCount < 1_000_000 else {
                throw DWGError.invalidValue("spline knot/control counts \(knotCount)/\(controlCount)")
            }

            var knots: [Double] = []
            knots.reserveCapacity(knotCount)
            for _ in 0..<knotCount { knots.append(try r.readBD()) }

            var controlPoints: [ControlPoint] = []
            controlPoints.reserveCapacity(controlCount)
            for _ in 0..<controlCount {
                let p = try r.read3BD()
                let w = hasWeights ? try r.readBD() : 1
                controlPoints.append(ControlPoint(point: DWGPoint(x: p.x, y: p.y, z: p.z), weight: w))
            }

            return DWGSpline(
                handle: header.handle,
                degree: degree,
                isRational: rational,
                isClosed: closed,
                isPeriodic: periodic,
                knots: knots,
                controlPoints: controlPoints,
                fitPoints: [],
                startTangent: .zero,
                endTangent: .zero,
                fitTolerance: 0,
                color: header.color
            )
        }
    }
}
