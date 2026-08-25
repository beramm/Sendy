import SwiftUI

struct SideBySideOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        FeatureOnboardingPage(
            lines: [
                .init("SIDE BY SIDE", color: .white),
                .init("MOVE BY MOVE", color: AppTheme.accent)
            ],
            headlineOffset: CGPoint(x: 42, y: 108),
            bodyCopy: Text(
                "We line both climbs up \(Text("move for move.").bold())\nThen we tell you where your hips sat, where\nyour weight went, and which move cost you."
            ),
            bodyOffset: CGPoint(x: 42, y: 205),
            bodyWidth: 326,
            imageName: "SideBySideIllustration",
            imageSize: CGSize(width: 342, height: 432),
            imageOffset: CGPoint(x: 0, y: 295),
            action: action
        )
    }
}

#Preview("04 · Side by Side") {
    OnboardingPreviewContainer {
        SideBySideOnboardingPage(action: {})
    }
}
