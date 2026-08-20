import SwiftUI

struct BetterClimberOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        IllustratedOnboardingPage(
            lines: [
                .init("FIND A", color: .white),
                .init("BETTER", color: AppTheme.accent),
                .init("CLIMBER", color: AppTheme.accent)
            ],
            headlineOffset: CGPoint(x: 44, y: 102),
            imageName: "BetterClimberIllustration",
            imageSize: CGSize(width: 263, height: 342),
            imageOffset: CGPoint(x: 75, y: 318),
            buttonTitle: "THERE ARE TONS!",
            action: action
        )
    }
}

#Preview("04 · Find Better Climber") {
    OnboardingPreviewContainer {
        BetterClimberOnboardingPage(action: {})
    }
}
