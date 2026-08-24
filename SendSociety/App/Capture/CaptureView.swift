#if os(iOS)
import SwiftUI
import AVFoundation
import CoreMotion
import PhotosUI
import UIKit

struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let role: VideoRef.Role

    @State private var camera = CameraController()
    @State private var tilt = TiltMonitor()
    @State private var countdownSeconds = 0
    @State private var singleTake = false
    @State private var recordedURL: URL?
    @State private var error: String?
    @State private var libraryItem: PhotosPickerItem?
    @State private var showingSettings = false
    @State private var showsFramingGuide = false
    @State private var showsAlignmentOverlay = true
    @State private var alignmentOverlay: CGImage?
    @State private var isLoadingAlignmentOverlay = false
    @State private var alignmentSourceLabel: String?
    @State private var recordedOrientation: CaptureOrientation?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                captureHeader

                ZStack {
                    CameraPreview(
                        session: camera.session,
                        alignmentOverlay: showsAlignmentOverlay ? alignmentOverlay : nil
                    )

                    if showsFramingGuide {
                        FramingGuide()
                    }

                    if isLoadingAlignmentOverlay {
                        ProgressView("Finding clearest wall frame…")
                            .tint(.white)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.72), in: .capsule)
                    }

                    if showsAlignmentOverlay,
                       let alignmentSourceLabel,
                       alignmentOverlay != nil {
                        VStack {
                            CaptureAlignmentGuide(
                                sourceLabel: alignmentSourceLabel,
                                motionAvailable: tilt.isAvailable,
                                hasMotionReference: tilt.referenceOrientation != nil,
                                deltaRollDegrees: tilt.deltaRollDegrees,
                                deltaPitchDegrees: tilt.deltaPitchDegrees
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            Spacer()
                        }
                    }

                    if let countdown = camera.countdown {
                        Text("\(countdown)")
                            .font(.system(size: 96, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                    }

                    if let error {
                        Text(error)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.red.opacity(0.8), in: .rect(cornerRadius: 12))
                            .padding(20)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
                .clipped()

                captureControls
            }
        }
        .foregroundStyle(.white)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .task {
            tilt.start()
            await camera.start()
            await loadAlignmentTarget()
        }
        .onDisappear {
            camera.stop()
            tilt.stop()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            model.beginImport(item, role: role)
            dismiss()
        }
        .navigationDestination(item: $recordedURL) { url in
            SingleTakeSplitView(
                url: url,
                captureOrientation: recordedOrientation
            )
        }
    }

    private var captureHeader: some View {
        HStack(spacing: 22) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 25, weight: .light))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close camera")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(.white)
                    Capsule()
                        .fill(role == .attempt ? .white : .white.opacity(0.25))
                }
                .frame(height: 8)

                Text(role == .reference ? "Reference · 1 of 2" : "Attempt · 2 of 2")
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Capture settings")
        }
        .padding(.horizontal, 18)
        .frame(height: 84)
        .background(Color.black)
    }

    private var captureControls: some View {
        HStack {
            PhotosPicker(selection: $libraryItem, matching: .videos) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.86), in: .rect(cornerRadius: 15))
            }
            .accessibilityLabel("Choose video from library")

            Spacer()

            Button {
                if camera.isRecording {
                    camera.stopRecording()
                } else if !camera.isPreparingRecording {
                    record()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 86, height: 86)

                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.red)
                            .frame(width: 34, height: 34)
                    } else {
                        Circle()
                            .fill(.white.opacity(0.2))
                            .frame(width: 68, height: 68)
                            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 1))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled((!camera.isRunning && !camera.isRecording) || camera.isPreparingRecording)
            .opacity((camera.isRunning || camera.isRecording) && !camera.isPreparingRecording ? 1 : 0.45)
            .accessibilityLabel(
                camera.isPreparingRecording
                    ? "Countdown in progress"
                    : (camera.isRecording ? "Stop recording" : "Start recording")
            )

            Spacer()

            Color.clear
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 58)
        .frame(height: 174)
        .background(Color.black)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Trigger") {
                    Toggle(
                        "Single continuous take",
                        isOn: $singleTake
                    )
                    Stepper(
                        countdownSeconds == 0
                            ? "Countdown: Off"
                            : "Countdown: \(countdownSeconds)s",
                        value: $countdownSeconds,
                        in: 0 ... 30
                    )
                    Text(
                        singleTake
                            ? "One recording covers both climbers and can be split afterwards."
                            : (countdownSeconds == 0
                                ? "Recording begins immediately when you press record."
                                : "Press record, walk away, then climb after the countdown.")
                    )
                    .font(.caption)
                }

                SwiftUI.Section("Framing") {
                    Toggle("Show framing guide", isOn: $showsFramingGuide)
                    Text("Use the guide to keep the complete route and wall visible.")
                        .font(.caption)
                    if alignmentSourceLabel != nil {
                        Toggle("Show wall alignment overlay", isOn: $showsAlignmentOverlay)
                        Text("The translucent wall is visible only in this live preview; it is never written into the recording.")
                            .font(.caption)
                    }
                }

                SwiftUI.Section("Camera") {
                    Text(camera.configurationNotes.joined(separator: " · "))
                        .font(.caption)
                    Button(camera.exposureLocked ? "Unlock AE/AF" : "Lock AE/AF") {
                        camera.exposureLocked
                            ? camera.unlockExposureAndFocus()
                            : camera.lockExposureAndFocus()
                    }
                    if !camera.status.isEmpty {
                        Text(camera.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = camera.locationNote {
                        // Stated, not warned about. A clip with no location is
                        // a session named by date, which is the ordinary
                        // outcome in a windowless gym — flagging it would put a
                        // warning on the majority case.
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    SwiftUI.Section("Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Capture settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func record() {
        error = nil
        Task {
            do {
                let url = try await camera.startRecording(
                    afterSeconds: countdownSeconds
                ) {
                    recordedOrientation = tilt.captureOrientation()
                }
                if singleTake {
                    recordedURL = url
                } else {
                    model.beginAddingVideo(
                        from: url,
                        role: role,
                        captureOrientation: recordedOrientation
                    )
                    dismiss()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The opposite role is always the alignment source, regardless of which
    /// climber was recorded first. This makes reference → attempt and attempt
    /// → reference the same flow.
    private func loadAlignmentTarget() async {
        let source: VideoRef? = switch role {
        case .reference: model.session?.attempts.first
        case .attempt: model.session?.reference
        }
        guard let source, let url = await model.videoURL(source) else { return }

        alignmentSourceLabel = source.label.isEmpty
            ? (source.role == .reference ? "reference" : "attempt")
            : source.label
        tilt.referenceOrientation = source.captureOrientation
        isLoadingAlignmentOverlay = true
        let image = await CaptureAlignmentOverlay.clearestWallFrame(url: url)
        guard !Task.isCancelled else { return }
        alignmentOverlay = image
        isLoadingAlignmentOverlay = false
        if image == nil {
            error = "Could not build the wall alignment overlay from the other clip. You can still record normally."
        }
    }
}

private struct CaptureAlignmentGuide: View {
    let sourceLabel: String
    let motionAvailable: Bool
    let hasMotionReference: Bool
    let deltaRollDegrees: Double
    let deltaPitchDegrees: Double

    private var combinedError: Double {
        hypot(deltaRollDegrees, deltaPitchDegrees)
    }

    private var isAligned: Bool {
        motionAvailable && hasMotionReference && combinedError < 3
    }

    private var statusColor: Color {
        guard motionAvailable, hasMotionReference else { return .white }
        if isAligned { return AppTheme.accent }
        return combinedError < 8 ? .yellow : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(isAligned ? "CAMERA ALIGNED" : "MATCH \(sourceLabel.uppercased())")
                    .font(.caption.weight(.black).monospaced())
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }

            if motionAvailable, hasMotionReference {
                Text(String(
                    format: "roll %+.1f°  pitch %+.1f°",
                    deltaRollDegrees,
                    deltaPitchDegrees
                ))
                .font(.caption.monospacedDigit().monospaced())
                .foregroundStyle(statusColor)
            } else {
                Text(hasMotionReference
                    ? "Motion unavailable — match the wall overlay"
                    : "Imported clip — match the wall overlay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.76), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.8), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Task 0.0b — a grid and route-coverage marks for straight-on framing.
struct FramingGuide: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Path { path in
                    for i in 1 ..< 3 {
                        let x = w * Double(i) / 3
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                        let y = h * Double(i) / 3
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(.white.opacity(0.5), lineWidth: 1)

                // Keep-clear margins: the homography needs wall features that
                // the climber is not standing in front of.
                Path { path in
                    path.addRect(CGRect(x: w * 0.15, y: h * 0.05, width: w * 0.7, height: h * 0.9))
                }
                .stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

                VStack {
                    Spacer()
                    Text("Whole route inside the dashed box · wall visible either side")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.5))
                        .padding(.bottom, 8)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
@Observable
final class TiltMonitor {
    private let motion = CMMotionManager()
    private(set) var isAvailable = false
    private(set) var currentOrientation: CaptureOrientation?
    var referenceOrientation: CaptureOrientation?
    var rollDegrees: Double = 0
    var pitchDegrees: Double = 0

    var deltaRollDegrees: Double {
        guard let referenceOrientation else { return 0 }
        return Self.wrappedDegrees(rollDegrees - referenceOrientation.rollDegrees)
    }

    var deltaPitchDegrees: Double {
        guard let referenceOrientation else { return 0 }
        return pitchDegrees - referenceOrientation.pitchDegrees
    }

    func start() {
        isAvailable = motion.isDeviceMotionAvailable
        guard isAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let gravity = data.gravity
            let orientation = CaptureOrientation(
                gravityX: gravity.x,
                gravityY: gravity.y,
                gravityZ: gravity.z
            )
            currentOrientation = orientation
            rollDegrees = orientation.rollDegrees
            pitchDegrees = orientation.pitchDegrees
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    func captureOrientation() -> CaptureOrientation? {
        currentOrientation
    }

    private static func wrappedDegrees(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let alignmentOverlay: CGImage?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.setAlignmentOverlay(alignmentOverlay)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.setAlignmentOverlay(alignmentOverlay)
    }

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private let alignmentLayer = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)

            clipsToBounds = true
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)

            alignmentLayer.contentsGravity = .resizeAspectFill
            alignmentLayer.opacity = 0.35
            alignmentLayer.masksToBounds = true
            alignmentLayer.contentsScale = UIScreen.main.scale
            layer.addSublayer(alignmentLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // The recorded wall and the live camera must use the exact same
            // viewport. Sharing bounds and aspect-fill geometry avoids the
            // subtle resize/center drift caused by two independent SwiftUI
            // layout passes.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            alignmentLayer.frame = bounds
            CATransaction.commit()
        }

        func setAlignmentOverlay(_ image: CGImage?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            alignmentLayer.contents = image
            alignmentLayer.isHidden = image == nil
            CATransaction.commit()
        }
    }
}

/// Task 0.0c, second option: one recording covering both climbers, split
/// afterwards. Camera pose is identical by construction, which sidesteps the
/// tripod-bump risk entirely.
struct SingleTakeSplitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let captureOrientation: CaptureOrientation?

    @State private var duration: Double = 0
    @State private var splitAt: Double = 0
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            SwiftUI.Section("Split point") {
                Slider(value: $splitAt, in: 0 ... max(duration, 1))
                Text(String(format: "%.1fs of %.1fs — everything before is the reference, everything after is the attempt.", splitAt, duration))
                    .font(.caption)
            }
            SwiftUI.Section {
                Button("Split and import both") { split() }
                    .disabled(working || duration <= 0)
                if working { ProgressView() }
                if let message { Text(message).font(.caption) }
            }
        }
        .navigationTitle("Split take")
        .task {
            let asset = AVURLAsset(url: url)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            splitAt = duration / 2
        }
    }

    private func split() {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let first = try await export(asset: AVURLAsset(url: url), range: CMTimeRange(start: .zero, duration: CMTime(seconds: splitAt, preferredTimescale: 600)))
                let second = try await export(asset: AVURLAsset(url: url), range: CMTimeRange(
                    start: CMTime(seconds: splitAt, preferredTimescale: 600),
                    duration: CMTime(seconds: max(0.1, duration - splitAt), preferredTimescale: 600)
                ))
                await model.addVideo(
                    from: first,
                    role: .reference,
                    captureOrientation: captureOrientation
                )
                await model.addVideo(
                    from: second,
                    role: .attempt,
                    captureOrientation: captureOrientation
                )
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
                message = "Imported both halves."
                dismiss()
            } catch {
                message = "Split failed: \(error.localizedDescription)"
            }
        }
    }

    private nonisolated func export(asset: sending AVAsset, range: CMTimeRange) async throws -> URL {
        let output = URL.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString).mov")
        nonisolated(unsafe) let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        guard let session else {
            throw CameraController.CaptureError.recordingFailed("cannot create export session")
        }
        session.timeRange = range
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        if let error = session.error { throw error }
        return output
    }
}

#Preview("Camera · reference") {
    NavigationStack {
        CaptureView(role: .reference)
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}

#endif
