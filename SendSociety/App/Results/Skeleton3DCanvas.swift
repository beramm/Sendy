import SwiftUI
import RealityKit

struct Skeleton3DCanvas: View {
    let frame: PoseFrame3D?
    @Binding var viewTransform: Skeleton3DViewTransform
    let dragMode: Skeleton3DDragMode

    @State private var scene = Skeleton3DSceneController()
    @State private var dragStart: Skeleton3DViewTransform?
    @State private var magnificationStart: Float?

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                scene.update(frame: frame, viewTransform: viewTransform)
            } update: { _ in
                scene.update(frame: frame, viewTransform: viewTransform)
            }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)

            if frame == nil {
                unavailable("3D pose unavailable")
            } else if frame?.joints.isEmpty == true {
                unavailable("No 3D body detected for this frame")
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? viewTransform
                if dragStart == nil { dragStart = start }
                switch dragMode {
                case .rotate:
                    viewTransform.yaw = start.yaw + Float(value.translation.width) * 0.01
                    viewTransform.pitch = (start.pitch + Float(value.translation.height) * 0.01)
                        .clamped(to: (-Float.pi * 0.48) ... (Float.pi * 0.48))
                case .pan:
                    viewTransform.translation.x = start.translation.x + Float(value.translation.width) * 0.004
                    viewTransform.translation.y = start.translation.y - Float(value.translation.height) * 0.004
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnificationStart ?? viewTransform.zoom
                if magnificationStart == nil { magnificationStart = start }
                viewTransform.zoom = (start * Float(value.magnification)).clamped(to: 0.5 ... 4)
            }
            .onEnded { _ in magnificationStart = nil }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor
private final class Skeleton3DSceneController {
    let root = Entity()
    private let skeleton = Entity()
    private let headEntity: ModelEntity
    private var jointEntities: [JointName3D: ModelEntity] = [:]
    private var segmentEntities: [Skeleton3DSegmentDefinition: ModelEntity] = [:]

    init() {
        let bodyMaterial = SimpleMaterial(color: .systemMint, roughness: 0.58, isMetallic: false)
        headEntity = ModelEntity(
            mesh: .generateSphere(radius: 1),
            materials: [bodyMaterial]
        )
        headEntity.isEnabled = false
        root.addChild(skeleton)
        skeleton.addChild(headEntity)
        buildEntities(bodyMaterial: bodyMaterial)
    }

    func update(frame: PoseFrame3D?, viewTransform: Skeleton3DViewTransform) {
        apply(viewTransform)
        guard let frame, !frame.joints.isEmpty else {
            headEntity.isEnabled = false
            jointEntities.values.forEach { $0.isEnabled = false }
            segmentEntities.values.forEach { $0.isEnabled = false }
            return
        }

        let origin = bodyOrigin(frame)
        let displayPoints = frame.joints.mapValues {
            SIMD3($0.point.x, $0.point.y, $0.point.z) - origin
        }
        let bodyScale = Skeleton3DGeometry.bodyScale(points: displayPoints)

        if let head = Skeleton3DGeometry.headTransform(points: displayPoints, bodyScale: bodyScale) {
            headEntity.position = head.position
            headEntity.scale = head.scale
            headEntity.isEnabled = true
        } else {
            headEntity.isEnabled = false
        }

        for (name, entity) in jointEntities {
            guard let point = displayPoints[name] else {
                entity.isEnabled = false
                continue
            }
            entity.position = point
            entity.scale = Skeleton3DGeometry.jointScale(name, bodyScale: bodyScale)
            entity.isEnabled = true
        }

        for (segment, entity) in segmentEntities {
            guard let start = displayPoints[segment.start], let end = displayPoints[segment.end] else {
                entity.isEnabled = false
                continue
            }
            let delta = end - start
            let length = simd_length(delta)
            guard length > 1e-5 else {
                entity.isEnabled = false
                continue
            }
            entity.position = (start + end) * 0.5
            let radii = Skeleton3DGeometry.segmentRadii(
                segment.style,
                bodyScale: bodyScale,
                points: displayPoints
            )
            entity.scale = SIMD3(radii.x, length, radii.y)
            entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            entity.isEnabled = true
        }
    }

    private func buildEntities(bodyMaterial: SimpleMaterial) {
        let jointMaterial = SimpleMaterial(color: .white, roughness: 0.48, isMetallic: false)
        let jointMesh = MeshResource.generateSphere(radius: 1)
        for name in JointName3D.allCases where name != .topHead && name != .centerHead {
            let entity = ModelEntity(mesh: jointMesh, materials: [jointMaterial])
            entity.isEnabled = false
            skeleton.addChild(entity)
            jointEntities[name] = entity
        }

        let segmentMesh = MeshResource.generateCylinder(height: 1, radius: 1)
        for segment in mannequinSegments3D {
            let entity = ModelEntity(mesh: segmentMesh, materials: [bodyMaterial])
            entity.isEnabled = false
            skeleton.addChild(entity)
            segmentEntities[segment] = entity
        }
    }

    private func apply(_ transform: Skeleton3DViewTransform) {
        let yaw = simd_quatf(angle: transform.yaw, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: transform.pitch, axis: SIMD3<Float>(1, 0, 0))
        root.orientation = yaw * pitch
        root.scale = SIMD3(repeating: transform.zoom)
        root.position = SIMD3(
            transform.translation.x,
            transform.translation.y,
            -2.6 + transform.translation.z
        )
    }

    private func bodyOrigin(_ frame: PoseFrame3D) -> SIMD3<Float> {
        if let root = frame.joints[.root]?.point {
            return SIMD3(root.x, root.y, root.z)
        }
        if let left = frame.joints[.leftHip]?.point, let right = frame.joints[.rightHip]?.point {
            return (SIMD3(left.x, left.y, left.z) + SIMD3(right.x, right.y, right.z)) * 0.5
        }
        return .zero
    }
}
