import SwiftUI

struct GoClimbOnboardingPage: View {
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(
                        lines: [
                            .init("GO CLIMB", color: .white),
                            .init("YOUR WAY!", color: OnboardingPalette.accent)
                        ]
                    )
                    .offset(x: 52, y: 124)
                    .onboardingPageAnimation(.headline, phase: animation.phase)

                    Image("ClimbingIllustration")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 305, height: 278)
                        .offset(x: 45, y: 339)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    Text("#@#$*")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(x: 258, y: 290)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.supportingContent, phase: animation.phase)

                    Text("GET ME DOWN!")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .rotationEffect(.degrees(14))
                        .offset(x: 171, y: 617)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.supportingContent, phase: animation.phase)

                    OnboardingButton(title: "CANT WAIT!", action: animation.action)
                        .offset(x: 45, y: 755)
                        .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

#Preview("03 · Go Climb") {
    OnboardingPreviewContainer {
        GoClimbOnboardingPage(action: {})
    }
}
