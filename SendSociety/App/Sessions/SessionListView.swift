import AVKit
import PhotosUI
import SwiftUI
import UIKit

private enum SessionCollectionLayout: String {
    case list
    case grid

    var alternateTitle: String {
        switch self {
        case .list: "Show as grid"
        case .grid: "Show as list"
        }
    }

    var alternateIcon: String {
        switch self {
        case .list: "square.grid.2x2"
        case .grid: "list.bullet"
        }
    }
}

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var sessionToEdit: ClimbSession?
    @AppStorage("sessionCollectionLayout") private var collectionLayout: SessionCollectionLayout = .grid
    @State private var isSelecting = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var isDeletingSelection = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Text(isSelecting ? selectionTitle : "Sessions")
                        .font(.system(size: 40, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()

                    if !model.sessions.isEmpty {
                        Menu {
                            Button {
                                toggleSelectionMode()
                            } label: {
                                Label(
                                    isSelecting ? "Done selecting" : "Select sessions",
                                    systemImage: isSelecting ? "checkmark" : "checkmark.circle"
                                )
                            }

                            Button {
                                withAnimation(.snappy(duration: 0.28)) {
                                    collectionLayout = collectionLayout == .list ? .grid : .list
                                }
                            } label: {
                                Label(
                                    collectionLayout.alternateTitle,
                                    systemImage: collectionLayout.alternateIcon
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Session options")
                    }
                }
                .padding(.horizontal, 20)

                if model.sessions.isEmpty {
                    VStack(alignment: .center) {
                        Spacer()
                        Image("JigglingClimberIllustration")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 210)
                        VStack(spacing: 8) {
                            Text("Time to get sendy!")
                                .bold()
                                .font(.title3)
                            Text("Become the v67 that you are, today")
                                .fontWeight(.light)
                        }
                        .padding(.vertical, 40)
                        
                        PrimaryButton(title: "Compare now") {
                            // nil, so the model names it: by date now, and by
                            // the gym once a located clip lands.
                            Task { await model.newSession(name: nil) }
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Group {
                        switch collectionLayout {
                        case .list:
                            sessionList
                        case .grid:
                            sessionGrid
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, 12)

            if !model.sessions.isEmpty && !isSelecting {
                Button {
                    // nil, so the model names it: by date now, and by
                    // the gym once a located clip lands.
                    Task { await model.newSession(name: nil) }
                } label: {
                    // Flat accent, not the orb gradient.
                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(AppTheme.background)
                        .frame(width: 64, height: 64)
                        .background(AppTheme.accentCore, in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                .accessibilityLabel("New session")
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomTrailing
                )
            }

            if isSelecting && !model.sessions.isEmpty {
                selectionBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
            }
        }
        .foregroundStyle(.white)
        .navigationTitle("")
        .task { await model.refresh() }
        .sheet(item: $sessionToEdit) { session in
            SaveClimbSheet(
                initialTitle: session.name,
                initialGrade: session.grade,
                sessionToEdit: session
            )
        }
        .confirmationDialog(
            bulkDeleteTitle,
            isPresented: $showingBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(bulkDeleteButtonTitle, role: .destructive) {
                Task { await deleteSelectedSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected climbs, videos, and saved analytics from this device.")
        }
        .onChange(of: model.sessions.map(\.id)) { _, currentIDs in
            selectedSessionIDs.formIntersection(currentIDs)
            if currentIDs.isEmpty { endSelection() }
        }
    }

    /// List (not ScrollView+VStack) because swipeActions requires it.
    /// Row chrome is stripped to keep the same look as before.
    private var sessionList: some View {
        List {
            ForEach(model.sessions) { session in
                Button {
                    handleSessionTap(session)
                } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
                .background(
                    LinearGradient(
                        stops: [
                            .init(
                                color: Color(
                                    red: 38.0 / 255.0,
                                    green: 38.0 / 255.0,
                                    blue: 30.0 / 255.0
                                ),
                                location: 0.22
                            ),
                            .init(
                                color: Color(
                                    red: 51.0 / 255.0,
                                    green: 51.0 / 255.0,
                                    blue: 53.0 / 255.0
                                ),
                                location: 1
                            ),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: .rect(cornerRadius: 16)
                )
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            selectedSessionIDs.contains(session.id)
                                ? AppTheme.accent
                                : Color.clear,
                            lineWidth: 3
                        )
                }
                .listRowInsets(
                    EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isSelecting {
                        Button(role: .destructive) {
                            Task { await model.delete(session) }
                        } label: {
                            Label {
                                Text("Delete")
                            } icon: {
                                blackSwipeIcon("trash")
                            }
                        }

                        Button {
                            sessionToEdit = session
                        } label: {
                            Label {
                                Text("Edit")
                            } icon: {
                                blackSwipeIcon("pencil")
                            }
                        }
                        .tint(AppTheme.accent)
                    }
                }
                .accessibilityValue(selectionAccessibilityValue(for: session))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 88, for: .scrollContent)
        .frame(minHeight: 260)
    }

    private var sessionGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 16
            ) {
                ForEach(model.sessions) { session in
                    Button {
                        handleSessionTap(session)
                    } label: {
                        SessionGridCard(
                            session: session,
                            isSelecting: isSelecting,
                            isSelected: selectedSessionIDs.contains(session.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !isSelecting {
                            Button {
                                sessionToEdit = session
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Task { await model.delete(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .accessibilityLabel(session.name)
                    .accessibilityValue(selectionAccessibilityValue(for: session))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 104)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: 260)
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Button("Cancel") { endSelection() }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                showingBulkDeleteConfirmation = true
            } label: {
                Label(bulkDeleteButtonTitle, systemImage: "trash")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(selectedSessionIDs.isEmpty ? Color.secondary : Color.white)
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .background(
                        selectedSessionIDs.isEmpty
                            ? ResultsStyle.controlSurface
                            : Color.red,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedSessionIDs.isEmpty || isDeletingSelection)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 62)
        .background(ResultsStyle.panelSurface.opacity(0.97), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 7)
    }

    /// Native swipe actions recolor template symbols regardless of a SwiftUI
    /// foreground style. Supplying an original-rendering image keeps the icon
    /// pixels black while the action retains its own background and text color.
    private func blackSwipeIcon(_ systemName: String) -> Image {
        guard let symbol = UIImage(systemName: systemName) else {
            return Image(systemName: systemName)
        }
        let blackSymbol = symbol.withTintColor(.black, renderingMode: .alwaysOriginal)
        return Image(uiImage: blackSymbol)
    }

    private func sessionRow(_ session: ClimbSession) -> some View {
        HStack(spacing: 16) {
            if let grade = session.grade {
                Image("GradeV\(grade.rawValue)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 40)
                    .accessibilityLabel(grade.displayName)
            } else {
                Image(systemName: "figure.climbing")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 44, height: 40)
                    .accessibilityLabel("Grade not set")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(
                    session.createdAt,
                    format: .dateTime
                        .day(.twoDigits)
                        .month(.twoDigits)
                        .year(.twoDigits)
                )
                .monoLabel(size: 13, weight: .regular)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelecting {
                Image(systemName: selectedSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(
                        selectedSessionIDs.contains(session.id)
                            ? AppTheme.accent
                            : Color.secondary
                    )
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(.horizontal, 20)
        .contentShape(.rect)
    }

    private var selectionTitle: String {
        selectedSessionIDs.isEmpty ? "Select Sessions" : "\(selectedSessionIDs.count) Selected"
    }

    private var bulkDeleteTitle: String {
        "Delete \(selectedSessionIDs.count) selected \(selectedSessionIDs.count == 1 ? "session" : "sessions")?"
    }

    private var bulkDeleteButtonTitle: String {
        selectedSessionIDs.isEmpty ? "Delete" : "Delete \(selectedSessionIDs.count)"
    }

    private func handleSessionTap(_ session: ClimbSession) {
        if isSelecting {
            withAnimation(.snappy(duration: 0.18)) {
                if selectedSessionIDs.contains(session.id) {
                    selectedSessionIDs.remove(session.id)
                } else {
                    selectedSessionIDs.insert(session.id)
                }
            }
        } else {
            Task { await model.open(session) }
        }
    }

    private func toggleSelectionMode() {
        if isSelecting {
            endSelection()
        } else {
            withAnimation(.snappy(duration: 0.25)) { isSelecting = true }
        }
    }

    private func endSelection() {
        withAnimation(.snappy(duration: 0.25)) {
            isSelecting = false
            selectedSessionIDs.removeAll()
        }
    }

    private func selectionAccessibilityValue(for session: ClimbSession) -> String {
        guard isSelecting else { return session.grade?.displayName ?? "Grade not set" }
        return selectedSessionIDs.contains(session.id) ? "Selected" : "Not selected"
    }

    @MainActor
    private func deleteSelectedSessions() async {
        let selected = model.sessions.filter { selectedSessionIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isDeletingSelection = true
        await model.deleteSessions(selected)
        isDeletingSelection = false
        endSelection()
    }
}

private struct SessionGridCard: View {
    let session: ClimbSession
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        SessionGridThumbnail(session: session, video: session.reference)
                        SessionGridThumbnail(session: session, video: session.attempts.first)
                    }
                    .frame(height: 132)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(isSelected ? AppTheme.accent : Color.white)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(
                        session.createdAt,
                        format: .dateTime
                            .day(.twoDigits)
                            .month(.twoDigits)
                            .year(.twoDigits)
                    )
                    .monoLabel(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 38.0 / 255.0, green: 38.0 / 255.0, blue: 30.0 / 255.0),
                        Color(red: 51.0 / 255.0, green: 51.0 / 255.0, blue: 53.0 / 255.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? AppTheme.accent : Color.clear, lineWidth: 3)
            }
            .contentShape(.rect(cornerRadius: 14))
            .padding(.top, 20)
            .padding(.trailing, 15)

            gradeBadge
                .rotationEffect(.degrees(18))
        }
    }

    private var gradeBadge: some View {
        let grade = session.grade ?? .v5
        return Image("GradeV\(grade.rawValue)")
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 42)
            .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
            .accessibilityHidden(true)
    }
}

private struct SessionGridThumbnail: View {
    @Environment(AppModel.self) private var model
    let session: ClimbSession
    let video: VideoRef?

    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            ResultsStyle.controlSurface

            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "figure.climbing")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(.rect(cornerRadius: 14))
        .task(id: video?.id) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil
        guard let video else { return }
        let url = await model.store.videoURL(session: session, video: video)
        thumbnail = try? await VideoFrameSource.image(
            url: url,
            seconds: 0,
            maximumSize: CGSize(width: 320, height: 480)
        )
    }
}

// MARK: - Flow previews

/// Preview data stays in the view layer: no preview writes to the session store
/// or needs Photos/camera permissions. These cover the main states in the
/// session-to-comparison flow while the camera itself has its own preview.
@MainActor
struct FlowPreviewContainer<Content: View>: View {
    @State private var model: AppModel
    let session: ClimbSession?
    let sessions: [ClimbSession]
    @ViewBuilder let content: () -> Content

    init(
        session: ClimbSession? = nil,
        sessions: [ClimbSession] = [],
        referenceImport: ClipImportState = .idle,
        attemptImport: ClipImportState = .idle,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.session = session
        self.sessions = sessions
        self.content = content
        let model = AppModel(previewSession: session, previewSessions: sessions)
        // Slot states are settable here so the failed and importing cases can be
        // previewed. Vision's body-pose request cannot even be constructed in
        // the Simulator, so the pre-flight always fails open there and the
        // unusable state is otherwise unreachable outside a device.
        model.referenceImport = referenceImport
        model.attemptImport = attemptImport
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            content()
        }
        .environment(model)
    }
}

enum FlowPreviewData {
    static let reference = VideoRef(
        filename: "reference.mov",
        role: .reference,
        label: "Climb A"
    )
    static let attempt = VideoRef(
        filename: "attempt.mov",
        role: .attempt,
        label: "Climb B"
    )
    static let empty = ClimbSession(name: "Thursday project")
    static let oneClip = ClimbSession(
        name: "Thursday project",
        reference: reference
    )
    static let ready = ClimbSession(
        name: "Thursday project",
        reference: reference,
        attempts: [attempt]
    )
    static let saved = [
        ClimbSession(
            name: "Kuta · V4",
            reference: reference,
            attempts: [attempt]
        ),
        ClimbSession(
            name: "Moon board",
            reference: reference,
            attempts: [attempt]
        ),
    ]
}

#Preview("Sessions · empty") {
    FlowPreviewContainer { SessionListView() }.preferredColorScheme(.dark)
}

#Preview("Sessions · saved comparisons") {
    FlowPreviewContainer(sessions: FlowPreviewData.saved) {
        SessionListView()
    }
}
