//
//  SessionSetupView.swift
//  SendSociety
//
//  Created by Dzikry Aji Santoso on 19/08/26.
//
import AVFoundation
import AVKit
import Combine
import SwiftUI

struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(OnboardingStorage.completionKey) private var hasCompletedOnboarding = false
    @Environment(\.dismiss) private var dismiss

    @State private var playback: PlaybackItem?
    /// Which slot is adding a clip. The **role**, not a boolean: one shared
    /// `isPresented` for two slots is the same bug the per-role import states
    /// were introduced to remove.
    @State private var addingClip: VideoRef.Role?
    @State private var removing: VideoRef?
    @State private var confirmingDiscard = false

    var body: some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 0) {
                Text("Compare")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.bottom, 6)

                Text("One Problem. Two Climbs")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 24)

                if let message = model.unusableClipMessage {
                    UnusableClipBanner(headline: message.headline, message: message.body)
                        .padding(.bottom, 24)
                }

                HStack(alignment: .top, spacing: 20) {
                    clipColumn(role: .reference)
                    clipColumn(role: .attempt)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 32)

                compareButton

                Text(statusText)
                    .font(.system(size: 15, weight: .regular))
                    // Raised while work is in flight: a line that is both dim
                    // and fading is invisible twice over.
                    .foregroundStyle(.white.opacity(model.isImporting ? 0.7 : 0.4))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .pulsing(model.isImporting)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        // The system back cannot ask before it pops, and popping is what
        // destroys an unsaved draft's clips. Same chevron, same place — it just
        // gets a chance to confirm first.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if hasCompletedOnboarding {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if model.draftHasClips {
                            confirmingDiscard = true
                        } else {
                            leave()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Discard this climb?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard climb", role: .destructive) { leave() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The clips you added will be deleted. Nothing has been saved yet.")
        }
        .sheet(item: $addingClip) { role in
            AddClipSheet(role: role)
        }
        .sheet(item: $playback) { item in
            ClipPlaybackView(url: item.url)
        }
    }

    private func leave() {
        Task {
            await model.discardDraft()
            dismiss()
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func clipColumn(role: VideoRef.Role) -> some View {
        let importState = model.importState(for: role)
        let video = model.video(for: role)

        VStack(spacing: 10) {
            Text(role == .reference ? "REFERENCE" : "YOU")
                .font(.system(size: 19, weight: .bold))
                // Always coloured. The pair is a legend for the results screen,
                // not a state indicator — the slot's border says the state.
                .foregroundStyle(role == .reference ? AppTheme.accent : AppTheme.you)
                .lineLimit(1)

            if let video {
                FilledClipCard(
                    video: video,
                    importState: importState,
                    play: { play(video) },
                    remove: { removing = video },
                    replace: {
                        Task {
                            await model.removeVideo(video)
                            addingClip = role
                        }
                    }
                )
            } else {
                Button {
                    addingClip = role
                } label: {
                    EmptyClipCard(importState: importState)
                }
                .buttonStyle(.plain)
                .disabled(importState == .loading)
                .accessibilityLabel(
                    role == .reference ? "Add reference climb" : "Add your climb"
                )
            }

            // Present whether or not the slot is filled. With one clip down and
            // one to go, "Your go at the same problem" is doing exactly the
            // teaching it was added for — and a caption that vanished on fill
            // would make the two columns different heights.
            Text(
                role == .reference
                    ? "The climber you\nwant to learn from"
                    : "Your go at the\nsame problem"
            )
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
        .confirmationDialog(
            "Remove this climb?",
            isPresented: .init(
                get: { removing?.role == role },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove climb", role: .destructive) {
                if let video = removing {
                    Task { await model.removeVideo(video) }
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The clip is deleted from this climb. Any comparison already run is discarded with it.")
        }
    }

    private var statusText: String {
        model.blockedReason ?? "Ready to compare"
    }

    private var compareButton: some View {
        PrimaryButton(
            title: "COMPARE NOW",
            isEnabled: model.canProcess,
            disabledHint: model.blockedReason ?? "Starts the comparison",
            action: {
                model.process()
                if model.path.last != .processing {
                    model.path.append(.processing)
                }
            }
        )
        .frame(maxWidth: .infinity)
    }

    private func play(_ video: VideoRef) {
        Task {
            guard let url = await model.videoURL(video) else { return }
            playback = PlaybackItem(url: url)
        }
    }
}

// MARK: - Banner

/// The unusable-clip banner. Names the slot that failed — never a fixed string,
/// or the words and the orange border can disagree.
private struct UnusableClipBanner: View {
    let headline: String
    let message: String

    private let advice = ["FRONT-ON", "WHOLE WALL", "CLIMBER IN FRAME"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.warning)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.warning)
                    Text(message)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Same three rules as the capture screen's framing card, from
            // `capture-protocol.md`.
            FlowLayout(spacing: 8) {
                ForEach(advice, id: \.self) { chip in
                    Text(chip)
                        .monoLabel(size: 11)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.warning.opacity(0.8), lineWidth: 1)
        }
    }
}

/// Wraps chips onto as many lines as they need. Three short strings fit two
/// lines on every phone, and at accessibility sizes they keep wrapping rather
/// than clipping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Slots

private enum SlotStyle {
    static let cornerRadius: CGFloat = 12
    static let aspectRatio: CGFloat = 0.49
}

private struct EmptyClipCard: View {
    let importState: ClipImportState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SlotStyle.cornerRadius)
                .fill(AppTheme.slotSurface)

            RoundedRectangle(cornerRadius: SlotStyle.cornerRadius)
                // Raised from the comp's 0.3: on OLED black in a bright gym,
                // this dashed line is the only thing marking the tap target.
                .strokeBorder(
                    .white.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                )

            if importState == .loading {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(AppTheme.accent)
                    Text("Loading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 40, weight: .light))
                    Text("Add climb")
                        .font(.system(size: 15))
                }
                .foregroundStyle(.white.opacity(0.4))
            }

            if case .failed(let message) = importState {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.warning)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
        }
        .aspectRatio(SlotStyle.aspectRatio, contentMode: .fit)
    }
}

/// A slot with a clip in it. Three separate affordances, and they do not
/// collide: the thumbnail plays, the badge is status only, and the pill is the
/// one control.
private struct FilledClipCard: View {
    @Environment(AppModel.self) private var model
    let video: VideoRef
    let importState: ClipImportState
    let play: () -> Void
    let remove: () -> Void
    let replace: () -> Void

    @State private var thumbnail: CGImage?

    private var isUnusable: Bool {
        if case .unusable = importState { return true } else { return false }
    }

    private var accent: Color { isUnusable ? AppTheme.warning : AppTheme.accent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SlotStyle.cornerRadius)
                .fill(AppTheme.slotSurface)

            if let thumbnail {
                Color.clear
                    .overlay {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    // Dimmed so the badge stays readable over arbitrary
                    // footage. Not a mistake to be corrected later.
                    .opacity(0.7)
                    .clipShape(RoundedRectangle(cornerRadius: SlotStyle.cornerRadius))
            }

            if importState == .loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.accent)
                    .padding(22)
                    .background(.black.opacity(0.5), in: .circle)
            } else {
                Image(systemName: isUnusable ? "xmark" : "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 47, height: 47)
                    .background(accent, in: .circle)
                    // Status, not a control: the tap belongs to the thumbnail
                    // underneath it.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack {
                Spacer()
                if isUnusable {
                    // A clip the app has just declared unusable is not worth
                    // protecting, so this is one step and no confirmation.
                    Button(action: replace) {
                        pill("Replace", foreground: .black, background: AppTheme.warning)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: remove) {
                        pill("Remove", foreground: .white.opacity(0.7), background: .black.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 16)
        }
        .aspectRatio(SlotStyle.aspectRatio, contentMode: .fit)
        .overlay {
            // `strokeBorder`, not `stroke`: a centred 3pt line would make this
            // column half a point wider than its neighbour.
            RoundedRectangle(cornerRadius: SlotStyle.cornerRadius)
                .strokeBorder(accent, lineWidth: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: SlotStyle.cornerRadius))
        .onTapGesture(perform: play)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Play \(video.label)")
        .task(id: video.id) { await loadThumbnail() }
    }

    private func pill(_ title: String, foreground: Color, background: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private func loadThumbnail() async {
        guard let url = await model.videoURL(video) else { return }
        thumbnail = try? await VideoFrameSource.image(
            url: url,
            seconds: 0,
            maximumSize: CGSize(width: 500, height: 800)
        )
    }
}

// MARK: - Playback

private struct PlaybackItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ClipPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            SignpostedVideoPlayer(player: player)
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onDisappear { player.pause() }
        }
    }
}

/// `VideoPlayer` intentionally hides its transport chrome after a moment. A
/// paused frame can then look like a still image, so keep an explicit play
/// affordance visible whenever playback is not running. Native controls remain
/// available by tapping anywhere else on the video.
private struct SignpostedVideoPlayer: View {
    let player: AVPlayer
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            VideoPlayer(player: player)

            if !isPlaying {
                Button {
                    restartIfAtEnd()
                    player.play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.black.opacity(0.38), in: .circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play video")
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = status == .playing
        }
    }

    private func restartIfAtEnd() {
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .infinity
        guard current.isFinite, duration.isFinite, current >= duration - 0.05 else { return }
        player.seek(to: .zero)
    }
}

#Preview("Compare · first clip") {
    FlowPreviewContainer(session: FlowPreviewData.empty) { SessionSetupView() }
        .preferredColorScheme(.dark)
}

#Preview("Compare · one clip") {
    FlowPreviewContainer(session: FlowPreviewData.oneClip) {
        SessionSetupView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Compare · ready") {
    FlowPreviewContainer(session: FlowPreviewData.ready) { SessionSetupView() }
        .preferredColorScheme(.dark)
}

#Preview("Compare · unusable clip") {
    FlowPreviewContainer(
        session: FlowPreviewData.ready,
        attemptImport: .unusable("Sendy didn't find a climber in that video.")
    ) { SessionSetupView() }
        .preferredColorScheme(.dark)
}

#Preview("Compare · importing") {
    FlowPreviewContainer(
        session: FlowPreviewData.oneClip,
        attemptImport: .loading
    ) { SessionSetupView() }
        .preferredColorScheme(.dark)
}
