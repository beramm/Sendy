import SwiftUI

struct Skeleton3DComparisonView: View {
    let referenceFrame: PoseFrame3D?
    let attemptFrame: PoseFrame3D?

    @State private var viewLocked = true
    @State private var dragMode: Skeleton3DDragMode = .rotate
    @State private var sharedTransform = Skeleton3DViewTransform.videoAligned
    @State private var referenceTransform = Skeleton3DViewTransform.videoAligned
    @State private var attemptTransform = Skeleton3DViewTransform.videoAligned

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $viewLocked) {
                    Label("Lock 3D view", systemImage: viewLocked ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button)

                Picker("Gesture", selection: $dragMode) {
                    ForEach(Skeleton3DDragMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    resetView()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
            .font(.caption)
            .padding(.horizontal)

            HStack(spacing: 4) {
                pane(title: "Reference", frame: referenceFrame, transform: referenceBinding)
                pane(title: "Attempt", frame: attemptFrame, transform: attemptBinding)
            }
        }
        .onChange(of: viewLocked) { _, locked in
            if locked {
                sharedTransform = referenceTransform
            } else {
                referenceTransform = sharedTransform
                attemptTransform = sharedTransform
            }
        }
    }

    private func pane(
        title: String,
        frame: PoseFrame3D?,
        transform: Binding<Skeleton3DViewTransform>
    ) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Skeleton3DCanvas(frame: frame, viewTransform: transform, dragMode: dragMode)
        }
    }

    private var referenceBinding: Binding<Skeleton3DViewTransform> {
        Binding(
            get: { viewLocked ? sharedTransform : referenceTransform },
            set: { value in
                if viewLocked { sharedTransform = value } else { referenceTransform = value }
            }
        )
    }

    private var attemptBinding: Binding<Skeleton3DViewTransform> {
        Binding(
            get: { viewLocked ? sharedTransform : attemptTransform },
            set: { value in
                if viewLocked { sharedTransform = value } else { attemptTransform = value }
            }
        )
    }

    private func resetView() {
        if viewLocked {
            sharedTransform = .videoAligned
        } else {
            referenceTransform = .videoAligned
            attemptTransform = .videoAligned
        }
    }
}
