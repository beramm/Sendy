import SwiftUI
import PhotosUI
import AVKit

/// A debug harness, not a product — system fonts, stock controls, no styling.
/// What it does spend effort on is *state legibility*: which clip is loading,
/// which failed, and why the submit button is disabled.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var newSessionName = ""

    var body: some View {
        List {
            SwiftUI.Section("New session") {
                TextField("Name (route, grade, date…)", text: $newSessionName)
                Button {
                    let name = newSessionName.isEmpty
                        ? "Session \(Date().formatted(date: .abbreviated, time: .shortened))"
                        : newSessionName
                    newSessionName = ""
                    // Creating pushes straight to the clips screen: a session
                    // with no clips has nothing else to offer.
                    Task { await model.newSession(name: name) }
                } label: {
                    Text("Create and add clips").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowSeparator(.hidden)
            }

            if let session = model.session {
                SwiftUI.Section("Current") {
                    NavigationLink(value: AppRoute.setup) {
                        VStack(alignment: .leading) {
                            Text(session.name)
                            Text(summary(of: session))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.processed != nil {
                        NavigationLink("Results", value: AppRoute.results)
                    }
                }
            }

            SwiftUI.Section("Saved sessions") {
                if model.sessions.isEmpty {
                    Text("No sessions yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { session in
                    Button {
                        model.open(session)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.name)
                                Text("\(summary(of: session)) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    // Reads as a row that goes somewhere, rather than a wall of
                    // tint-coloured text.
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let targets = offsets.map { model.sessions[$0] }
                    Task { for t in targets { await model.delete(t) } }
                }
            }

            if let error = model.lastError {
                SwiftUI.Section("Error") {
                    Text(error).foregroundStyle(.red)
                    Button("Dismiss") { model.lastError = nil }
                }
            }
        }
        .navigationTitle(AppNaming.displayName)
        .task { await model.refresh() }
    }

    private func summary(of session: ClimbSession) -> String {
        let reference = session.reference == nil ? "no reference" : "reference"
        let attempts = session.attempts.count == 1 ? "1 attempt" : "\(session.attempts.count) attempts"
        return "\(reference) · \(attempts)"
    }
}

/// Task 5.1 and 5.2 — import first, because pre-shot fixtures get tested far
/// more often than live recording.
///
/// Every slot reports its own state (empty / importing / ready / failed), and
/// the submit button at the bottom states the reason it is disabled. Both
/// exist because the alternative is standing at a gym wondering whether the
/// app is working.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var referenceItem: PhotosPickerItem?
    @State private var attemptItem: PhotosPickerItem?

    var body: some View {
        List {
            SwiftUI.Section {
                if let reference = model.session?.reference {
                    ClipRow(video: reference)
                    PhotosPicker("Replace from Photos", selection: $referenceItem, matching: .videos)
                    Button("Remove", role: .destructive) {
                        Task { await model.removeVideo(reference) }
                    }
                } else {
                    ImportSlot(
                        state: model.referenceImport,
                        emptyText: "No reference clip yet.",
                        retry: { model.referenceImport = .idle }
                    )
                    PhotosPicker("Import from Photos", selection: $referenceItem, matching: .videos)
                    NavigationLink("Record") { CaptureView(role: .reference) }
                }
            } header: {
                Text("Reference climb")
            } footer: {
                Text("The stronger climber's send. This is what your attempt gets compared against.")
            }

            SwiftUI.Section {
                ForEach(model.session?.attempts ?? []) { attempt in
                    ClipRow(video: attempt)
                }
                .onDelete { offsets in
                    let targets = offsets.map { (model.session?.attempts ?? [])[$0] }
                    Task { for t in targets { await model.removeVideo(t) } }
                }
                if model.attemptImport != .idle || model.session?.attempts.isEmpty != false {
                    ImportSlot(
                        state: model.attemptImport,
                        emptyText: "No attempts yet.",
                        retry: { model.attemptImport = .idle }
                    )
                }
                PhotosPicker("Import from Photos", selection: $attemptItem, matching: .videos)
                NavigationLink("Record") { CaptureView(role: .attempt) }
            } header: {
                Text("Attempts")
            } footer: {
                Text("Your own climbs. Swipe an attempt to remove it.")
            }
            
            
            //added for collage
            if model.session?.reference != nil, !(model.session?.attempts.isEmpty ?? true) {
                            SwiftUI.Section {
                                NavigationLink("Compare arm positions", value: AppRoute.armPositionCollage)
                            } footer: {
                                Text("Frame-by-frame arm position comparison — no processing run needed.")
                            }
                        }
            //added for collage
            
            
            SwiftUI.Section {
                DisclosureGroup("Capture protocol") {
                    Text("""
                    Tripod, straight on to the wall, whole route in frame with wall visible either side of the climber. \
                    Stabilization off — it warps the frame per-frame and breaks registration. \
                    Lock AE/AF. 1080p60, 1× lens. Do not touch the tripod between the two clips.
                    """)
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Clips")
        .safeAreaInset(edge: .bottom) { submitBar }
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
        // A finished run goes to the comparison, which is the thing the user
        // asked for. Failures stay here, next to the clips that caused them.
        .onChange(of: model.state) { _, state in
            guard state == .done, model.processed != nil else { return }
            if model.path.last != .results { model.path.append(.results) }
        }
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
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// The fill is drawn here rather than left to `.borderedProminent`, because
    /// a disabled prominent button loses nearly all of its fill and stops
    /// reading as a control at all — it looked like a line of grey text. A
    /// blocked Process button has to still look like a button, or the reason
    /// beneath it answers a question the user never knew to ask.
    private func processButton(title: String) -> some View {
        Button {
            model.process()
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

/// The empty / importing / failed states for a slot that has no clip yet.
private struct ImportSlot: View {
    let state: ClipImportState
    let emptyText: String
    let retry: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Text(emptyText).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Importing…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Dismiss", action: retry)
            }
        }
    }
}

/// A clip that made it to disk: first frame, label, duration. The old row
/// showed eight characters of a UUID, which told the user nothing about
/// whether they picked the right video.
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
