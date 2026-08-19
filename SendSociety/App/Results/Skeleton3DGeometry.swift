import Foundation
import simd

/// Visual proportions for the RealityKit mannequin. These definitions consume
/// Vision joints but contain no Vision types, requests, or analytical state.
enum Skeleton3DSegmentStyle: Hashable {
    case neck
    case shoulder
    case upperArm
    case forearm
    case upperTorso
    case lowerTorso
    case pelvis
    case thigh
    case lowerLeg
}

struct Skeleton3DSegmentDefinition: Hashable {
    var start: JointName3D
    var end: JointName3D
    var style: Skeleton3DSegmentStyle
}

let mannequinSegments3D: [Skeleton3DSegmentDefinition] = [
    .init(start: .centerHead, end: .centerShoulder, style: .neck),
    .init(start: .centerShoulder, end: .leftShoulder, style: .shoulder),
    .init(start: .centerShoulder, end: .rightShoulder, style: .shoulder),
    .init(start: .leftShoulder, end: .leftElbow, style: .upperArm),
    .init(start: .leftElbow, end: .leftWrist, style: .forearm),
    .init(start: .rightShoulder, end: .rightElbow, style: .upperArm),
    .init(start: .rightElbow, end: .rightWrist, style: .forearm),
    .init(start: .centerShoulder, end: .spine, style: .upperTorso),
    .init(start: .spine, end: .root, style: .lowerTorso),
    .init(start: .root, end: .leftHip, style: .pelvis),
    .init(start: .root, end: .rightHip, style: .pelvis),
    .init(start: .leftHip, end: .leftKnee, style: .thigh),
    .init(start: .leftKnee, end: .leftAnkle, style: .lowerLeg),
    .init(start: .rightHip, end: .rightKnee, style: .thigh),
    .init(start: .rightKnee, end: .rightAnkle, style: .lowerLeg)
]

enum Skeleton3DGeometry {
    /// A stable proportional unit derived from the detected torso rather than
    /// a fixed world-space thickness. The clamps keep partial detections sane.
    static func bodyScale(points: [JointName3D: SIMD3<Float>]) -> Float {
        let shoulderWidth = distance(.leftShoulder, .rightShoulder, points: points)
        let hipWidth = distance(.leftHip, .rightHip, points: points)
        let torsoLength = distance(.centerShoulder, .root, points: points)
        let candidates = [shoulderWidth, hipWidth, torsoLength.map { $0 * 0.55 }].compactMap { $0 }
        return (candidates.max() ?? 0.38).clamped(to: 0.18 ... 0.75)
    }

    static func segmentRadii(
        _ style: Skeleton3DSegmentStyle,
        bodyScale: Float,
        points: [JointName3D: SIMD3<Float>]
    ) -> SIMD2<Float> {
        switch style {
        case .neck:
            return SIMD2(repeating: bodyScale * 0.19)
        case .shoulder:
            return SIMD2(repeating: bodyScale * 0.24)
        case .upperArm:
            return SIMD2(bodyScale * 0.28, bodyScale * 0.25)
        case .forearm:
            return SIMD2(bodyScale * 0.24, bodyScale * 0.22)
        case .upperTorso:
            let shoulderWidth = distance(.leftShoulder, .rightShoulder, points: points) ?? bodyScale
            return SIMD2(max(bodyScale * 0.49, shoulderWidth * 0.54), bodyScale * 0.43)
        case .lowerTorso:
            let hipWidth = distance(.leftHip, .rightHip, points: points) ?? bodyScale * 0.75
            return SIMD2(max(bodyScale * 0.43, hipWidth * 0.55), bodyScale * 0.39)
        case .pelvis:
            return SIMD2(bodyScale * 0.31, bodyScale * 0.35)
        case .thigh:
            return SIMD2(bodyScale * 0.32, bodyScale * 0.29)
        case .lowerLeg:
            return SIMD2(bodyScale * 0.27, bodyScale * 0.245)
        }
    }

    static func jointScale(_ name: JointName3D, bodyScale: Float) -> SIMD3<Float> {
        let radius: Float
        switch name {
        case .leftWrist, .rightWrist:
            radius = bodyScale * 0.16
        case .leftAnkle, .rightAnkle:
            radius = bodyScale * 0.17
        case .leftShoulder, .rightShoulder, .leftHip, .rightHip:
            radius = bodyScale * 0.15
        case .leftElbow, .rightElbow, .leftKnee, .rightKnee:
            radius = bodyScale * 0.135
        case .centerShoulder, .spine, .root:
            radius = bodyScale * 0.14
        case .topHead, .centerHead:
            radius = bodyScale * 0.10
        }
        if name == .leftWrist || name == .rightWrist {
            return SIMD3(radius * 0.85, radius * 1.15, radius * 0.70)
        }
        if name == .leftAnkle || name == .rightAnkle {
            return SIMD3(radius * 0.90, radius * 1.20, radius * 0.75)
        }
        return SIMD3(repeating: radius)
    }

    static func headTransform(points: [JointName3D: SIMD3<Float>], bodyScale: Float) -> (position: SIMD3<Float>, scale: SIMD3<Float>)? {
        guard let center = points[.centerHead] else { return nil }
        let halfHeight = points[.topHead].map { max(simd_distance($0, center) * 1.15, bodyScale * 0.25) }
            ?? bodyScale * 0.28
        return (
            center,
            SIMD3(halfHeight * 0.88, halfHeight, halfHeight * 0.93)
        )
    }

    private static func distance(
        _ a: JointName3D,
        _ b: JointName3D,
        points: [JointName3D: SIMD3<Float>]
    ) -> Float? {
        guard let start = points[a], let end = points[b] else { return nil }
        return simd_distance(start, end)
    }
}
