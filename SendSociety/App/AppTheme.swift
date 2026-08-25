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
                    isEnabled ? AppTheme.background : Color.secondary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 24)
                .frame(minWidth: 313, minHeight: 59)
                .background(
                    isEnabled ? AppTheme.accent : AppTheme.accent.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
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
