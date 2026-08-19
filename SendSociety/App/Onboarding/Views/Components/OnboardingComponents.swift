import SwiftUI

enum OnboardingPalette {
    static let accent = Color(red: 188 / 255, green: 247 / 255, blue: 0)
    static let background = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let target = Color(red: 74 / 255, green: 96 / 255, blue: 7 / 255)
}

struct OnboardingHeadlineLine {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

struct OnboardingHeadline: View {
    let lines: [OnboardingHeadlineLine]

    var body: some View {
        VStack(alignment: .leading, spacing: -4) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                Text(line.text)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 48, weight: .medium, design: .monospaced))
        .tracking(-1.2)
    }
}

/// A centered, edge-to-edge background shared by the live onboarding flow and
/// every page preview. `scaledToFill` keeps the wall pattern covering screens
/// with aspect ratios that differ from the 402 × 874 reference artwork.
struct OnboardingBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OnboardingPalette.background

                Image("WallDots")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }
}

struct OnboardingButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: 24, weight: .black, design: .default))
                .foregroundStyle(OnboardingPalette.background)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 313, height: 59)
                .background(OnboardingPalette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(enabled ? "" : "Align the route first")
    }
}

enum OnboardingPageAnimationPhase: Equatable {
    case beforeEntrance
    case visible
    case exiting
}

enum OnboardingPageAnimationRole: Equatable {
    case headline
    case artwork
    case supportingContent
    case button

    var entranceDelay: TimeInterval {
        switch self {
        case .headline: 0.04
        case .artwork: 0.13
        case .supportingContent: 0.2
        case .button: 0.27
        }
    }

    var travel: CGFloat {
        switch self {
        case .headline, .button: 42
        case .artwork: 64
        case .supportingContent: 50
        }
    }
}

struct OnboardingPageAnimationContext {
    let phase: OnboardingPageAnimationPhase
    let action: () -> Void
}

/// Runs the page's fade-and-move exit to completion, holds on the empty
/// onboarding background for 0.2 seconds, and only then advances the flow.
struct AnimatedOnboardingPage<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (OnboardingPageAnimationContext) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = OnboardingPageAnimationPhase.beforeEntrance

    var body: some View {
        content(
            OnboardingPageAnimationContext(
                phase: phase,
                action: playExit
            )
        )
        .task {
            await Task.yield()
            guard phase == .beforeEntrance, !Task.isCancelled else { return }
            phase = .visible
        }
    }

    private func playExit() {
        guard phase == .visible else { return }
        phase = .exiting

        Task { @MainActor in
            // Reduced Motion uses a 0.2s fade; the normal fade/move is 0.4s.
            // Both then remain fully transparent for another 0.2s.
            let delay = reduceMotion ? 400 : 600
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

private struct OnboardingPageElementAnimation: ViewModifier {
    let role: OnboardingPageAnimationRole
    let phase: OnboardingPageAnimationPhase
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        !isEnabled || phase == .visible
    }

    private var horizontalOffset: CGFloat {
        guard isEnabled, !reduceMotion else { return 0 }
        return switch phase {
        case .beforeEntrance: role.travel
        case .visible: 0
        case .exiting: -role.travel * 0.4
        }
    }

    private var scale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if phase == .beforeEntrance, role == .artwork { return 0.92 }
        if phase == .exiting, role == .artwork { return 0.98 }
        return 1
    }

    private var animation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.2)
        }

        switch phase {
        case .beforeEntrance:
            return .linear(duration: 0)
        case .visible:
            return .spring(response: 0.58, dampingFraction: 0.82)
                .delay(role.entranceDelay)
        case .exiting:
            return .easeInOut(duration: 0.4)
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(x: horizontalOffset)
            .scaleEffect(scale)
            .animation(isEnabled ? animation : nil, value: phase)
    }
}

extension View {
    func onboardingPageAnimation(
        _ role: OnboardingPageAnimationRole,
        phase: OnboardingPageAnimationPhase,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            OnboardingPageElementAnimation(
                role: role,
                phase: phase,
                isEnabled: isEnabled
            )
        )
    }
}

/// All reference comps use a 402 × 874 canvas. This preserves their measured
/// layout on current phones, scales down on compact phones, and stays centered
/// instead of becoming tablet-sized on iPad.
struct OnboardingDesignCanvas<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / 402,
                proxy.size.height / 874,
                1.2
            )

            content()
                .frame(width: 402, height: 874, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

struct IllustratedOnboardingPage: View {
    let lines: [OnboardingHeadlineLine]
    let headlineOffset: CGPoint
    let imageName: String
    let imageSize: CGSize
    let imageOffset: CGPoint
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(lines: lines)
                        .offset(x: headlineOffset.x, y: headlineOffset.y)
                        .onboardingPageAnimation(.headline, phase: animation.phase)

                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .offset(x: imageOffset.x, y: imageOffset.y)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    OnboardingButton(title: buttonTitle, action: animation.action)
                        .offset(x: 45, y: 755)
                        .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

struct OnboardingPreviewContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            OnboardingBackground()
            content()
        }
        .preferredColorScheme(.dark)
    }
}
