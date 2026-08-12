import SwiftUI

/// Task 4.9 — every `TuningConfig` field, adjustable on device with no rebuild,
/// each showing its current numeric value.
///
/// The list is generated from `TuningConfig.fields`, so a threshold that gets
/// added to the config and not to that table is the only way for something to
/// go missing here.
struct TuningPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var saveName = ""

    var body: some View {
        @Bindable var model = model
        List {
            SwiftUI.Section("Pose model") {
                Picker("Tracker", selection: Binding(
                    get: { model.session?.poseSource ?? .vision },
                    set: { source in Task { await model.setPoseSource(source) } }
                )) {
                    ForEach(PoseSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if let source = model.session?.poseSource {
                    Text(source.detail).font(.caption2).foregroundStyle(.secondary)
                    if !PoseExtractorFactory.isAvailable(source) {
                        Text("Not installed in this build — processing will fail with that reason rather than quietly falling back to the other model.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if model.cachedPoseSources.contains(source) {
                        Text("Pose already cached for this session — switching back is instant.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Changing the tracker re-extracts pose. Every other setting below re-uses it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            SwiftUI.Section {
                Button("Reprocess now") { model.process() }
                Text("Reprocessing re-runs from contact detection using cached pose. Vision does not run again.")
                    .font(.caption).foregroundStyle(.secondary)
                if case .running(let stage, _, _) = model.state {
                    ProgressView(stage)
                }
            }

            ForEach(groups, id: \.self) { group in
                SwiftUI.Section(group) {
                    ForEach(TuningConfig.fields.filter { $0.group == group }) { field in
                        FieldRow(field: field, config: $model.config)
                    }
                }
            }

            SwiftUI.Section("Saved configs") {
                TextField("Name this config", text: $saveName)
                Button("Save") {
                    let name = saveName.isEmpty ? "Config \(Date().formatted(date: .omitted, time: .shortened))" : saveName
                    saveName = ""
                    Task { await model.saveConfig(named: name) }
                }
                ForEach(model.savedConfigs) { saved in
                    Button {
                        model.apply(saved)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(saved.name)
                            Text(saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Reset to defaults", role: .destructive) { model.resetConfig() }
            }
        }
        .navigationTitle("Tuning")
    }

    private var groups: [String] {
        var seen: [String] = []
        for field in TuningConfig.fields where !seen.contains(field.group) { seen.append(field.group) }
        return seen
    }
}

private struct FieldRow: View {
    let field: TuningConfig.Field
    @Binding var config: TuningConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch field.kind {
            case .double(let keyPath, let range, let step):
                HStack {
                    Text(field.label).font(.callout)
                    Spacer()
                    // Every value shown with its current number, not just a
                    // slider position.
                    Text(String(format: step < 0.01 ? "%.3f" : "%.2f", config[keyPath: keyPath]))
                        .font(.system(.callout, design: .monospaced))
                }
                Slider(
                    value: Binding(
                        get: { config[keyPath: keyPath] },
                        set: { config[keyPath: keyPath] = $0 }
                    ),
                    in: range,
                    step: step
                )
            case .int(let keyPath, let range):
                Stepper(value: Binding(
                    get: { config[keyPath: keyPath] },
                    set: { config[keyPath: keyPath] = $0 }
                ), in: range) {
                    HStack {
                        Text(field.label).font(.callout)
                        Spacer()
                        Text("\(config[keyPath: keyPath])")
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
            Text(field.help).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Task 1.10 — tap to add, move, or delete a derived hold, and reorder them.
/// The fallback for when contact clustering underperforms, which on real
/// footage it sometimes will.
struct RouteCorrectionView: View {
    @Environment(AppModel.self) private var model
    @State private var holds: [Hold] = []
    @State private var selected: Int?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    Rectangle().fill(Color(.secondarySystemFill))
                    Canvas { context, size in
                        for hold in holds {
                            let p = CGPoint(x: hold.position.x * size.width, y: (1 - hold.position.y) * size.height)
                            let r: CGFloat = hold.isHandHold ? 12 : 8
                            let isSelected = selected == hold.id
                            context.stroke(
                                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                with: .color(isSelected ? .red : (hold.isHandHold ? .blue : .teal)),
                                lineWidth: isSelected ? 3 : 1.5
                            )
                            context.draw(Text("\(hold.ordinal + 1)").font(.caption2), at: CGPoint(x: p.x, y: p.y - r - 8))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleTap(at: value.location, size: geometry.size)
                            }
                    )
                }
            }
            .frame(maxHeight: .infinity)

            List {
                SwiftUI.Section {
                    Text("Tap a hold to select it. Tap empty wall to move the selected hold there, or to add a new one when nothing is selected.")
                        .font(.caption)
                    HStack {
                        Button("Add hand hold") { add(hand: true) }
                        Button("Add foot hold") { add(hand: false) }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Button("Delete selected", role: .destructive) { deleteSelected() }
                            .disabled(selected == nil)
                        Button("Move earlier") { reorder(by: -1) }.disabled(selected == nil)
                        Button("Move later") { reorder(by: 1) }.disabled(selected == nil)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                SwiftUI.Section {
                    Button("Apply and reprocess") {
                        Task { await model.applyManualRoute(Route(holds: holds.map { markManual($0) })) }
                    }
                    Button("Revert to the derived route", role: .destructive) {
                        Task { await model.clearManualRoute() }
                    }
                }
            }
            .frame(height: 240)
        }
        .navigationTitle("Route")
        .onAppear {
            guard !loaded else { return }
            holds = model.session?.manualRouteOverride?.holds ?? model.processed?.route.holds ?? []
            loaded = true
        }
    }

    private func markManual(_ hold: Hold) -> Hold {
        var h = hold
        h.isManual = true
        return h
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let p = Point2D(x: location.x / size.width, y: 1 - location.y / size.height)
        if let hit = holds.first(where: { hold in
            abs(hold.position.x - p.x) < 0.03 && abs(hold.position.y - p.y) < 0.03
        }) {
            selected = selected == hit.id ? nil : hit.id
            return
        }
        if let selected, let index = holds.firstIndex(where: { $0.id == selected }) {
            holds[index].position = p
            holds[index].isManual = true
        }
    }

    private func add(hand: Bool) {
        let id = (holds.map(\.id).max() ?? -1) + 1
        holds.append(Hold(
            id: id,
            position: Point2D(x: 0.5, y: 0.5),
            firstUsedBy: hand ? .leftWrist : .leftAnkle,
            ordinal: holds.count,
            contactCount: 1,
            firstFrame: holds.last.map { $0.firstFrame + 1 } ?? 0,
            isManual: true
        ))
        selected = id
    }

    private func deleteSelected() {
        guard let selected else { return }
        holds.removeAll { $0.id == selected }
        renumber()
        self.selected = nil
    }

    private func reorder(by delta: Int) {
        guard let selected, let index = holds.firstIndex(where: { $0.id == selected }) else { return }
        let target = index + delta
        guard holds.indices.contains(target) else { return }
        holds.swapAt(index, target)
        renumber()
    }

    /// Ordinal and first-frame order must stay consistent, because segmentation
    /// reads the ordering, not the ids.
    private func renumber() {
        for i in holds.indices {
            holds[i].ordinal = i
            holds[i].firstFrame = i * 10
        }
    }
}
