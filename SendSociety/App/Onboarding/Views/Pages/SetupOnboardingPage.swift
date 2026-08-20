import SwiftUI

struct SetupOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        IllustratedOnboardingPage(
            lines: [
                .init("PREPARE", color: .white),
                .init("YOUR", color: .white),
                .init("TRUSTY", color: AppTheme.accent),
                .init("TRIPOD!", color: AppTheme.accent)
            ],
            headlineOffset: CGPoint(x: 53, y: 73),
            imageName: "TripodSetupIllustration",
            imageSize: CGSize(width: 402, height: 373),
            imageOffset: CGPoint(x: 0, y: 337),
            buttonTitle: "YUP READY!",
            action: action
        )
    }
}

#Preview("02 · Set Up") {
    OnboardingPreviewContainer {
        SetupOnboardingPage(action: {})
    }
}
