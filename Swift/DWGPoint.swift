import Foundation

/// A point in the drawing's coordinate space.
struct DWGPoint: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = DWGPoint(x: 0, y: 0, z: 0)

    /// The extrusion direction shared by virtually all 2D entities.
    static let defaultExtrusion = DWGPoint(x: 0, y: 0, z: 1)
}

extension DWGPoint: CustomStringConvertible {
    var description: String {
        String(format: "(%.6g, %.6g, %.6g)", x, y, z)
    }
}
