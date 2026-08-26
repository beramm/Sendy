import SwiftUI

/// The animated splash, shown for a beat after the launch screen hands over.
///
/// The launch screen (`LaunchScreen.storyboard`) paints the same black
/// background, so the handover is invisible: the phone goes from tap straight
/// to this, with no flash of a different colour on the way.
///
/// **It delays every cold start**, which is why it is short and why it is the
/// only artificial wait in the app. Anything much past a second is felt at a
/// gym, where the app is opened between attempts.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called when the splash has had its beat and the app should take over.
    let onFinished: () -> Void

    @State private var settled = false
    @State private var jiggling = false

    /// Measured from the view appearing, so it covers the entrance as well as
    /// the hold. The spring takes ~0.5s to settle the figure, which leaves a
    /// full second of it sitting there jiggling — at 0.95s total the climber
    /// had barely landed before the app took over.
    private let dwell = Duration.milliseconds(1500)

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { proxy in
                Image("JigglingClimberIllustration")
                    .resizable()
                    .scaledToFit()
                    // Fills the frame the way the reference does, rather than
                    // sitting small in the middle of it.
                    .frame(width: proxy.size.width * 0.78)
                    // The figure is already a climber mid-shake, so the motion
                    // is a small rotation about its own centre — a wobble, not
                    // a slide or a spin. Anything larger fights the drawing.
                    .rotationEffect(.degrees(jiggling ? 2.5 : -2.5))
                    .scaleEffect(settled ? 1 : 0.88)
                    .opacity(settled ? 1 : 0)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    // The name is not shown, so it has to be spoken. Without
                    // this the splash is a silent screen to VoiceOver.
                    .accessibilityLabel(AppNaming.displayName)
            }
        }
        .task {
            // Reduce Motion still gets the splash, just without the movement —
            // cutting it entirely would make the app start differently for
            // those users for no reason.
            if reduceMotion {
                settled = true
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.35)) { settled = true }
                withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                    jiggling = true
                }
            }
            try? await Task.sleep(for: dwell)
            onFinished()
        }
    }
}

#Preview {
    SplashView {}
        .preferredColorScheme(.dark)
}
