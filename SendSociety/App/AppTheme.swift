//
//  AppTheme.swift
//  SendSociety
//
//  Created by Dzikry Aji Santoso on 19/08/26.
//


import SwiftUI

/// Shared app-wide color palette. Previously lived on `OnboardingPalette`,
/// but these colors are used well beyond onboarding, so they now live here.
enum AppTheme {
    static let accent = Color("AccentColor")
    static let background = Color("BackgroundColor")
    static let target = Color("TargetColor")

    /// The two stops of the accent orb, centre then rim. Defined once because
    /// the pair is what makes the gradient read as a glow — a second copy of
    /// either value is how the two drift apart.
    static let accentCore = Color(red: 188.0 / 255.0, green: 247.0 / 255.0, blue: 0)
    static let accentEdge = Color(red: 234.0 / 255.0, green: 250.0 / 255.0, blue: 182.0 / 255.0)

    /// The climber's own colour. `accent` is the reference, this is the
    /// attempt, and the pair is a legend that has to mean the same thing on
    /// every screen — so `ResultsStyle.attempt` reads from here rather than
    /// declaring its own cyan.
    static let you = Color(red: 0, green: 0.72, blue: 0.96)

    /// Unusable input: a clip that imported fine but has no climber in it.
    /// Distinct from `.red`, which stays reserved for falls.
    static let warning = Color(red: 1.0, green: 154.0 / 255.0, blue: 0)

    /// Surfaces.
    static let sheetSurface = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let disabledSurface = Color(red: 38.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0)
    static let slotSurface = Color(red: 14.0 / 255.0, green: 14.0 / 255.0, blue: 14.0 / 255.0)
}

/// Monospaced is a role in this app, not a per-call-site font choice: it marks
/// labels and technical readouts (capture titles, framing chips, session
/// dates). Declared once so the role can be changed in one place.
extension View {
    func monoLabel(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }
}

/// The app-wide filled call-to-action used for primary actions.
struct PrimaryButton: View {
    let title: String
    var isEnabled = true
    var disabledHint = ""
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Text(title)
                .font(.system(.title2, weight: .black))
                .foregroundStyle(
                    isEnabled ? AppTheme.background : Color.white.opacity(0.4)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 24)
                .frame(minWidth: 313, minHeight: 59)
                // Flat grey when disabled, not a dimmed accent. Accent at 16%
                // reads as a live control someone turned the lights down on;
                // grey reads as "not yet", which is what it means.
                .background(
                    isEnabled ? AppTheme.accent : AppTheme.disabledSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : disabledHint)
    }
}

/// A centered, edge-to-edge background used throughout the app (not just
/// onboarding). `scaledToFill` keeps the wall pattern covering screens with
/// aspect ratios that differ from the 402 × 874 reference artwork.
struct AppBackground: View {
    var color = AppTheme.background

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                color

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
