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
    private var jointEntities: [JointName: ModelEntity] = [:]
    private var boneEntities: [BoneKey: ModelEntity] = [:]

    init() {
        root.addChild(skeleton)
        buildEntities()
    }

    func update(frame: PoseFrame3D?, viewTransform: Skeleton3DViewTransform) {
        apply(viewTransform)
        guard let frame, !frame.joints.isEmpty else {
            jointEntities.values.forEach { $0.isEnabled = false }
            boneEntities.values.forEach { $0.isEnabled = false }
            return
        }

        let origin = bodyOrigin(frame)
        var displayPoints: [JointName: SIMD3<Float>] = [:]
        for (name, entity) in jointEntities {
            guard let joint = frame.joints[name] else {
                entity.isEnabled = false
                continue
            }
            let point = SIMD3(joint.point.x, joint.point.y, joint.point.z) - origin
            displayPoints[name] = point
            entity.position = point
            entity.isEnabled = true
        }

        for (key, entity) in boneEntities {
            guard let start = displayPoints[key.start], let end = displayPoints[key.end] else {
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
            entity.scale = SIMD3(1, length, 1)
            entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            entity.isEnabled = true
        }
    }

    private func buildEntities() {
        let material = SimpleMaterial(color: .systemTeal, roughness: 0.65, isMetallic: false)
        let jointMesh = MeshResource.generateSphere(radius: 0.035)
        for name in JointName.allCases {
            let entity = ModelEntity(mesh: jointMesh, materials: [material])
            entity.isEnabled = false
            skeleton.addChild(entity)
            jointEntities[name] = entity
        }

        let boneMesh = MeshResource.generateCylinder(height: 1, radius: 0.018)
        for (start, end) in skeletonBones {
            let key = BoneKey(start: start, end: end)
            let entity = ModelEntity(mesh: boneMesh, materials: [material])
            entity.isEnabled = false
            skeleton.addChild(entity)
            boneEntities[key] = entity
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

private struct BoneKey: Hashable {
    var start: JointName
    var end: JointName
}
