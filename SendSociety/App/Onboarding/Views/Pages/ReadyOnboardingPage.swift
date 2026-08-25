import SwiftUI

struct ReadyOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    Text(
                        "LET’S \(Text("SEND!").foregroundColor(AppTheme.accent))"
                    )
                        .foregroundColor(.white)
                        .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                        .tracking(-1.2)
                        .lineLimit(1)
                        .frame(width: 402)
                        .offset(y: 153)
                        .onboardingPageAnimation(.headline, phase: animation.phase)

                    Image("ReadyIllustration")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 307, height: 355)
                        .offset(x: 48, y: 238)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    PrimaryButton(
                        title: "START COMPARING",
                        action: animation.action
                    )
                    .offset(x: 45, y: 755)
                    .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

#Preview("05 · Ready") {
    OnboardingPreviewContainer {
        ReadyOnboardingPage(action: {})
    }
}
