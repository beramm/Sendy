#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import Observation
import CoreLocation

/// The capture side of the harness: a dumb recorder with the settings the
/// homography step depends on.
///
/// Three of these are not preferences — they are what makes registration
/// possible at all:
/// - **stabilization off**, because it warps the frame per-frame
/// - **AE/AF locked**, because exposure drift changes apparent contrast between
///   the two clips and breaks feature matching
/// - **1× lens locked**, because switching lenses changes intrinsics mid-shoot
@MainActor
@Observable
final class CameraController: NSObject {
    /// `AVCaptureSession` is thread-safe by contract but not `Sendable`, and it
    /// must be started off the main actor because `startRunning()` blocks.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated private let sessionQueue = DispatchQueue(label: "capture.session")
    nonisolated(unsafe) private let output = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var continuation: CheckedContinuation<URL, Error>?

    var isRunning = false
    var isRecording = false
    var countdown: Int?
    var status: String = ""
    var configurationNotes: [String] = []
    var lastRecordingURL: URL?
    var exposureLocked = false
    /// Whether the last recording carried a coordinate. Shown on the capture
    /// screen as a plain statement of what the clip knows — **not** as a
    /// warning. A clip with no location is a session named by date, which is
    /// the ordinary indoor outcome.
    var lastRecordingHadLocation = false
    /// Nil before the first recording. After one, says whether the clip carries
    /// a coordinate — which decides whether the session can be named after the
    /// gym or falls back to its date.
    var locationNote: String? {
        guard lastRecordingURL != nil else { return nil }
        return lastRecordingHadLocation
            ? "Location saved with the clip — the session can be named after the gym."
            : "No location on this clip; the session is named by date."
    }

    private let locationProvider = CaptureLocationProvider()

    enum CaptureError: Error, LocalizedError {
        case noCamera
        case recordingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: "No usable rear camera."
            case .recordingFailed(let s): "Recording failed: \(s)"
            }
        }
    }

    func start() async {
        guard !isRunning else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            status = "Camera access denied. Enable it in Settings to record."
            return
        }
        do {
            try configure()
            await withCheckedContinuation { continuation in
                sessionQueue.async { [session] in
                    session.startRunning()
                    continuation.resume()
                }
            }
            isRunning = true
            status = "Ready."
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        sessionQueue.async { [session] in session.stopRunning() }
        isRunning = false
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // 1× wide angle only. A dual/triple camera would switch lenses mid-clip.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        device = camera
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(output) else { throw CaptureError.recordingFailed("cannot add movie output") }
        session.addOutput(output)

        var notes: [String] = []

        // 1080p60: contact detection is velocity-based, so temporal resolution
        // matters more than spatial.
        if let format = Self.bestFormat(for: camera) {
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = format
                let duration = CMTime(value: 1, timescale: 60)
                if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 }) {
                    camera.activeVideoMinFrameDuration = duration
                    camera.activeVideoMaxFrameDuration = duration
                    notes.append("1080p60")
                } else {
                    notes.append("1080p (60fps unavailable on this device)")
                }
                camera.unlockForConfiguration()
            } catch {
                notes.append("Could not set 1080p60: \(error.localizedDescription)")
            }
        } else {
            session.sessionPreset = .high
            notes.append("No 1080p60 format found; using the default preset.")
        }

        // Stabilization off. This is the single most likely thing to ruin a
        // shoot, and it is silent until Phase 2.
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
                notes.append("stabilization off")
            }
        }
        configurationNotes = notes
    }

    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1920 && dimensions.height == 1080
        }
        // Prefer one that can actually do 60fps.
        return formats.first { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 } }
            ?? formats.first
    }

    /// Locks exposure and focus at the current values. Long-press equivalent.
    func lockExposureAndFocus() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
            exposureLocked = true
            status = "AE/AF/WB locked."
        } catch {
            status = "Could not lock exposure: \(error.localizedDescription)"
        }
    }

    func unlockExposureAndFocus() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
            exposureLocked = false
            status = "AE/AF unlocked."
        } catch {
            status = error.localizedDescription
        }
    }

    /// Hands-free trigger (task 0.0c). Pressing record on a tripod-mounted phone
    /// risks bumping it, and a bumped tripod is the one thing the homography
    /// cannot absorb — so recording starts after a countdown, not on touch.
    func startRecording(afterSeconds delay: Int) async throws -> URL {
        guard isRunning else { throw CaptureError.recordingFailed("camera not running") }

        // `AVCaptureMovieFileOutput` writes no location of its own, so the
        // recording path has to attach one — otherwise a clip filmed inside the
        // app knows less about where it was shot than one imported from Photos.
        //
        // Started **before** the countdown and awaited after it, so the fix
        // costs nothing: the user is walking to the wall for those seconds
        // anyway. Taken after the countdown instead, a phone with no signal
        // would sit for the whole location timeout between "1" and the camera
        // actually rolling, which is exactly when the climber has started.
        let location = Task { @MainActor [weak self] in await self?.attachLocationMetadata() }

        for remaining in stride(from: delay, through: 1, by: -1) {
            countdown = remaining
            try? await Task.sleep(for: .seconds(1))
        }
        countdown = nil

        // Awaited rather than abandoned: `output.metadata` has to be set before
        // `startRecording`, or it is not in the file.
        await location.value

        let url = URL.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).mov")
        isRecording = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        output.stopRecording()
    }

    /// Writes the current coordinate into the movie as ISO 6709, the same field
    /// the Camera app writes and the import path already knows how to read.
    ///
    /// Failure is silent by design. No fix, denied permission, or no signal all
    /// end with a clip that has no location, and every one of those is a
    /// session named by date rather than an error to report.
    private func attachLocationMetadata() async {
        guard let coordinate = await locationProvider.currentCoordinate() else {
            output.metadata = []
            lastRecordingHadLocation = false
            return
        }
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as any NSCopying & NSObjectProtocol
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = ISO6709.string(for: coordinate) as NSString
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        output.metadata = [item]
        lastRecordingHadLocation = true
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.lastRecordingURL = outputFileURL
            let continuation = self.continuation
            self.continuation = nil
            if let error {
                continuation?.resume(throwing: CaptureError.recordingFailed(error.localizedDescription))
            } else {
                continuation?.resume(returning: outputFileURL)
            }
        }
    }
}
#endif
