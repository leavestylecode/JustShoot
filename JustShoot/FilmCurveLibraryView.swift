import SwiftUI

// MARK: - 曲线管理

struct FilmCurveLibraryView: View {
    @EnvironmentObject private var library: FilmCurveLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: CustomFilmCurve?

    let showsDoneButton: Bool

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        List {
            Section {
                ForEach(CurvePreset.allCases) { preset in
                    Toggle(isOn: builtInVisibilityBinding(preset)) {
                        FilmCurvePreviewCard(
                            curve: .builtIn(preset),
                            isSelected: false,
                            cardSize: CGSize(width: 108, height: 76),
                            graphSize: CGSize(width: 94, height: 40)
                        )
                    }
                    .tint(.green)
                    .disabled(preset == .none)
                    .accessibilityHint(preset == .none
                        ? Text("Neutral is always available")
                        : Text("Show or hide this curve in the camera"))
                }
            } header: {
                Text("Built-in Curves")
            } footer: {
                Text("Neutral is always available")
            }

            Section("My Curves") {
                if library.customCurves.isEmpty {
                    NavigationLink {
                        FilmCurveEditorView(curve: nil)
                    } label: {
                        Label("Add Curve", systemImage: "plus")
                    }
                } else {
                    ForEach(library.customCurves) { custom in
                        HStack(spacing: 10) {
                            NavigationLink {
                                FilmCurveEditorView(curve: custom)
                            } label: {
                                FilmCurvePreviewCard(
                                    curve: custom.filmCurve,
                                    isSelected: false,
                                    cardSize: CGSize(width: 108, height: 76),
                                    graphSize: CGSize(width: 94, height: 40)
                                )
                            }
                            .buttonStyle(.plain)

                            Toggle("", isOn: customVisibilityBinding(custom.id))
                                .labelsHidden()
                                .tint(.green)
                                .accessibilityLabel("Show \(custom.name) in camera")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = custom
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Film Curves")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    FilmCurveEditorView(curve: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Curve")
            }
        }
        .alert(
            "Delete Curve?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { curve in
            Button("Delete", role: .destructive) {
                library.delete(id: curve.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { curve in
            Text("“\(curve.name)” will be permanently deleted.")
        }
    }

    private func builtInVisibilityBinding(_ preset: CurvePreset) -> Binding<Bool> {
        Binding(
            get: { library.isBuiltInVisible(preset) },
            set: { library.setBuiltIn(preset, isVisible: $0) }
        )
    }

    private func customVisibilityBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { library.customCurves.first(where: { $0.id == id })?.isVisible ?? false },
            set: { library.setCustomVisibility(id: id, isVisible: $0) }
        )
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
    @State private var draft: CustomFilmCurve
    @State private var channel: CurveEditingChannel = .master
    @State private var selectedPointIndex: Int?

    private let isNew: Bool

    init(curve: CustomFilmCurve?) {
        isNew = curve == nil
        _draft = State(initialValue: curve ?? CustomFilmCurve(name: String(localized: "My Curve")))
    }

    var body: some View {
        Form {
            Section {
                TextField("Curve Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: draft.name) { _, value in
                        if value.count > 40 {
                            draft.name = String(value.prefix(40))
                        }
                    }
            }

            Section {
                Picker("Channel", selection: $channel) {
                    ForEach(CurveEditingChannel.allCases) { item in
                        Text(item.shortName).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                curveActionRow

                PhotoshopCurveEditor(
                    points: selectedPoints,
                    selectedIndex: $selectedPointIndex,
                    accent: channel.color
                )
                .aspectRatio(1, contentMode: .fit)
                .padding(.vertical, 4)

                pointControls
            } header: {
                Text("Tone Curve")
            } footer: {
                Text("Tap to add a point. Drag points in any direction.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .tint(.white)
        .navigationTitle(isNew ? String(localized: "New Curve") : String(localized: "Edit Curve"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onChange(of: channel) { _, _ in selectedPointIndex = nil }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(trimmedName.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var pointControls: some View {
        if let index = validSelectedIndex {
            Stepper(value: selectedInputValue, in: selectedInputRange) {
                LabeledContent("Input", value: "\(selectedInputValue.wrappedValue)")
                    .monospacedDigit()
            }
            .disabled(index == 0 || index == selectedPoints.wrappedValue.count - 1)

            Stepper(value: selectedOutputValue, in: 0...255) {
                LabeledContent("Output", value: "\(selectedOutputValue.wrappedValue)")
                    .monospacedDigit()
            }

            if index > 0 && index < selectedPoints.wrappedValue.count - 1 {
                Button(role: .destructive, action: deleteSelectedPoint) {
                    Label("Delete Point", systemImage: "trash")
                }
            }
        } else {
            Button(action: addCenterPoint) {
                Label("Add Point", systemImage: "plus.circle")
            }
        }
    }

    private var curveActionRow: some View {
        HStack {
            Menu {
                ForEach(CurvePreset.allCases) { preset in
                    Button(preset.displayName) {
                        draft.applyTemplate(preset)
                        channel = preset.usesChannelCurves ? .red : .master
                        selectedPointIndex = nil
                    }
                }
            } label: {
                Label("Start From", systemImage: "square.stack.3d.up")
            }

            Spacer()

            Button(role: .destructive) {
                draft.resetAllChannels()
                channel = .master
                selectedPointIndex = nil
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
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

    private var validSelectedIndex: Int? {
        guard let selectedPointIndex,
              selectedPoints.wrappedValue.indices.contains(selectedPointIndex) else { return nil }
        return selectedPointIndex
    }

    private var selectedInputValue: Binding<Int> {
        Binding(
            get: {
                guard let index = validSelectedIndex else { return 0 }
                return byteValue(selectedPoints.wrappedValue[index].input)
            },
            set: { value in updateSelectedPoint(input: Float(value) / 255) }
        )
    }

    private var selectedOutputValue: Binding<Int> {
        Binding(
            get: {
                guard let index = validSelectedIndex else { return 0 }
                return byteValue(selectedPoints.wrappedValue[index].output)
            },
            set: { value in updateSelectedPoint(output: Float(value) / 255) }
        )
    }

    private var selectedInputRange: ClosedRange<Int> {
        guard let index = validSelectedIndex else { return 0...0 }
        let points = selectedPoints.wrappedValue
        guard index > 0, index < points.count - 1 else {
            let value = Int((points[index].input * 255).rounded())
            return value...value
        }
        let lower = Int((points[index - 1].input * 255).rounded(.up)) + 1
        let upper = Int((points[index + 1].input * 255).rounded(.down)) - 1
        guard lower <= upper else {
            let value = Int((points[index].input * 255).rounded())
            return value...value
        }
        return lower...upper
    }

    private func updateSelectedPoint(input: Float? = nil, output: Float? = nil) {
        guard let index = validSelectedIndex else { return }
        var points = selectedPoints.wrappedValue
        if let input, index > 0, index < points.count - 1 {
            let minimum = points[index - 1].input + 1 / 255
            let maximum = points[index + 1].input - 1 / 255
            points[index].input = min(max(input, minimum), maximum)
        }
        if let output {
            points[index].output = min(max(output, 0), 1)
        }
        selectedPoints.wrappedValue = points
    }

    private func byteValue(_ value: Float) -> Int {
        Int((Double(value) * 255 + 0.0001).rounded())
    }

    private func addCenterPoint() {
        var points = selectedPoints.wrappedValue
        guard points.count < 16, points.count >= 2 else { return }

        var insertionIndex = 1
        var largestGap: Float = -1
        for index in 1..<points.count {
            let gap = points[index].input - points[index - 1].input
            if gap > largestGap {
                largestGap = gap
                insertionIndex = index
            }
        }

        let input = (points[insertionIndex - 1].input + points[insertionIndex].input) / 2
        let table = CurveMath.expand(points)
        let output = CurveMath.sample(table, at: input)
        points.insert(CurveControlPoint(input: input, output: output), at: insertionIndex)
        selectedPoints.wrappedValue = points
        selectedPointIndex = insertionIndex
    }

    private func deleteSelectedPoint() {
        guard let index = validSelectedIndex,
              index > 0,
              index < selectedPoints.wrappedValue.count - 1 else { return }
        var points = selectedPoints.wrappedValue
        points.remove(at: index)
        selectedPoints.wrappedValue = points
        selectedPointIndex = nil
    }

    private func save() {
        draft.name = trimmedName
        if isNew {
            library.add(draft)
        } else {
            library.update(draft)
        }
        dismiss()
    }
}

// MARK: - Photoshop 式自由控制点曲线

private struct PhotoshopCurveEditor: View {
    @Binding var points: [CurveControlPoint]
    @Binding var selectedIndex: Int?
    let accent: Color

    @State private var activeIndex: Int?

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tone curve editor")
            .accessibilityHint("Tap to add a point. Drag points in any direction.")
        }
    }

    private func curveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeIndex == nil {
                    activeIndex = nearestPoint(to: value.startLocation, size: size)
                        ?? addPoint(at: value.startLocation, size: size)
                    selectedIndex = activeIndex
                }
                guard let activeIndex else { return }
                movePoint(at: activeIndex, to: value.location, size: size)
            }
            .onEnded { _ in activeIndex = nil }
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

    private func movePoint(at index: Int, to location: CGPoint, size: CGSize) {
        guard points.indices.contains(index) else { return }
        let proposed = curvePoint(at: location, size: size)
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
        updated[index].output = proposed.output
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
        CGPoint(
            x: inset + (size.width - inset * 2) * CGFloat(point.input),
            y: inset + (size.height - inset * 2) * CGFloat(1 - point.output)
        )
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

        for division in 1..<4 {
            let fraction = CGFloat(division) / 4
            var path = Path()
            let x = inset + (size.width - inset * 2) * fraction
            let y = inset + (size.height - inset * 2) * fraction
            path.move(to: CGPoint(x: x, y: inset))
            path.addLine(to: CGPoint(x: x, y: size.height - inset))
            path.move(to: CGPoint(x: inset, y: y))
            path.addLine(to: CGPoint(x: size.width - inset, y: y))
            context.stroke(path, with: .color(.white.opacity(0.075)), lineWidth: 0.5)
        }

        var identity = Path()
        identity.move(to: CGPoint(x: inset, y: size.height - inset))
        identity.addLine(to: CGPoint(x: size.width - inset, y: inset))
        context.stroke(
            identity,
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
        var path = Path()
        for (index, output) in table.enumerated() {
            let point = CGPoint(
                x: inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(table.count - 1),
                y: inset + (size.height - inset * 2) * CGFloat(1 - output)
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        context.stroke(
            path,
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
