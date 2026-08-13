import SwiftUI

/// Presentation state only. It never changes the move, sequence, or resolved
/// pose-frame indices supplied by `ResultsView`.
struct Skeleton3DViewTransform: Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 1
    var translation = SIMD3<Float>.zero

    static let identity = Skeleton3DViewTransform()
}

enum Skeleton3DDragMode: String, CaseIterable, Identifiable {
    case rotate
    case pan

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
