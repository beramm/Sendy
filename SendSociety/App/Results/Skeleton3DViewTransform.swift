import SwiftUI

/// Presentation state only. It never changes the move, sequence, or resolved
/// pose-frame indices supplied by `ResultsView`.
struct Skeleton3DViewTransform: Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 1
    var translation = SIMD3<Float>.zero

    static let identity = Skeleton3DViewTransform()

    /// Vision reports the body in camera-relative coordinates, while the
    /// RealityKit virtual camera observes the model from the opposite side of
    /// its local depth axis. Half a turn restores the viewpoint seen in the
    /// source video (for example, a filmed back opens as a back view).
    static let videoAligned = Skeleton3DViewTransform(yaw: .pi, zoom: 2.5)
}

enum Skeleton3DDragMode: String, CaseIterable, Identifiable {
    case rotate
    case pan

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
