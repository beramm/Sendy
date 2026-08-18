@preconcurrency import CoreMotion
import Observation
import SwiftUI
import UIKit

/// Owns the live motion session for onboarding. Keeping this out of the view
/// hierarchy means changing pages does not briefly tear down Core Motion.
@MainActor
@Observable
final class OnboardingMotionController {
    var visualTranslation = CGSize.zero
    var visualRotation = 0.0
    var alignmentTranslation = CGSize(width: -28, height: -24)
    var isAligned = false
    private(set) var isMotionAvailable = false
    private(set) var shakeEvent = 0
    private(set) var shakeFallRotation = 10.0

    private let motionManager = CMMotionManager()
    private var alignmentBaseline: CMQuaternion?
    private var alignmentStartedAt: Date?
    private var lastShakeAt = Date.distantPast
    private var lastShakeHapticAt = Date.distantPast
    private var acceptShakeAfter = Date.distantFuture
    private var sustainedShakeStartedAt: Date?
    private var lastSustainedShakeActivityAt: Date?
    private var simulatedSustainedShakeTask: Task<Void, Never>?
    private var isAligning = false
    private var isShakeDetectionArmed = false
    private var alignmentHapticZone = 0
    private let shakeFeedbackGenerator = UIImpactFeedbackGenerator(style: .rigid)

    func start() {
        guard !motionManager.isDeviceMotionActive else { return }
        isMotionAvailable = motionManager.isDeviceMotionAvailable
        guard isMotionAvailable else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, _ in
            guard let motion else { return }
            let sample = MotionSample(
                accelerationX: motion.userAcceleration.x,
                accelerationY: motion.userAcceleration.y,
                accelerationZ: motion.userAcceleration.z,
                attitude: motion.attitude.quaternion
            )
            Task { @MainActor [weak self] in
                self?.consume(sample)
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    /// The Welcome entrance is intentionally presentation-only. Core Motion is
    /// fully stopped so no queued visual shake or haptic can affect it.
    func pauseForEntrance() {
        disarmShakeDetection()
        stop()
        visualTranslation = .zero
        visualRotation = 0
    }

    func armShakeDetection(after delay: TimeInterval = 0.45) {
        isShakeDetectionArmed = true
        acceptShakeAfter = Date().addingTimeInterval(delay)
        lastShakeAt = .distantPast
        lastShakeHapticAt = .distantPast
        resetSustainedShakeProgress()
        shakeFeedbackGenerator.prepare()
    }

    func disarmShakeDetection() {
        isShakeDetectionArmed = false
        simulatedSustainedShakeTask?.cancel()
        simulatedSustainedShakeTask = nil
        resetSustainedShakeProgress()
    }

    /// UIKit's shake event makes the interaction work with Xcode's Simulator
    /// “Shake” command as well as with physical Core Motion samples.
    func registerSystemShake() {
        guard isShakeDetectionArmed, Date() >= acceptShakeAfter else { return }
        switch OnboardingConfiguration.shakeTriggerMode {
        case .accelerationThreshold:
            registerShakeIfReady()
        case .sustainedDuration:
            // Simulator has no continuous Core Motion samples. Treat its Shake
            // command as a simulated sustained shake with the same duration.
            guard !isMotionAvailable else { return }
            simulatedSustainedShakeTask?.cancel()
            simulatedSustainedShakeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: .seconds(OnboardingConfiguration.sustainedShakeDuration)
                )
                guard !Task.isCancelled else { return }
                self?.registerShakeIfReady()
            }
        }
    }

    func prepareForAlignment() {
        isAligning = true
        isAligned = false
        alignmentStartedAt = nil
        alignmentHapticZone = 0
        alignmentTranslation = CGSize(width: -28, height: -24)
        // Always calibrate from a fresh sample on Align. The quaternion-based
        // delta remains stable when the phone starts upright, where Euler pitch
        // is close to its ±90° singularity.
        alignmentBaseline = nil
    }

    func finishAlignment() {
        isAligning = false
    }

    /// A drag is intentionally retained as a simulator and accessibility
    /// fallback; on device, the gyro updates the same translation continuously.
    func adjustAlignment(by translation: CGSize) {
        guard !isAligned else { return }
        alignmentTranslation = CGSize(
            width: Self.clamp(translation.width, to: -90 ... 90),
            height: Self.clamp(translation.height, to: -90 ... 90)
        )
        evaluateAlignment()
    }

    func finishManualAlignment() {
        guard hypot(alignmentTranslation.width, alignmentTranslation.height) <= 13 else { return }
        isAligned = true
        alignmentTranslation = .zero
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func consume(_ sample: MotionSample) {
        let horizontalMovement = Self.clamp(sample.accelerationX * 42, to: -32 ... 32)
        let verticalMovement = Self.clamp(-sample.accelerationY * 42, to: -32 ... 32)
        visualTranslation = switch OnboardingConfiguration.shakeMovement {
        case .horizontal:
            CGSize(width: horizontalMovement, height: 0)
        case .vertical:
            CGSize(width: 0, height: verticalMovement)
        case .both:
            CGSize(width: horizontalMovement, height: verticalMovement)
        }
        visualRotation = switch OnboardingConfiguration.shakeRotation {
        case .on:
            Self.clamp(sample.accelerationX * 15, to: -14 ... 14)
        case .off:
            0
        }

        let acceleration = sqrt(
            sample.accelerationX * sample.accelerationX
                + sample.accelerationY * sample.accelerationY
                + sample.accelerationZ * sample.accelerationZ
        )
        let fallDirectionSource = abs(sample.accelerationX) >= 0.05
            ? sample.accelerationX
            : sample.accelerationY
        let fallDirection = fallDirectionSource >= 0 ? 1.0 : -1.0
        shakeFallRotation = fallDirection
            * Self.clamp(acceleration * 12, to: 6 ... 14)

        updateShakeHaptics(for: acceleration)
        evaluateShakeTrigger(for: acceleration)

        guard isAligning, !isAligned else { return }
        if alignmentBaseline == nil {
            alignmentBaseline = sample.attitude
        }
        guard let baseline = alignmentBaseline else { return }
        let rotation = Self.relativeRotationVector(
            from: baseline,
            to: sample.attitude
        )

        alignmentTranslation = CGSize(
            width: Self.clamp(-28 + rotation.y * 130, to: -90 ... 90),
            height: Self.clamp(-24 + rotation.x * 130, to: -90 ... 90)
        )
        evaluateAlignment()
    }

    private func registerShakeIfReady() {
        let now = Date()
        guard now >= acceptShakeAfter,
              isShakeDetectionArmed,
              now.timeIntervalSince(lastShakeAt) > 0.8 else { return }
        lastShakeAt = now
        shakeEvent += 1
    }

    private func evaluateShakeTrigger(for acceleration: Double) {
        let now = Date()
        guard isShakeDetectionArmed, now >= acceptShakeAfter else { return }

        switch OnboardingConfiguration.shakeTriggerMode {
        case .accelerationThreshold:
            if acceleration > 0.72 {
                registerShakeIfReady()
            }
        case .sustainedDuration:
            updateSustainedShakeProgress(acceleration: acceleration, now: now)
        }
    }

    private func updateSustainedShakeProgress(acceleration: Double, now: Date) {
        let activityThreshold = 0.18
        let interruptionTolerance = 0.32

        if acceleration > activityThreshold {
            if let lastActivity = lastSustainedShakeActivityAt,
               now.timeIntervalSince(lastActivity) > interruptionTolerance {
                sustainedShakeStartedAt = now
            } else if sustainedShakeStartedAt == nil {
                sustainedShakeStartedAt = now
            }
            lastSustainedShakeActivityAt = now

            if let startedAt = sustainedShakeStartedAt,
               now.timeIntervalSince(startedAt)
                   >= OnboardingConfiguration.sustainedShakeDuration {
                resetSustainedShakeProgress()
                registerShakeIfReady()
            }
        } else if let lastActivity = lastSustainedShakeActivityAt,
                  now.timeIntervalSince(lastActivity) > interruptionTolerance {
            resetSustainedShakeProgress()
        }
    }

    private func resetSustainedShakeProgress() {
        sustainedShakeStartedAt = nil
        lastSustainedShakeActivityAt = nil
    }

    private func updateShakeHaptics(for acceleration: Double) {
        let now = Date()
        guard isShakeDetectionArmed,
              now >= acceptShakeAfter,
              acceleration > 0.16,
              now.timeIntervalSince(lastShakeHapticAt) >= 0.05 else { return }

        lastShakeHapticAt = now
        shakeFeedbackGenerator.impactOccurred(intensity: 1)
        shakeFeedbackGenerator.prepare()
    }

    private func evaluateAlignment() {
        let distance = hypot(alignmentTranslation.width, alignmentTranslation.height)
        updateAlignmentHaptics(for: distance)
        if distance <= 13 {
            let now = Date()
            if let alignmentStartedAt,
               now.timeIntervalSince(alignmentStartedAt) >= 0.45 {
                isAligned = true
                alignmentTranslation = .zero
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if alignmentStartedAt == nil {
                alignmentStartedAt = now
            }
        } else {
            alignmentStartedAt = nil
        }
    }

    private func updateAlignmentHaptics(for distance: Double) {
        let newZone: Int
        switch distance {
        case ...13: newZone = 3
        case ...25: newZone = 2
        case ...42: newZone = 1
        default: newZone = 0
        }

        guard newZone > alignmentHapticZone else {
            if newZone == 0 { alignmentHapticZone = 0 }
            return
        }

        alignmentHapticZone = newZone
        let style: UIImpactFeedbackGenerator.FeedbackStyle = newZone == 3 ? .rigid : .light
        UIImpactFeedbackGenerator(style: style).impactOccurred(
            intensity: newZone == 3 ? 0.9 : 0.55
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Returns the shortest local rotation from `baseline` to `current` as an
    /// axis-angle vector in radians. Unlike absolute roll/pitch subtraction,
    /// this remains continuous when the phone is upright or face-up.
    private static func relativeRotationVector(
        from baseline: CMQuaternion,
        to current: CMQuaternion
    ) -> (x: Double, y: Double, z: Double) {
        let baselineLength = sqrt(
            baseline.w * baseline.w
                + baseline.x * baseline.x
                + baseline.y * baseline.y
                + baseline.z * baseline.z
        )
        let currentLength = sqrt(
            current.w * current.w
                + current.x * current.x
                + current.y * current.y
                + current.z * current.z
        )
        guard baselineLength > .ulpOfOne, currentLength > .ulpOfOne else {
            return (0, 0, 0)
        }

        let inverseBaseline = CMQuaternion(
            x: -baseline.x / baselineLength,
            y: -baseline.y / baselineLength,
            z: -baseline.z / baselineLength,
            w: baseline.w / baselineLength
        )
        let normalizedCurrent = CMQuaternion(
            x: current.x / currentLength,
            y: current.y / currentLength,
            z: current.z / currentLength,
            w: current.w / currentLength
        )
        var relative = multiply(inverseBaseline, normalizedCurrent)

        // q and -q encode the same attitude. Keeping w positive selects the
        // shortest rotation and prevents sign flips between adjacent samples.
        if relative.w < 0 {
            relative = CMQuaternion(
                x: -relative.x,
                y: -relative.y,
                z: -relative.z,
                w: -relative.w
            )
        }

        let vectorLength = sqrt(
            relative.x * relative.x
                + relative.y * relative.y
                + relative.z * relative.z
        )
        guard vectorLength > 0.000_001 else {
            return (relative.x * 2, relative.y * 2, relative.z * 2)
        }

        let angle = 2 * atan2(vectorLength, relative.w)
        let scale = angle / vectorLength
        return (
            relative.x * scale,
            relative.y * scale,
            relative.z * scale
        )
    }

    private static func multiply(
        _ lhs: CMQuaternion,
        _ rhs: CMQuaternion
    ) -> CMQuaternion {
        CMQuaternion(
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }
}

private struct MotionSample: Sendable {
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let attitude: CMQuaternion
}

/// Receives the standard UIKit motion event, including Simulator shakes.
struct DeviceShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: () -> Void

    init(onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake()
        }
        super.motionEnded(motion, with: event)
    }
}
