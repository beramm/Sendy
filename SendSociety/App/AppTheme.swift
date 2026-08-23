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

/// A centered, edge-to-edge background used throughout the app (not just
/// onboarding). `scaledToFill` keeps the wall pattern covering screens with
/// aspect ratios that differ from the 402 × 874 reference artwork.
struct AppBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.background

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
