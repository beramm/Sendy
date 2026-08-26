#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit
import CoreMotion
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
    @State private var showingSettings = false
    @State private var showsFramingGuide = false
    @State private var showsAlignmentOverlay = true
    @State private var alignmentOverlay: CGImage?
    @State private var isLoadingAlignmentOverlay = false
    @State private var alignmentSourceLabel: String?
    @State private var recordedOrientation: CaptureOrientation?
    /// The instructional card. Auto-hides so it never covers the wall while the
    /// framing it describes is being done; `?` brings it back.
    @State private var showsFramingCard = true
    @State private var framingCardTask: Task<Void, Never>?

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
                    if camera.isRecording {
                        VStack {
                            recordingTimer.padding(.top, 14)
                            Spacer()
                        }
                    }

                    if showsFramingCard, !camera.isRecording {
                        FramingCard()
                    }

                    // Floating over the preview's lower edge, with the black
                    // control bar gone. Kept close to the bottom so it occludes
                    // as little of a low start as possible, and with no scrim
                    // behind it.
                    VStack {
                        Spacer()
                        shutter.padding(.bottom, 24)
                    }
                }
                .frame(maxHeight: .infinity)
                .clipped()
            }
        }
        .foregroundStyle(.white)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Volume buttons and, on the phones that have it, Camera Control — one
        // API for both. Reaching the on-screen shutter means touching the
        // tripod, which is the one thing the capture protocol asks you not to
        // do between clips.
        .onCameraCaptureEvent { event in
            guard event.phase == .ended else { return }
            toggleRecording()
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .task {
            tilt.start()
            await camera.start()
            await loadAlignmentTarget()
            showFramingCard()
        }
        .onDisappear {
            framingCardTask?.cancel()
            camera.stop()
            tilt.stop()
        }
        .onChange(of: camera.isRecording) { _, recording in
            // Never let the card sit over the wall while the wall is being
            // filmed — the auto-hide usually gets there first, but a climber
            // who presses record inside four seconds would otherwise film
            // behind a panel.
            if recording {
                framingCardTask?.cancel()
                showsFramingCard = false
            }
        }
        .navigationDestination(item: $recordedURL) { url in
            SingleTakeSplitView(
                url: url,
                captureOrientation: recordedOrientation
            )
        }
    }

    private var captureHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                Button {
                    dismiss()
                } label: {
                    // A chevron, not the comp's arrow: every other back
                    // affordance in the app is a chevron, and this screen only
                    // draws its own because it hides the navigation bar to make
                    // room for the progress bars and title.
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                // Visible but dead while recording. Stopping is the shutter's
                // job; popping mid-recording would leave the file to be
                // finalised on a view that is gone.
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.35 : 0.8)
                .accessibilityLabel("Back")
                .accessibilityHint(camera.isRecording ? "Stop recording first" : "")

                HStack(spacing: 10) {
                    Capsule().fill(AppTheme.accent)
                    Capsule().fill(role == .attempt ? AppTheme.accent : AppTheme.accent.opacity(0.25))
                }
                .frame(height: 8)

                Button {
                    // Opens the settings form, which is the only home for the
                    // countdown, single-take and overlay toggles. The framing
                    // card shows itself on entry and needs no button of its
                    // own; the form's Framing section repeats its advice for
                    // anyone who missed it.
                    showingSettings = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 24, weight: .regular))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture settings")
            }

            Text(role == .reference ? "Reference Climber" : "Your Climb")
                .monoLabel(size: 18, weight: .medium)
        }
        .padding(.horizontal, 18)
        .frame(height: 84)
        .background(Color.black)
    }

    /// The shutter, floating over the bottom of the preview.
    ///
    /// Four states, and only the idle one is lime. A disc that stayed lime while
    /// recording is a bug nobody notices until a climb is lost.
    private var shutter: some View {
        Button(action: toggleRecording) {
            ZStack {
                if camera.isRecording {
                    Circle()
                        .fill(.white)
                        .frame(width: 86, height: 86)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.red)
                        .frame(width: 34, height: 34)
                } else {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 86, height: 86)
                        .overlay(Circle().stroke(.black, lineWidth: 5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.isRunning && !camera.isRecording)
        .opacity(camera.isRunning || camera.isRecording ? 1 : 0.45)
        .accessibilityLabel(
            camera.isPreparingRecording
                ? "Cancel countdown"
                : (camera.isRecording ? "Stop recording" : "Start recording")
        )
    }

    /// One button, three meanings: idle starts, counting down cancels,
    /// recording stops. Kept in one place so the shutter and the hardware
    /// handler cannot disagree.
    private func toggleRecording() {
        if camera.isRecording {
            camera.stopRecording()
        } else if camera.isPreparingRecording {
            camera.cancelCountdown()
        } else {
            record()
        }
    }

    /// Elapsed recording time, read from the output rather than a wall clock so
    /// it describes the file rather than the session.
    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(Self.timecode(camera.recordedSeconds))
                    .monoLabel(size: 15)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func showFramingCard() {
        framingCardTask?.cancel()
        showsFramingCard = true
        framingCardTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showsFramingCard = false
        }
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
                    // The same three rules the framing card states on entry,
                    // kept here because the card fades and this does not.
                    Text("Full wall in frame · square to the wall · tripod fixed")
                        .monoLabel(size: 12, weight: .regular)
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
/// Instructional, and distinct from ``FramingGuide``.
///
/// The guide is a *live* overlay whose keep-clear box exists because
/// `WallAligner` registers on wall texture the climber is not standing in front
/// of. This is three words of advice, shown once and then out of the way.
private struct FramingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let advice = ["Full Wall", "Front-On", "Use Tripod"]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.75))

            Text("Frame your shot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            // Plain monospaced text, no pills: the card is the surface.
            HStack(spacing: 16) {
                ForEach(advice.prefix(2), id: \.self) { chip in
                    Text(chip).monoLabel(size: 14, weight: .regular)
                }
            }
            Text(advice[2]).monoLabel(size: 14, weight: .regular)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .transition(reduceMotion ? .identity : .opacity)
    }
}

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
            // Fit, not fill: what the preview shows is exactly what the file
            // contains. Filling would crop the preview while
            // `AVCaptureMovieFileOutput` still wrote the full sensor frame, so
            // the framing advice on this screen would be describing a frame
            // nobody sees. Cropping the *recording* to match instead would throw
            // away the side wall texture `WallAligner` registers on.
            previewLayer.videoGravity = .resizeAspect
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
