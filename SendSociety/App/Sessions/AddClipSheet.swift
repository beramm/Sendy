//
//  AddClipSheet.swift
//  SendSociety
//

import PhotosUI
import SwiftUI

/// The two ways a clip can arrive, offered before either one costs anything.
///
/// Upload used to live inside the camera screen, which meant importing an
/// existing clip started an `AVCaptureSession` and raised a camera permission
/// prompt it never needed. Separating the intents here means the camera is only
/// ever touched by someone who chose to record.
@MainActor
struct AddClipSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let role: VideoRef.Role

    @State private var libraryItem: PhotosPickerItem?
    /// Set when RECORD was tapped, acted on in `onDisappear`.
    @State private var pendingRecord = false
    /// Measured content height, so accessibility text sizes grow the detent
    /// instead of clipping — a sheet detent does not scroll to rescue clipped
    /// content. Starts at a rough guess and is corrected on first layout.
    @State private var contentHeight: CGFloat = 250

    var body: some View {
        VStack(spacing: 16) {
            title
                .padding(.top, 28)
                .padding(.bottom, 4)

            Button {
                // Dismiss first and push from `onDismiss`: dismissing a sheet
                // and pushing in the same runloop turn drops the push.
                pendingRecord = true
                dismiss()
            } label: {
                SheetButtonLabel(title: "RECORD", systemImage: "camera.fill")
                    .foregroundStyle(AppTheme.background)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $libraryItem, matching: .videos) {
                SheetButtonLabel(title: "UPLOAD", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white, lineWidth: 4)
                    }
            }

        }
        .padding(.horizontal, 44)
        // No hand-rolled gutter. The comp draws 59pt below the last button, but
        // that space *is* the home-indicator safe area — adding it as padding
        // too gave the sheet two gutters and a visibly empty lower third.
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measure(proxy) }
                    .onChange(of: proxy.size.height) { _, _ in measure(proxy) }
            }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.sheetSurface)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            model.beginImport(item, role: role)
            dismiss()
        }
        .onDisappear {
            guard pendingRecord else { return }
            pendingRecord = false
            model.path.append(.capture(role))
        }
    }

    /// The detent is the content plus the safe area it has to clear. Measuring
    /// only the content leaves the buttons sitting under the home indicator;
    /// padding for the safe area as well leaves a dead band under them.
    private func measure(_ proxy: GeometryProxy) {
        contentHeight = proxy.size.height + proxy.safeAreaInsets.bottom
    }

    private var title: some View {
        // The coloured word is the role, and it is the same colour the slot
        // label uses — the legend has to hold everywhere.
        (
            Text("Add ")
                + Text(role == .reference ? "reference" : "your")
                .foregroundColor(role == .reference ? AppTheme.accent : AppTheme.you)
                + Text(" climb")
        )
        .font(.system(size: 19, weight: .bold))
        .foregroundStyle(.white)
    }

}

/// A struct rather than a method: `PhotosPicker`'s label closure is nonisolated,
/// so a main-actor method cannot supply it.
private struct SheetButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 59)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            AddClipSheet(role: .reference)
                .environment(AppModel(previewSession: FlowPreviewData.empty))
        }
        .preferredColorScheme(.dark)
}
