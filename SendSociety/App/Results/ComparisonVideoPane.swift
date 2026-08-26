import SwiftUI

/// Visual constants taken from the approved sequence-detail reference. Keeping
/// them together prevents the segmented control, pane labels and analytics
/// cards from drifting into slightly different greys and radii.
enum ResultsStyle {
    static let controlSurface = Color(red: 0.20, green: 0.20, blue: 0.21)
    static let panelSurface = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let badgeSurface = Color.black.opacity(0.68)
    static let reference = AppTheme.accent
    static let attempt = Color(red: 0.0, green: 0.72, blue: 0.96)
    static let secondaryText = Color.white.opacity(0.58)
    static let sheetSurface = Color(red: 0.18, green: 0.18, blue: 0.19)
    static let controlCornerRadius: CGFloat = 18
    static let paneCornerRadius: CGFloat = 16
    static let panelCornerRadius: CGFloat = 16
}

/// A video frame surface used by the results side-by-side mode. Its parent
/// derives the shared pane height from the reference source aspect ratio, and
/// the image remains aspect-fit so footage is never stretched.
struct ComparisonVideoPane: View {
    @Environment(AppModel.self) private var model

    let title: String
    let video: VideoRef?
    let pose: PoseSequence
    let frameIndex: Int?
    let scrubbing: Bool
    let cache: FrameImageCache
    var badgeLabel: String? = nil
    var badgeColor: Color = .white
    /// Lets Xcode previews show the complete result layout without importing a
    /// user video or touching the on-disk session store.
    var showsPreviewArtwork = false
    var unavailableReason: String = "Not reached"
    /// Supplied by the Results screen so both panes always show the same crop.
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero

    @State private var frames = VideoFrameLoader()
    @State private var url: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.10)

            Group {
                if showsPreviewArtwork {
                    ResultPreviewArtwork(role: video?.role ?? .reference)
                } else {
                    if let image = frames.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .tint(AppTheme.accent)
                            .opacity(frameIndex == nil ? 0 : 1)
                    }
                }
            }
            .compositingGroup()
            .scaleEffect(max(1, zoomScale))
            .offset(panOffset)

            if frameIndex == nil, !showsPreviewArtwork {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let decodeFailure = frames.decodeFailure, !showsPreviewArtwork {
                VStack {
                    Spacer()
                    Text(decodeFailure)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .padding(7)
                        .background(.thinMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(badgeLabel ?? title.uppercased())
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(ResultsStyle.badgeSurface, in: .capsule)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResultsStyle.panelSurface)
        .clipShape(.rect(cornerRadius: ResultsStyle.paneCornerRadius))
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: video?.id) {
            guard !showsPreviewArtwork else { return }
            guard let video else { url = nil; return }
            url = await model.videoURL(video)
        }
        .task(id: FrameRequest(url: url, frameIndex: frameIndex, scrubbing: scrubbing)) {
            guard !showsPreviewArtwork else { return }
            await frames.load(
                url: url,
                frameIndex: frameIndex,
                timeSeconds: frameIndex.flatMap { pose.frame(at: $0)?.timeSeconds },
                scrubbing: scrubbing,
                cache: cache
            )
        }
    }
}

/// A lightweight, deterministic stand-in for video in Xcode previews. It is
/// intentionally diagrammatic so nobody mistakes preview pixels for pipeline
/// evidence.
private struct ResultPreviewArtwork: View {
    let role: VideoRef.Role

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.82, green: 0.82, blue: 0.76)))

            let holds: [(Double, Double, Color)] = [
                (0.16, 0.14, .red), (0.72, 0.10, .orange), (0.46, 0.25, .green),
                (0.20, 0.37, .blue), (0.76, 0.42, .red), (0.37, 0.55, .green),
                (0.70, 0.66, .orange), (0.18, 0.76, .red), (0.55, 0.87, .green)
            ]
            for (x, y, color) in holds {
                let width = size.width * 0.22
                let height = size.height * 0.035
                let rect = CGRect(
                    x: size.width * x - width / 2,
                    y: size.height * y - height / 2,
                    width: width,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(color.opacity(0.82)))
            }

            let shift = role == .reference ? -size.width * 0.06 : size.width * 0.05
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: size.width * x + shift, y: size.height * y)
            }
            let bodyColor = role == .reference
                ? Color(red: 0.08, green: 0.13, blue: 0.25)
                : Color(red: 0.06, green: 0.06, blue: 0.07)
            let joints = [
                (point(0.50, 0.52), point(0.50, 0.68)),
                (point(0.50, 0.56), point(0.31, 0.43)),
                (point(0.31, 0.43), point(0.22, 0.31)),
                (point(0.50, 0.56), point(0.68, 0.43)),
                (point(0.68, 0.43), point(0.76, 0.29)),
                (point(0.50, 0.68), point(0.35, 0.79)),
                (point(0.35, 0.79), point(0.24, 0.91)),
                (point(0.50, 0.68), point(0.66, 0.78)),
                (point(0.66, 0.78), point(0.75, 0.90))
            ]
            for (start, end) in joints {
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(
                    path,
                    with: .color(bodyColor),
                    style: StrokeStyle(lineWidth: max(8, size.width * 0.075), lineCap: .round)
                )
            }
            let headCenter = point(0.50, 0.47)
            let headSize = max(20, size.width * 0.16)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: headCenter.x - headSize / 2,
                    y: headCenter.y - headSize / 2,
                    width: headSize,
                    height: headSize
                )),
                with: .color(bodyColor)
            )
        }
        .accessibilityHidden(true)
    }
}
