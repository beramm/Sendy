import SwiftUI

struct MoveBetterOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        FeatureOnboardingPage(
            lines: [
                .init("LEARN BETTER", color: .white),
                .init("MOVE BETTER", color: AppTheme.accent)
            ],
            headlineOffset: CGPoint(x: 42, y: 108),
            bodyCopy: Text(
                "Film a stronger climber on your project,\nthen film your go. Sendy finds what they\ndid \(Text("differently.").bold())"
            ),
            bodyOffset: CGPoint(x: 42, y: 199),
            bodyWidth: 322,
            imageName: "MoveBetterIllustration",
            imageSize: CGSize(width: 312, height: 454),
            imageOffset: CGPoint(x: 44, y: 276),
            action: action
        )
    }
}

#Preview("03 · Move Better") {
    OnboardingPreviewContainer {
        MoveBetterOnboardingPage(action: {})
    }
}
