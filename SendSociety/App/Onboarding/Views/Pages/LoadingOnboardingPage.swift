import SwiftUI

struct LoadingOnboardingPage: View {
    let motion: OnboardingMotionController
    let onEntranceCompleted: () -> Void
    let onCompleted: () -> Void

    var body: some View {
        ShakeOnboardingPage(
            firstLine: "SHAKE TO",
            accentLine: "REVEAL!",
            showsPrompt: false,
            usesWelcomeEntrance: false,
            motion: motion,
            onEntranceCompleted: onEntranceCompleted,
            onShakeCompleted: onCompleted
        )
    }
}

private struct LoadingOnboardingPagePreview: View {
    @State private var motion = OnboardingMotionController()

    var body: some View {
        OnboardingPreviewContainer {
            LoadingOnboardingPage(
                motion: motion,
                onEntranceCompleted: {},
                onCompleted: {}
            )
        }
    }
}

#Preview("07 · Loading") {
    LoadingOnboardingPagePreview()
}
