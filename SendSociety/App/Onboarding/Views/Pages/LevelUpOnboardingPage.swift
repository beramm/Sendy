import SwiftUI

struct LevelUpOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        FeatureOnboardingPage(
            lines: [
                .init("LEVEL UP", color: AppTheme.accent),
                .init("YOUR CLIMBS", color: .white)
            ],
            headlineOffset: CGPoint(x: 42, y: 128),
            bodyCopy: Text(
                "Improve your skills by \(Text("comparing").bold()) your\nclimbs with a \(Text("better climber.").bold())"
            ),
            bodyOffset: CGPoint(x: 42, y: 227),
            bodyWidth: 318,
            imageName: "LevelUpIllustration",
            imageSize: CGSize(width: 338, height: 345),
            imageOffset: CGPoint(x: 32, y: 320),
            action: action
        )
    }
}

#Preview("02 · Level Up") {
    OnboardingPreviewContainer {
        LevelUpOnboardingPage(action: {})
    }
}
