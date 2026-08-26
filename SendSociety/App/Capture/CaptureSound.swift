#if os(iOS)
import AudioToolbox
import UIKit

/// The countdown ticks and the start beep.
///
/// The climber presses record, walks to the wall and climbs — from ten feet
/// away, on a tripod, a disc changing colour is not a signal. Sound is the only
/// channel that reaches someone already tied into the start position, which
/// makes this flow legibility rather than polish.
///
/// System tones rather than shipped audio assets: a bespoke beep in a debug
/// harness is effort where the project rules say not to spend it.
///
/// **The silent switch defeats both, and that is accepted.** `AudioServices`
/// tones respect the ringer switch, so a climber on silent hears nothing.
/// Overriding a hardware switch someone deliberately set is user-hostile, so
/// the on-screen countdown stays large enough to read from the wall and the
/// sound is an enhancement rather than the only channel.
@MainActor
enum CaptureSound {
    /// One per remaining countdown second. Lower and shorter than ``start()``.
    ///
    /// The gap between the two is **pitch, not loudness** — a gym is loud
    /// enough that a quieter tick simply disappears, whereas a different pitch
    /// survives.
    static func tick() {
        AudioServicesPlaySystemSound(1103)
        impact.impactOccurred(intensity: 0.6)
    }

    /// Fired when capture is genuinely live, never when the button was tapped.
    static func start() {
        AudioServicesPlaySystemSound(1113)
        // Covers the phone-in-hand case with the volume down. It cannot cross a
        // room, so it supplements the beep rather than replacing it.
        notification.notificationOccurred(.success)
    }

    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()
}
#endif
