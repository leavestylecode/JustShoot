import SwiftUI

// MARK: - 曲线管理

struct FilmCurveLibraryView: View {
    private enum Destination: Hashable {
        case builtIn(CurvePreset)
        case editor(CustomFilmCurve?)
    }

    @EnvironmentObject private var library: FilmCurveLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var destination: Destination?
    @State private var pendingDelete: CustomFilmCurve?
    @State private var confirmsReset = false

    let showsDoneButton: Bool
    private let curveRowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        let visibleEntries = library.visibleEntries

        List {
            if let error = library.storageError {
                Section {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                FilmCurvePickerStrip(
                    curves: library.visibleCurves,
                    current: library.selectedCurve,
                    contentRotation: .zero,
                    orientation: .portrait,
                    style: UIDevice.current.userInterfaceIdiom == .pad ? .iPadOverlay : .standard,
                    presentation: editMode.isEditing ? .sortingPreview : .preview
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(visibleEntries, content: curveRow)
                    .onMove(perform: editMode.isEditing ? { offsets, destination in
                        var order = visibleEntries.map(\.id)
                        order.move(fromOffsets: offsets, toOffset: destination)
                        library.setVisibleOrder(order)
                    } : nil)
                    .listRowInsets(curveRowInsets)
            } header: {
                sectionHeader(editMode.isEditing ? "Reorder Curves" : "Shown",
                              showsReorder: !editMode.isEditing && library.canEdit && visibleEntries.count > 1)
            }
            if !editMode.isEditing {
                let hiddenEntries = library.hiddenEntries
                if !hiddenEntries.isEmpty {
                    Section {
                        ForEach(hiddenEntries, content: curveRow)
                            .listRowInsets(curveRowInsets)
                    } header: {
                        sectionHeader("Hidden")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    Text("Reset")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.red)
                .disabled(!library.canEdit)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 72, leading: 0, bottom: 16, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .alert("Reset Curve List?", isPresented: $confirmsReset) {
                    Button("Reset", role: .destructive) { library.resetList() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Restore the default order and show all curves. Your custom curves will be kept.")
                }
            }
        }
        .listSectionSpacing(4)
        .contentMargins(.top, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .pageContentWidth()
        .appPageBackground()
        .navigationTitle("Film Curves")
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .softScrollEdges()
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .builtIn(let preset):
                BuiltInCurveDetailView(preset: preset)
            case .editor(let curve):
                FilmCurveEditorView(curve: curve)
            }
        }
        .toolbar {
            if showsDoneButton && !editMode.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Done").toolbarControlSurface(text: true)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if editMode.isEditing {
                    Button { withAnimation { editMode = .inactive } } label: {
                        Text("Done").toolbarControlSurface(text: true)
                    }
                } else {
                    // On iOS 17 a toolbar NavigationLink to a fresh draft loops during a row push.
                    Button {
                        destination = .editor(nil)
                    } label: {
                        Image(systemName: "plus")
                            .toolbarControlSurface()
                    }
                    .accessibilityLabel("Add Curve")
                    .disabled(!library.canEdit)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .modifier(CurveDeletionConfirmation(pending: $pendingDelete))
    }

    private func sectionHeader(_ title: LocalizedStringKey, showsReorder: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if showsReorder {
                Button {
                    withAnimation { editMode = .active }
                } label: {
                    Text("Reorder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reorder Curves")
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 12)
        .textCase(nil)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private func curveRow(_ entry: FilmCurveLibrary.Entry) -> some View {
        if editMode.isEditing || entry == .builtIn(.none) {
            curveLabel(entry)
                .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                Button {
                    switch entry {
                    case .builtIn(let preset): destination = .builtIn(preset)
                    case .custom(let curve): destination = .editor(curve)
                    }
                } label: {
                    curveLabel(entry)
                }
                .buttonStyle(CurveDetailButtonStyle())
                .accessibilityHint(entry.customCurve == nil ? Text("View Curve Details") : Text("Edit Curve"))

                Toggle("Show \(entry.displayName) in camera", isOn: visibilityBinding(for: entry))
                    .labelsHidden()
                    .tint(.green)
                    .disabled(!library.canEdit)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if library.canEdit, let custom = entry.customCurve {
                    Button(role: .destructive) { pendingDelete = custom } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func curveLabel(_ entry: FilmCurveLibrary.Entry) -> some View {
        HStack(spacing: 12) {
            if let data = library.previewData(for: entry) {
                CurveGraphView(data: data, accent: .white)
                    .frame(width: 30, height: 30)
                    .padding(5)
                    .background(Color(white: 0.085), in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
            }
            Text(entry.displayName)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !editMode.isEditing && entry == .builtIn(.none) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 51)
                    .accessibilityLabel("Original is always available")
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private func visibilityBinding(for entry: FilmCurveLibrary.Entry) -> Binding<Bool> {
        switch entry {
        case .builtIn(let preset):
            Binding(
                get: { library.isBuiltInVisible(preset) },
                set: { library.setBuiltIn(preset, isVisible: $0) }
            )
        case .custom(let curve):
            Binding(
                get: { library.curve(id: entry.id) != nil },
                set: { library.setCustomVisibility(id: curve.id, isVisible: $0) }
            )
        }
    }
}

private struct CurveDetailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                        in: .rect(cornerRadius: 8))
    }
}

private struct CurveDeletionConfirmation: ViewModifier {
    @EnvironmentObject private var library: FilmCurveLibrary
    @Binding var pending: CustomFilmCurve?
    var didDelete: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert("Delete Curve?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { curve in
            Button("Delete", role: .destructive) {
                if library.delete(id: curve.id) { didDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { curve in
            Text("“\(curve.name)” will be permanently deleted.")
        }
    }
}

private struct BuiltInCurveDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let preset: CurvePreset

    var body: some View {
        GeometryReader { geometry in
            let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
            let layout = wide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                : AnyLayout(VStackLayout(alignment: .center, spacing: 18))

            ScrollView {
                layout {
                    CurvePhotoComparison(look: .preset(preset))
                    CurveResponsePreview(preset: preset)
                        .frame(width: wide ? min(geometry.size.width * 0.32, PageLayout.curveEditorWidth) : nil)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .pageContentWidth(wide ? PageLayout.browseWidth : PageLayout.readingWidth)
            }
        }
        .appPageBackground()
        .navigationTitle(preset.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .softScrollEdges()
        .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - 曲线编辑器

private enum CurveEditingChannel: String, CaseIterable, Identifiable {
    case master
    case red
    case green
    case blue

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .master: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }

    var color: Color {
        switch self {
        case .master: return .white
        case .red: return Color(red: 1.00, green: 0.30, blue: 0.28)
        case .green: return Color(red: 0.22, green: 0.86, blue: 0.40)
        case .blue: return Color(red: 0.26, green: 0.52, blue: 1.00)
        }
    }
}

struct FilmCurveEditorView: View {
    @EnvironmentObject private var library: FilmCurveLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft: CustomFilmCurve
    @State private var channel: CurveEditingChannel = .master
    @State private var selectedPointIndex: Int?
    @State private var showsEditingHelp = false
    @State private var offersCopy = false
    @State private var pendingDelete: CustomFilmCurve?

    private let original: CustomFilmCurve?
    private var isNew: Bool { original == nil }

    init(curve: CustomFilmCurve?) {
        original = curve
        _draft = State(initialValue: curve ?? CustomFilmCurve(name: String(localized: "My Curve")))
    }

    var body: some View {
        GeometryReader { geometry in
            let usesColumns = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
            Form {
                nameSection
                adjustmentSection
                comparisonSection
            }
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .pageContentWidth(usesColumns ? PageLayout.browseWidth : PageLayout.readingWidth)
        }
        .appPageBackground()
        .tint(.primary)
        .navigationTitle(isNew ? String(localized: "New Curve") : String(localized: "Edit Curve"))
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .softScrollEdges()
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: channel) { _, _ in selectedPointIndex = nil }
        .toolbar {
            if let original {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            pendingDelete = original
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .toolbarControlSurface()
                    }
                    .accessibilityLabel("More Curve Actions")
                    .disabled(!library.canEdit)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    Text("Save").toolbarControlSurface(text: true)
                }
                .disabled(trimmedName.isEmpty || !library.canEdit)
            }
        }
        .alert("This curve was deleted", isPresented: $offersCopy) {
            Button("Save a Copy") {
                var copy = draft
                copy.id = UUID()
                copy.createdAt = Date()
                if library.add(copy) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .modifier(CurveDeletionConfirmation(pending: $pendingDelete, didDelete: { dismiss() }))
    }

    private var adjustmentSection: some View {
        Section("Tone Curve") {
            VStack(spacing: 8) {
                channelPicker
                curveEditor
                curveActionRow
            }
            .frame(maxWidth: PageLayout.curveEditorWidth)
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderless)
            .accessibilityElement(children: .contain)
            .listRowSeparator(.hidden)
        }
        .listSectionSeparator(.hidden)
    }

    private var comparisonSection: some View {
        Section {
            CurvePhotoComparison(look: .draft(draft))
                .frame(maxWidth: PageLayout.readingWidth)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Curve Name", text: $draft.name)
                .accessibilityIdentifier("curves.editor.name")
                .textInputAutocapitalization(.words)
                .onChange(of: draft.name) { _, value in
                    if value.count > 40 { draft.name = String(value.prefix(40)) }
                }
        }
    }

    private var channelPicker: some View {
        AppSegmentedPicker(title: "Channel", selection: $channel, options: CurveEditingChannel.allCases) { item in
            Text(item.shortName)
        }
    }

    private var curveEditor: some View {
        PhotoshopCurveEditor(points: selectedPoints, selectedIndex: $selectedPointIndex, accent: channel.color)
            .frame(maxWidth: PageLayout.curveEditorWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityIdentifier("curves.editor.graph")
    }

    private var curveActionRow: some View {
        HStack {
            Menu {
                ForEach(CurvePreset.allCases.filter { $0 != .none }) { preset in
                    Button(preset.displayName) {
                        draft.applyTemplate(preset)
                        channel = preset.usesChannelCurves ? .red : .master
                        selectedPointIndex = nil
                    }
                }
            } label: {
                Label("Start From", systemImage: "square.stack.3d.up")
                    .frame(minHeight: 44)
            }

            Spacer()

            Button { showsEditingHelp = true } label: {
                Image(systemName: "info.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("About curve editing")
            .popover(isPresented: $showsEditingHelp) {
                Text("Tap to add a point. Drag to move it. Drag an interior point outside the graph to delete it.")
                    .font(.callout)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }

            Button(role: .destructive) {
                draft.resetAllChannels()
                channel = .master
                selectedPointIndex = nil
            } label: {
                Text("Reset")
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedPoints: Binding<[CurveControlPoint]> {
        Binding(
            get: {
                switch channel {
                case .master: return draft.masterPoints
                case .red: return draft.redPoints
                case .green: return draft.greenPoints
                case .blue: return draft.bluePoints
                }
            },
            set: { points in
                switch channel {
                case .master: draft.masterPoints = points
                case .red: draft.redPoints = points
                case .green: draft.greenPoints = points
                case .blue: draft.bluePoints = points
                }
            }
        )
    }

    private func save() {
        draft.name = trimmedName
        if let original {
            if library.update(draft, editedFrom: original) {
                dismiss()
            } else if library.canEdit {
                offersCopy = true
            }
        } else if library.add(draft) {
            dismiss()
        }
    }
}

// MARK: - Photoshop 式自由控制点曲线

struct PhotoshopCurveEditor: View {
    @Binding var points: [CurveControlPoint]
    @Binding var selectedIndex: Int?
    let accent: Color

    @State private var activeIndex: Int?
    @State private var dragOrigin: CGPoint?

    private let inset: CGFloat = 18
    private let hitRadius: CGFloat = 26
    private let minimumInputSpacing: Float = 1 / 255
    private let maximumPointCount = 16

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, canvasSize in
                drawBackground(context: &context, size: canvasSize)
                drawCurve(context: &context, size: canvasSize)
                drawPoints(context: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .gesture(curveGesture(size: size))
            .accessibilityRepresentation {
                VStack {
                    Button("Tone curve editor") { addAccessiblePoint(size: size) }
                        .disabled(points.count >= maximumPointCount)
                        .accessibilityHint("Add Point")
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        Text("Point \(index + 1)")
                            .accessibilityValue(Text("Input \(Int((point.input * 255).rounded())), output \(Int((point.output * 255).rounded()))"))
                            .accessibilityAdjustableAction { direction in
                                let delta: Float = direction == .increment ? minimumInputSpacing : -minimumInputSpacing
                                movePoint(at: index, to: CurveControlPoint(input: point.input, output: point.output + delta))
                            }
                            .accessibilityActions {
                                if index > 0, index < points.count - 1 {
                                    Button("Move Left") {
                                        movePoint(at: index, to: CurveControlPoint(input: point.input - minimumInputSpacing, output: point.output))
                                    }
                                    Button("Move Right") {
                                        movePoint(at: index, to: CurveControlPoint(input: point.input + minimumInputSpacing, output: point.output))
                                    }
                                    Button("Delete Point") { deletePoint(at: index) }
                                }
                            }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func curveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeIndex == nil {
                    if let nearby = nearestPoint(to: value.startLocation, size: size) {
                        activeIndex = nearby
                        dragOrigin = position(of: points[nearby], size: size)
                    } else {
                        activeIndex = addPoint(at: value.startLocation, size: size)
                        dragOrigin = value.startLocation
                    }
                    selectedIndex = activeIndex
                }
                guard let activeIndex, let dragOrigin, value.translation != .zero else { return }
                let position = CGPoint(x: dragOrigin.x + value.translation.width,
                                       y: dragOrigin.y + value.translation.height)
                movePoint(at: activeIndex, to: curvePoint(at: position, size: size))
            }
            .onEnded { value in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8)
                if let activeIndex, !bounds.contains(value.location) { deletePoint(at: activeIndex) }
                activeIndex = nil
                dragOrigin = nil
            }
    }

    private func nearestPoint(to location: CGPoint, size: CGSize) -> Int? {
        points.indices.min { lhs, rhs in
            distance(from: location, to: position(of: points[lhs], size: size))
                < distance(from: location, to: position(of: points[rhs], size: size))
        }.flatMap { index in
            distance(from: location, to: position(of: points[index], size: size)) <= hitRadius
                ? index
                : nil
        }
    }

    @discardableResult
    private func addPoint(at location: CGPoint, size: CGSize) -> Int? {
        guard points.count < maximumPointCount else { return nearestPoint(to: location, size: size) }
        let proposed = curvePoint(at: location, size: size)
        let insertionIndex = points.firstIndex { $0.input > proposed.input } ?? points.count
        guard insertionIndex > 0, insertionIndex < points.count else {
            return proposed.input < 0.5 ? 0 : points.count - 1
        }

        let minimum = points[insertionIndex - 1].input + minimumInputSpacing
        let maximum = points[insertionIndex].input - minimumInputSpacing
        guard minimum <= maximum else {
            return abs(proposed.input - points[insertionIndex - 1].input)
                < abs(proposed.input - points[insertionIndex].input)
                ? insertionIndex - 1
                : insertionIndex
        }

        var updated = points
        updated.insert(
            CurveControlPoint(
                input: min(max(proposed.input, minimum), maximum),
                output: proposed.output
            ),
            at: insertionIndex
        )
        points = updated
        return insertionIndex
    }

    private func addAccessiblePoint(size: CGSize) {
        guard points.count < maximumPointCount, let index = points.indices.dropFirst().max(by: {
            points[$0].input - points[$0 - 1].input < points[$1].input - points[$1 - 1].input
        }) else { return }
        let input = (points[index - 1].input + points[index].input) / 2
        let output = CurveMath.sample(CurveMath.expand(points), at: input)
        selectedIndex = addPoint(at: position(of: CurveControlPoint(input: input, output: output), size: size), size: size)
    }

    private func deletePoint(at index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
        selectedIndex = nil
    }

    private func movePoint(at index: Int, to proposed: CurveControlPoint) {
        guard points.indices.contains(index) else { return }
        selectedIndex = index
        var updated = points
        if index == 0 {
            updated[index].input = 0
        } else if index == points.count - 1 {
            updated[index].input = 1
        } else {
            let minimum = points[index - 1].input + minimumInputSpacing
            let maximum = points[index + 1].input - minimumInputSpacing
            updated[index].input = min(max(proposed.input, minimum), maximum)
        }
        updated[index].output = min(max(proposed.output, 0), 1)
        points = updated
    }

    private func curvePoint(at location: CGPoint, size: CGSize) -> CurveControlPoint {
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let rawInput = min(max((location.x - inset) / width, 0), 1)
        let rawOutput = 1 - min(max((location.y - inset) / height, 0), 1)
        return CurveControlPoint(
            input: quantized(rawInput),
            output: quantized(rawOutput)
        )
    }

    private func quantized(_ value: CGFloat) -> Float {
        Float((value * 255).rounded() / 255)
    }

    private func position(of point: CurveControlPoint, size: CGSize) -> CGPoint {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        return ToneCurvePlot.position(input: CGFloat(point.input), output: CGFloat(point.output), in: bounds)
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(
            Path(roundedRect: bounds, cornerRadius: 10),
            with: .color(Color(white: 0.065))
        )

        let plotBounds = bounds.insetBy(dx: inset, dy: inset)
        context.stroke(ToneCurvePlot.grid(divisions: 4, in: plotBounds), with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        context.stroke(
            ToneCurvePlot.path(for: [0, 1], in: plotBounds),
            with: .color(.white.opacity(0.24)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        context.stroke(
            Path(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 10),
            with: .color(.white.opacity(0.12)),
            lineWidth: 0.5
        )
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        let table = CurveMath.expand(points)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        context.stroke(
            ToneCurvePlot.path(for: table, in: bounds),
            with: .color(accent),
            style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawPoints(context: inout GraphicsContext, size: CGSize) {
        for index in points.indices {
            let center = position(of: points[index], size: size)
            let radius: CGFloat = selectedIndex == index ? 6.5 : 5
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.065)))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(selectedIndex == index ? .white : accent),
                lineWidth: selectedIndex == index ? 2.5 : 2
            )
        }
    }
}
