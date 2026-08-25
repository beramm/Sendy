import SwiftUI

/// Final confirmation for a completed comparison. Dismissing the sheet keeps
/// the user on Results and leaves a new climb as a draft; only Save commits it.
struct SaveClimbSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var selectedGrade: ClimbGrade
    @State private var centredGrade: ClimbGrade?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleIsFocused: Bool

    init(initialTitle: String, initialGrade: ClimbGrade?) {
        _title = State(initialValue: initialTitle)
        _selectedGrade = State(initialValue: initialGrade ?? .v4)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Save")
                    .foregroundStyle(.white)
                Text("Climb")
                    .foregroundStyle(AppTheme.accent)
            }
            .font(.system(size: 24, weight: .bold))
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 12) {
                Text("Climb Name")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(ResultsStyle.secondaryText)

                HStack(spacing: 10) {
                    TextField("Climb name", text: $title)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white)
                        .focused($titleIsFocused)
                        .submitLabel(.done)
                        .onSubmit { titleIsFocused = false }

                    if !title.isEmpty {
                        Button {
                            title = ""
                            titleIsFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear climb name")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(
                    ResultsStyle.controlSurface,
                    in: .rect(cornerRadius: 14)
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 14) {
                Text("Grade")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(ResultsStyle.secondaryText)
                    

                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 1) {
                                ForEach(ClimbGrade.allCases) { grade in
                                    gradeButton(grade)
                                        .id(grade)
                                }
                            }
                            .frame(minHeight: 98)
                            .scrollTargetLayout()
                        }
                        .scrollIndicators(.hidden)
                        // Like the Results sequence strip, every grade — even
                        // V1 and V6 — gets enough empty content to reach the
                        // selection position in the exact centre.
                        .contentMargins(
                            .horizontal,
                            max(0, geometry.size.width / 2 - 52),
                            for: .scrollContent
                        )
                        .scrollTargetBehavior(.viewAligned)
                        // Dragging is selection, not just navigation. Whichever
                        // grade settles in the middle becomes the saved grade.
                        .scrollPosition(id: $centredGrade, anchor: .center)
                        .onChange(of: centredGrade) { _, grade in
                            guard let grade, grade != selectedGrade else { return }
                            selectedGrade = grade
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.2),
                                    .init(color: .black, location: 0.8),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .onChange(of: selectedGrade) { _, grade in
                            guard centredGrade != grade else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                proxy.scrollTo(grade, anchor: .center)
                            }
                        }
                        .task {
                            centredGrade = selectedGrade
                            proxy.scrollTo(selectedGrade, anchor: .center)
                        }
                    }
                }
                .frame(height: 98)
                .sensoryFeedback(.selection, trigger: centredGrade)
            }
            .padding(.top, 24)
            .padding(.horizontal, 22)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
            }

            Spacer(minLength: 18)

            PrimaryButton(
                title: isSaving ? "SAVING…" : "SAVE",
                isEnabled: canSave,
                disabledHint: "Enter a climb name."
            ) {
                save()
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .tint(AppTheme.background)
                        .offset(x: -66)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ResultsStyle.panelSurface)
        .presentationDetents([.fraction(0.58)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(38)
        .presentationBackground(ResultsStyle.panelSurface)
        .interactiveDismissDisabled(isSaving)
    }

    private var canSave: Bool {
        !isSaving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func gradeButton(_ grade: ClimbGrade) -> some View {
        let selected = selectedGrade == grade
        return Button {
            selectedGrade = grade
        } label: {
            Image("GradeV\(grade.rawValue)")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 44)
                .frame(width: 92, height: 78)
                .background(
                    AppTheme.accent.opacity(selected ? 0.10 : 0.07),
                    in: .rect(cornerRadius: 14)
                )
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppTheme.accent, lineWidth: 3)
                    }
                }
                .scaleEffect(selected ? 1 : 0.82)
                .animation(.snappy(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(grade.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard canSave else { return }
        titleIsFocused = false
        errorMessage = nil
        isSaving = true
        Task {
            if await model.saveClimb(title: title, grade: selectedGrade) {
                dismiss()
            } else {
                errorMessage = model.lastError ?? "The climb could not be saved."
                isSaving = false
            }
        }
    }
}
