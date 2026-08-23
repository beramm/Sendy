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

    @State private var playback: PlaybackItem?
    @State private var trimmingVideo: VideoRef?
    @State private var editedName = ""
    /// Focus on the name field, so something other than the keyboard's own
    /// return key can let go of it. Without this the keyboard covers the
    /// Compare button and the only way out is the return key — a dead end on a
    /// screen whose whole job is to get you to that button.
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 0) {
                Text("Compare")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.bottom, 6)

                sessionName
                    .padding(.bottom, 56)

                HStack(alignment: .top, spacing: 24) {
                    clipColumn(
                        role: .reference,
                        title: "Climber 1",
                        video: model.session?.reference
                    )
                    clipColumn(
                        role: .attempt,
                        title: "Climber 2",
                        video: model.session?.attempts.first
                    )
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 48)

                Text(statusText)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 36)

                compareButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        // The keyboard overlays this screen rather than resizing it. `ClipCard`
        // sizes itself from the available height via `.aspectRatio(_:.fit)`, so
        // letting the keyboard eat half the height shrank the cards vertically
        // and — because the ratio is fixed — dragged their width down with it,
        // collapsing two video thumbnails into small ovals. Nothing here needs
        // to move out of the keyboard's way: the name field is at the top, and
        // the Compare button it covers is reachable the moment the keyboard is
        // dismissed, which the tap gesture below and the return key both do.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // A tap anywhere that isn't a control drops the keyboard. Buttons and
        // the field itself still get their taps first — this only catches what
        // nothing else claimed.
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
        .foregroundStyle(.white)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.session?.id) { editedName = model.session?.name ?? "" }
        .onChange(of: model.session?.name) { _, name in editedName = name ?? "" }
        .sheet(item: $playback) { item in
            ClipPlaybackView(url: item.url)
        }
    }

    @ViewBuilder
    private func clipColumn(
        role: VideoRef.Role,
        title: String,
        video: VideoRef?
    ) -> some View {
        let importState = model.importState(for: role)

        VStack(alignment: .leading, spacing: 8) {
            HStack() {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(video == nil ? .secondary : .primary)
                    .lineLimit(1)

                Spacer( )

                if let video {
                    Menu {
                        Button(role: .destructive) {
                            Task { await model.removeVideo(video) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Options for \(title)")
                }
            }
            .frame(height: 25)

            if let video {
                ClipCard(
                    video: video,
                    importState: importState,
                    play: { play(video) }
                )
            } else {
                NavigationLink {
                    CaptureView(role: role)
                } label: {
                    EmptyClipCard(importState: importState)
                }
                .buttonStyle(.plain)
                .disabled(importState == .loading)
                .accessibilityLabel("Add \(title) video")
            }

            if case .failed(let message) = importState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        // Give both HStack children the same ideal width before they expand.
        // This keeps the two aspect-ratio-driven cards exactly the same size.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
    }

    /// The session's name, editable in place.
    ///
    /// Renaming is the correction mechanism for the whole naming feature: it
    /// locks the name against any later resolve, and it teaches the placemark
    /// cache, so the next session at this gym inherits the climber's name
    /// rather than Apple's label for the building.
    private var sessionName: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Session name", text: $editedName)
                .font(.system(size: 18, weight: .medium))
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                // Commit on *losing focus* rather than on submit, so a name
                // typed and then tapped away from is kept. Committing only on
                // submit silently discarded the edit by every other exit.
                .onChange(of: nameFocused) { _, focused in
                    guard !focused else { return }
                    let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    // An emptied field is an abandoned edit, not a request for
                    // a nameless session. `renameSession` refuses it either
                    // way; this puts the real name back on screen.
                    guard !trimmed.isEmpty else {
                        editedName = model.session?.name ?? ""
                        return
                    }
                    Task { await model.renameSession(to: editedName) }
                }
            Text(nameProvenance)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the name came from, stated plainly.
    ///
    /// The date case deliberately reads as an outcome rather than a failure.
    /// Gyms are windowless warehouses where GPS and cell both fail, so a date
    /// name is the *normal* result — dressing it as "location unavailable"
    /// would put a warning on the majority case and teach the user to ignore
    /// warnings.
    private var nameProvenance: String {
        switch model.sessionNameSource {
        case .user: "Your name. Nothing renames it."
        case .cache: "Named from a gym you've been to before."
        case .network: "Named from Apple Maps. Rename it and the next session here inherits your name."
        case .date: "Named by date. Rename it whenever you like."
        }
    }

    private var statusText: String {
        if model.isImporting { return "Preparing your clip…" }
        if model.canProcess { return "Ready to compare" }
        return "One more clip to go"
    }

    private var compareButton: some View {
        Button {
            model.process()
            if model.path.last != .processing { model.path.append(.processing) }
        } label: {
            Text("Compare")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    model.canProcess ? AppTheme.background : Color.secondary
                )
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    model.canProcess
                        ? AppTheme.accent : AppTheme.accent.opacity(0.16),
                    in: .capsule
                )
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!model.canProcess)
        .accessibilityHint(model.blockedReason ?? "Starts the comparison")
    }

    private func play(_ video: VideoRef) {
        Task {
            guard let url = await model.videoURL(video) else { return }
            playback = PlaybackItem(url: url)
        }
    }
}

private struct ClipCard: View {
    @Environment(AppModel.self) private var model
    let video: VideoRef
    let importState: ClipImportState
    let play: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: play) {
            ZStack {
                RoundedRectangle(cornerRadius: 27)
                    .fill(Color.white.opacity(0.20))

                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                }

                Color.black.opacity(thumbnail == nil ? 0 : 0.18)

                if importState == .loading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(AppTheme.accent)
                        .padding(22)
                        .background(.black.opacity(0.5), in: .circle)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(.black.opacity(0.38), in: .circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .shadow(radius: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 27))
            .contentShape(RoundedRectangle(cornerRadius: 27))
        }
        .buttonStyle(.plain)
        .disabled(importState == .loading)
        .aspectRatio(0.52, contentMode: .fit)
        .task(id: video.id) { await loadThumbnail() }
        .accessibilityLabel("Play \(video.label)")
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

private struct EmptyClipCard: View {
    let importState: ClipImportState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 27)
                .fill(Color.white.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 27)
                        .stroke(AppTheme.accent, lineWidth: 2)
                }

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
                Image(systemName: "plus")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .aspectRatio(0.52, contentMode: .fit)
    }
}

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
