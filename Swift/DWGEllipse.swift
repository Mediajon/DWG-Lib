import Foundation

/// A decoded ELLIPSE entity (object type 35).
///
/// Validated byte-exact against AutoCAD's own property dump: handle 0x1BE,
/// centre (11.1433, 9.5374), major axis (-8.7508, -8.03465), ratio 0.336109,
/// angles 0 → 6.28319 — reproducing AutoCAD's reported major radius (11.8799)
/// and minor radius (3.99294).
///
/// Note the shape is defined by a *vector*, not two radii: `majorAxis` runs from
/// the centre to the ellipse's extreme point, so its length is the major radius
/// and its direction encodes the rotation. The minor radius is
/// `|majorAxis| × axisRatio`.
struct DWGEllipse {
    let handle: Int
    let center: DWGPoint
    /// Vector from the centre to the major-axis endpoint.
    let majorAxis: DWGPoint
    let extrusion: DWGPoint
    /// Minor radius ÷ major radius, in 0...1.
    let axisRatio: Double
    /// Radians, measured in the ellipse's own frame.
    let startAngle: Double
    let endAngle: Double
    let color: Int

    /// Length of `majorAxis` — AutoCAD's "MajorRadius".
    var majorRadius: Double {
        (majorAxis.x * majorAxis.x + majorAxis.y * majorAxis.y + majorAxis.z * majorAxis.z).squareRoot()
    }

    /// AutoCAD's "MinorRadius".
    var minorRadius: Double { majorRadius * axisRatio }

    /// Rotation of the major axis from +X, in radians.
    var rotation: Double { atan2(majorAxis.y, majorAxis.x) }

    /// True when the ellipse is a full, unbroken curve.
    var isFullEllipse: Bool {
        abs((endAngle - startAngle).magnitude - 2 * .pi) < 1e-6
    }

    /// Decodes an ELLIPSE, with the reader positioned immediately after the
    /// common entity header.
    ///
    ///     3BD  centre
    ///     3BD  major-axis vector
    ///     3BD  extrusion
    ///     BD   axis ratio
    ///     BD   start angle
    ///     BD   end angle
    static func parse(_ r: inout DWGBitReader, header: DWGEntityHeader) throws -> DWGEllipse {
        let c = try r.read3BD()
        let m = try r.read3BD()
        let e = try r.read3BD()
        let axisRatio = try r.readBD()
        let startAngle = try r.readBD()
        let endAngle = try r.readBD()

        guard axisRatio.isFinite, axisRatio > 0, axisRatio <= 1.0000001 else {
            throw DWGError.invalidValue("ellipse axis ratio \(axisRatio)")
        }
        guard startAngle.isFinite, endAngle.isFinite else {
            throw DWGError.invalidValue("ellipse angles \(startAngle)…\(endAngle)")
        }

        return DWGEllipse(
            handle: header.handle,
            center: DWGPoint(x: c.x, y: c.y, z: c.z),
            majorAxis: DWGPoint(x: m.x, y: m.y, z: m.z),
            extrusion: DWGPoint(x: e.x, y: e.y, z: e.z),
            axisRatio: axisRatio,
            startAngle: startAngle,
            endAngle: endAngle,
            color: header.color
        )
    }
}
