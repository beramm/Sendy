//
//  SessionSetupView.swift
//  SendSociety
//
//  Created by Dzikry Aji Santoso on 19/08/26.
//
import SwiftUI
import PhotosUI

struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var referenceItem: PhotosPickerItem?
    @State private var attemptItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 20) {
                Text("Let’s compare").font(.largeTitle.bold())
                Text("Add two clips from the same angle.").foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    clipCard(role: .reference, title: "Climb A", video: model.session?.reference)
                    clipCard(role: .attempt, title: "Climb B", video: model.session?.attempts.first)
                }
                Text(model.canProcess ? "Ready to compare" : "Add two clips to start")
                    .frame(maxWidth: .infinity).foregroundStyle(.secondary)
                Spacer()
                
                submitBar
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .navigationTitle("Compare")
        .onChange(of: referenceItem) { _, item in
            guard let item else { return }
            referenceItem = nil
            Task { await model.importPicked(item, role: .reference) }
        }
        .onChange(of: attemptItem) { _, item in
            guard let item else { return }
            attemptItem = nil
            Task { await model.importPicked(item, role: .attempt) }
        }
    }

    @ViewBuilder private func clipCard(role: VideoRef.Role, title: String, video: VideoRef?) -> some View {
        VStack(spacing: 12) {
            if let video { ClipRow(video: video).frame(height: 145); Button("Remove") { Task { await model.removeVideo(video) } }.font(.caption) }
            else {
                NavigationLink { CaptureView(role: role) } label: {
                    Image(systemName: "plus").font(.system(size: 38, weight: .light)).foregroundStyle(AppTheme.accent)
                }
                .frame(maxWidth: .infinity, minHeight: 145)
                PhotosPicker(selection: role == .reference ? $referenceItem : $attemptItem, matching: .videos) {
                    Label("Library", systemImage: "photo.on.rectangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(title).font(.headline)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(video == nil ? AppTheme.accent : .white.opacity(0.2), lineWidth: 1.5))
    }

    /// The submit gate, with its reason directly beneath it, and the run itself.
    ///
    /// The pipeline used to have its own screen, which meant the user crossed a
    /// stage-timing table to reach their results. Running here and landing on
    /// results makes the clips screen the last thing between them and the
    /// comparison; the stage report is still one tap from results when a number
    /// looks wrong.
    @ViewBuilder
    private var submitBar: some View {
        VStack(spacing: 8) {
            switch model.state {
            case .running(let stage, let index, let fraction):
                ProgressView(value: Double(index) + fraction, total: Double(ProcessingPipeline.stageCount))
                HStack {
                    Text("\(stage) — stage \(index + 1) of \(ProcessingPipeline.stageCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { model.cancelProcessing() }
                        .font(.footnote)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                processButton(title: "Try again")
            default:
                processButton(title: "Process")
                if let reason = model.blockedReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// The fill is drawn here rather than left to `.borderedProminent`, because
    /// a disabled prominent button loses nearly all of its fill and stops
    /// reading as a control at all — it looked like a line of grey text. A
    /// blocked Process button has to still look like a button, or the reason
    /// beneath it answers a question the user never knew to ask.
    private func processButton(title: String) -> some View {
        Button {
            model.process()
            if model.path.last != .processing { model.path.append(.processing) }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(model.canProcess ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    model.canProcess ? Color.accentColor : Color(.systemGray4),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.canProcess)
    }
}

private struct ClipRow: View {
    @Environment(AppModel.self) private var model
    let video: VideoRef

    @State private var thumbnail: CGImage?
    @State private var durationSeconds: Double?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(.secondarySystemFill)
                }
            }
            .frame(width: 88, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(video.label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .task(id: video.id) { await loadPreview() }
    }

    private var detail: String {
        guard let durationSeconds else { return "Reading…" }
        return String(format: "%.1fs", durationSeconds)
    }

    private func loadPreview() async {
        guard let url = await model.videoURL(video) else { return }
        durationSeconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        thumbnail = try? await VideoFrameSource.image(
            url: url, seconds: 0, maximumSize: CGSize(width: 240, height: 240)
        )
    }
}

#Preview("Compare · first clip") {
    FlowPreviewContainer(session: FlowPreviewData.empty) { SessionSetupView()
    }.preferredColorScheme(.dark)
}

#Preview("Compare · one clip") {
    FlowPreviewContainer(session: FlowPreviewData.oneClip) { SessionSetupView()
    }.preferredColorScheme(.dark)
}

#Preview("Compare · ready") {
    FlowPreviewContainer(session: FlowPreviewData.ready) { SessionSetupView()
    }.preferredColorScheme(.dark)
}
