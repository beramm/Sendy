#if os(iOS)
import SwiftUI
import AVFoundation
import CoreMotion

struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let role: VideoRef.Role

    @State private var camera = CameraController()
    @State private var tilt = TiltMonitor()
    @State private var countdownSeconds = 10
    @State private var singleTake = false
    @State private var recordedURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreview(session: camera.session)
                FramingGuide(rollDegrees: tilt.rollDegrees, pitchDegrees: tilt.pitchDegrees)
                if let countdown = camera.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 96, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                }
            }
            .frame(maxHeight: .infinity)

            Form {
                SwiftUI.Section("Trigger") {
                    Toggle("Single continuous take (both climbers, split afterwards)", isOn: $singleTake)
                    Stepper("Countdown: \(countdownSeconds)s", value: $countdownSeconds, in: 0 ... 30)
                    Text(singleTake
                         ? "One recording covers both climbers, so the camera pose is identical by construction. You split it afterwards."
                         : "Press record, walk away, climb after the countdown. The tripod is never touched between clips.")
                    .font(.caption)
                }

                SwiftUI.Section("Camera") {
                    Text(camera.configurationNotes.joined(separator: " · "))
                        .font(.caption)
                    Button(camera.exposureLocked ? "Unlock AE/AF" : "Lock AE/AF") {
                        camera.exposureLocked ? camera.unlockExposureAndFocus() : camera.lockExposureAndFocus()
                    }
                    if !camera.status.isEmpty {
                        Text(camera.status).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = camera.locationNote {
                        // Stated, not warned about. A clip with no location is
                        // a session named by date, which is the ordinary
                        // outcome in a windowless gym — flagging it would put a
                        // warning on the majority case.
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                SwiftUI.Section {
                    if camera.isRecording {
                        Button("Stop recording", role: .destructive) { camera.stopRecording() }
                    } else {
                        Button(singleTake ? "Record single take" : "Record \(role == .reference ? "reference" : "attempt")") {
                            record()
                        }
                        .disabled(!camera.isRunning)
                    }
                }

                if let error {
                    SwiftUI.Section("Error") { Text(error).foregroundStyle(.red) }
                }
            }
            .frame(height: 320)
        }
        .navigationTitle(role == .reference ? "Record reference" : "Record attempt")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await camera.start()
            tilt.start()
        }
        .onDisappear {
            camera.stop()
            tilt.stop()
        }
        .navigationDestination(item: $recordedURL) { url in
            if singleTake {
                SingleTakeSplitView(url: url)
            } else {
                CaptureReviewView(url: url, role: role)
            }
        }
    }

    private func record() {
        error = nil
        Task {
            do {
                let url = try await camera.startRecording(afterSeconds: countdownSeconds)
                recordedURL = url
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Task 0.0b — crude is fine. A grid for straight-on framing, a level
/// indicator, and route-coverage marks. It has to be legible in gym lighting,
/// not pretty.
struct FramingGuide: View {
    let rollDegrees: Double
    let pitchDegrees: Double

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
                    Text(levelText)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(isLevel ? .green : .red)
                        .padding(6)
                        .background(.black.opacity(0.5))
                        .padding(.top, 8)
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

    private var isLevel: Bool { abs(rollDegrees) < 2 && abs(pitchDegrees) < 5 }

    private var levelText: String {
        String(format: "roll %+.1f°  pitch %+.1f°%@", rollDegrees, pitchDegrees, isLevel ? "  LEVEL" : "")
    }
}

@MainActor
@Observable
final class TiltMonitor {
    private let motion = CMMotionManager()
    var rollDegrees: Double = 0
    var pitchDegrees: Double = 0

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // Portrait phone on a tripod: roll is the horizon tilt, pitch is how
            // far it is angled up the wall.
            self.rollDegrees = data.attitude.roll * 180 / .pi
            self.pitchDegrees = (data.attitude.pitch * 180 / .pi) - 90
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.session = session
        view.layer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.layer.session = session
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}

struct CaptureReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let role: VideoRef.Role

    var body: some View {
        Form {
            SwiftUI.Section("Recorded") {
                Text(url.lastPathComponent).font(.caption)
                Button("Use as \(role == .reference ? "reference" : "attempt")") {
                    Task {
                        await model.addVideo(from: url, role: role)
                        dismiss()
                    }
                }
                Button("Discard", role: .destructive) {
                    try? FileManager.default.removeItem(at: url)
                    dismiss()
                }
            }
        }
        .navigationTitle("Review")
    }
}

/// Task 0.0c, second option: one recording covering both climbers, split
/// afterwards. Camera pose is identical by construction, which sidesteps the
/// tripod-bump risk entirely.
struct SingleTakeSplitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL

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
                await model.addVideo(from: first, role: .reference)
                await model.addVideo(from: second, role: .attempt)
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

#endif
