import AVKit
import PhotosUI
import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model

    private let gradeImages = [
        "GradeV1", "GradeV5", "GradeV3", "GradeV2", "GradeV4", "GradeV6",
    ]

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Sessions")
                        .font(.system(size: 40, weight: .bold))
                    Spacer()
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
                    sessionList
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, 12)

            if !model.sessions.isEmpty {
                Button {
                    // nil, so the model names it: by date now, and by
                    // the gym once a located clip lands.
                    Task { await model.newSession(name: nil) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppTheme.background)
                        .frame(width: 64, height: 64)
                        .background(
                            RadialGradient(
                                colors: [
                                    Color(
                                        red: 188.0 / 255.0,
                                        green: 247.0 / 255.0,
                                        blue: 0
                                    ),
                                    Color(
                                        red: 234.0 / 255.0,
                                        green: 250.0 / 255.0,
                                        blue: 182.0 / 255.0
                                    ),
                                ],
                                center: .leading,
                                startRadius: 0,
                                endRadius: 64
                            ),
                            in: Circle()
                        )
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
        }
        .foregroundStyle(.white)
        .navigationTitle("")
        .task { await model.refresh() }
    }

    /// List (not ScrollView+VStack) because swipeActions requires it.
    /// Row chrome is stripped to keep the same look as before.
    private var sessionList: some View {
        List {
            ForEach(Array(model.sessions.enumerated()), id: \.element.id) {
                index, session in
                Button {
                    model.open(session)
                } label: {
                    sessionRow(session, gradeImage: gradeImages[index % gradeImages.count])
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
                .listRowInsets(
                    EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await model.delete(session) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 88, for: .scrollContent)
        .frame(minHeight: 260)
    }

    private func sessionRow(_ session: ClimbSession, gradeImage: String) -> some View {
        HStack(spacing: 16) {
            Image(gradeImage)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 40)
                .accessibilityHidden(true)

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
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(.horizontal, 20)
        .contentShape(.rect)
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
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.session = session
        self.sessions = sessions
        self.content = content
        _model = State(
            initialValue: AppModel(
                previewSession: session,
                previewSessions: sessions
            )
        )
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
