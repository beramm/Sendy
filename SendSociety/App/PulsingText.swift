//
//  PulsingText.swift
//  SendSociety
//

import SwiftUI

/// A slow fade in and out, applied to a label that means "this is still
/// working".
///
/// Two screens want the identical behaviour — the clip setup screen while a
/// clip imports, and the processing screen while a stage runs — so it lives in
/// one place. Two hand-rolled `repeatForever` animations would drift.
///
/// This is flow legibility, not decoration: a pulsing status is what separates
/// "still working" from "stuck". Stock opacity animation only.
struct PulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the pulse off the work itself. When the work stops the animation
    /// stops — a settled label that keeps throbbing says the app is busy when
    /// it is not.
    let active: Bool

    @State private var dimmed = false

    private var shouldPulse: Bool { active && !reduceMotion }

    func body(content: Content) -> some View {
        content
            // Floored well above zero. Text that fully vanishes reads as a bug
            // on a screen the user is watching.
            .opacity(shouldPulse && dimmed ? 0.35 : 1)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    : .default,
                value: dimmed
            )
            .onAppear { dimmed = shouldPulse }
            .onChange(of: shouldPulse) { _, pulsing in dimmed = pulsing }
    }
}

extension View {
    /// Fades this view in and out slowly while `active`, and leaves it steady
    /// at full opacity otherwise — including whenever Reduce Motion is on.
    func pulsing(_ active: Bool = true) -> some View {
        modifier(PulseModifier(active: active))
    }
}
