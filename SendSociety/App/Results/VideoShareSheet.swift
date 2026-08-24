//
//  VideoShareSheet.swift
//  SendSociety
//

import SwiftUI
import UIKit

/// One clip, identified so `sheet(item:)` can present it.
struct SharedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet, wrapped for SwiftUI.
///
/// Export hands over the clip as imported rather than rendering the overlay
/// into it. The share sheet is the destination because it already contains
/// "Save Video" — so the clip reaches Photos without this app asking for
/// library write access it otherwise never needs.
struct VideoShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
