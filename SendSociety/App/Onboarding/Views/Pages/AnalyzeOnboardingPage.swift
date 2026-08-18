import SwiftUI

struct AnalyzeOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    Image("ComparisonIllustration")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 359)
                        .offset(x: 0, y: 113)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    AnalyzeSoundEffectLabel(text: "bip bip", rotation: -14)
                        .offset(x: 62, y: 84)
                        .onboardingPageAnimation(.supportingContent, phase: animation.phase)

                    AnalyzeSoundEffectLabel(text: "bup bap", rotation: 14)
                        .offset(x: 277, y: 508)
                        .onboardingPageAnimation(.supportingContent, phase: animation.phase)

                    OnboardingHeadline(
                        lines: [
                            .init("AND", color: .white),
                            .init("COMPARE!", color: OnboardingPalette.accent)
                        ]
                    )
                    .offset(x: 151, y: 596)
                    .onboardingPageAnimation(.headline, phase: animation.phase)

                    OnboardingButton(title: "FEELIN’ V100!", action: animation.action)
                        .offset(x: 45, y: 755)
                        .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

private struct AnalyzeSoundEffectLabel: View {
    let text: String
    let rotation: Double

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .fixedSize()
            .rotationEffect(.degrees(rotation), anchor: .center)
            .accessibilityHidden(true)
    }
}

#Preview("05 · Analyze") { 
    OnboardingPreviewContainer {
        AnalyzeOnboardingPage(action: {})
    }
}
