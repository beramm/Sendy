import SwiftUI
import PhotosUI
import AVKit

/// A debug harness, not a product. System fonts, default controls, no styling.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var newSessionName = ""

    var body: some View {
        List {
            SwiftUI.Section("New session") {
                TextField("Name (route, grade, date…)", text: $newSessionName)
                Button("Create") {
                    let name = newSessionName.isEmpty ? "Session \(Date().formatted(date: .abbreviated, time: .shortened))" : newSessionName
                    newSessionName = ""
                    Task { await model.newSession(name: name) }
                }
            }

            if let session = model.session {
                SwiftUI.Section("Current: \(session.name)") {
                    NavigationLink("Set up clips") { SessionSetupView() }
                    if session.isReadyToProcess {
                        NavigationLink("Process") { ProcessingView() }
                    } else {
                        Text("Add a reference climb and at least one attempt.")
                            .foregroundStyle(.secondary)
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
                        VStack(alignment: .leading) {
                            Text(session.name)
                            Text("\(session.reference == nil ? "no reference" : "reference") · \(session.attempts.count) attempts · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
}

/// Task 5.1 and 5.2 — import first, because pre-shot fixtures get tested far
/// more often than live recording.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var referenceItem: PhotosPickerItem?
    @State private var attemptItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        List {
            SwiftUI.Section("Reference climb — the stronger climber") {
                if let reference = model.session?.reference {
                    LabeledContent("Imported", value: reference.label)
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
                PhotosPicker("Import from Photos", selection: $referenceItem, matching: .videos)
                NavigationLink("Record") { CaptureView(role: .reference) }
            }

            SwiftUI.Section("Attempts — your climbs") {
                ForEach(model.session?.attempts ?? []) { attempt in
                    LabeledContent(attempt.label, value: attempt.filename.prefix(8) + "…")
                }
                PhotosPicker("Import from Photos", selection: $attemptItem, matching: .videos)
                NavigationLink("Record") { CaptureView(role: .attempt) }
            }

            SwiftUI.Section("Capture protocol") {
                Text("""
                Tripod, straight on to the wall, whole route in frame with wall visible either side of the climber. \
                Stabilization off — it warps the frame per-frame and breaks registration. \
                Lock AE/AF. 1080p60, 1× lens. Do not touch the tripod between the two clips.
                """)
                .font(.caption)
            }

            if importing { SwiftUI.Section { ProgressView("Importing…") } }
            if let importError {
                SwiftUI.Section("Import failed") { Text(importError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Clips")
        .onChange(of: referenceItem) { _, item in load(item, role: .reference) }
        .onChange(of: attemptItem) { _, item in load(item, role: .attempt) }
    }

    private func load(_ item: PhotosPickerItem?, role: VideoRef.Role) {
        guard let item else { return }
        importing = true
        importError = nil
        Task {
            defer { importing = false }
            do {
                // Copy out of Photos into the session directory: a Photos asset
                // URL is not stable, and a session that loses its video can
                // never be reprocessed.
                guard let movie = try await item.loadTransferable(type: VideoFile.self) else {
                    importError = "Could not read that video."
                    return
                }
                await model.addVideo(from: movie.url, role: role)
                try? FileManager.default.removeItem(at: movie.url)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// Transfers a picked video to a temporary file so it can be copied into the
/// session directory.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let destination = URL.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return VideoFile(url: destination)
        }
    }
}
