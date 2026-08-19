import SwiftUI

struct WelcomeOnboardingPage: View {
    let motion: OnboardingMotionController
    let onEntranceCompleted: () -> Void
    let onCompleted: () -> Void

    var body: some View {
        ShakeOnboardingPage(
            firstLine: "YOU READY",
            accentLine: "TO SEND?",
            showsPrompt: true,
            usesWelcomeEntrance: true,
            motion: motion,
            onEntranceCompleted: onEntranceCompleted,
            onShakeCompleted: onCompleted
        )
    }
}

private struct WelcomeOnboardingPagePreview: View {
    @State private var motion = OnboardingMotionController()

    var body: some View {
        OnboardingPreviewContainer {
            WelcomeOnboardingPage(
                motion: motion,
                onEntranceCompleted: {},
                onCompleted: {}
            )
        }
    }
}

#Preview("01 · Welcome") {
    WelcomeOnboardingPagePreview()
}
