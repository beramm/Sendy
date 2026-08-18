import SwiftUI

struct AlignRouteOnboardingPage: View {
    let motion: OnboardingMotionController
    let action: () -> Void

    @State private var dragOrigin = CGSize(width: -28, height: -24)

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(
                        lines: [
                            .init("ALIGN THE", color: .white),
                            .init("ROUTE!", color: OnboardingPalette.accent)
                        ]
                    )
                    .offset(x: 49, y: 83)
                    .onboardingPageAnimation(.headline, phase: animation.phase)

                    Group {
                        Text("TOP!")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(-5))
                            .offset(x: 278, y: 285)

                        Text(motion.isAligned ? "Locked" : "Tilt To Match")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(motion.isAligned ? OnboardingPalette.accent : .white)
                            .rotationEffect(.degrees(-5))
                            .offset(x: 240, y: 430)
                    }
                    .onboardingPageAnimation(.supportingContent, phase: animation.phase)

                    ZStack(alignment: .topLeading) {
                        routeTarget
                            .offset(x: 29, y: 177)

                        routeHolds
                            .offset(
                                x: 29 + motion.alignmentTranslation.width,
                                y: 177 + motion.alignmentTranslation.height
                            )
                            .animation(.spring(response: 0.25), value: motion.isAligned)
                            .gesture(manualAlignmentGesture)
                    }
                    .onboardingPageAnimation(.artwork, phase: animation.phase)

                    OnboardingButton(
                        title: motion.isAligned ? "LOCKED IN!" : "LIL BIT DIZZY..",
                        enabled: motion.isAligned,
                        action: {
                            motion.finishAlignment()
                            motion.stop()
                            animation.action()
                        }
                    )
                    .offset(x: 45, y: 755)
                    .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Align the route by tilting your phone")
    }

    private var routeTarget: some View {
        Image("RouteHoldsIllustration")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(OnboardingPalette.target)
            .frame(width: 344, height: 547)
            .accessibilityHidden(true)
    }

    private var routeHolds: some View {
        Image("RouteHoldsIllustration")
            .resizable()
            .scaledToFit()
            .frame(width: 344, height: 547)
            .accessibilityHidden(true)
    }

    private var manualAlignmentGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !motion.isMotionAvailable else { return }
                motion.adjustAlignment(
                    by: CGSize(
                        width: dragOrigin.width + value.translation.width,
                        height: dragOrigin.height + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                guard !motion.isMotionAvailable else { return }
                dragOrigin = motion.alignmentTranslation
                motion.finishManualAlignment()
            }
    }
}

private struct AlignRouteOnboardingPagePreview: View {
    @State private var motion = OnboardingMotionController()

    var body: some View {
        OnboardingPreviewContainer {
            AlignRouteOnboardingPage(motion: motion, action: {})
        }
    }
}

#Preview("06 · Align Route") {
    AlignRouteOnboardingPagePreview()
}
