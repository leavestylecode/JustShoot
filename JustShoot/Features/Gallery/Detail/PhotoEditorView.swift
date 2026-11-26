import SwiftData
import SwiftUI

struct PhotoEditorView: View {
    private enum Tool: CaseIterable { case film, curve, crop }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \CustomLUT.displayName) private var customLUTs: [CustomLUT]
    let assetID: String
    let onSave: () -> Void

    @State private var tool = Tool.film
    @State private var session: PhotoEditSession?
    @State private var recipe = PhotoEditRecipe()
    @State private var sourceSize: CGSize = .zero
    @State private var preview: CGImage?
    @State private var renderedRecipe: PhotoEditRecipe?
    @State private var films: [FilmSource] = []
    @State private var curves: [PhotoEditCurve] = []
    @State private var selectedPoint: Int?
    @State private var dragStart: PhotoEditCrop?
    @State private var saving = false
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable().scaledToFit()
                            .overlay { if tool == .crop { CropGuides() } }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(pan(size: geometry.size), including: tool == .crop ? .all : .none)
                            .accessibilityLabel("Photo preview")
                    } else if session != nil || failure == nil {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let session {
                    controls
                        .frame(height: verticalSizeClass == .compact ? 92 : 143)
                    Picker("Edit photo", selection: $tool) {
                        Label("Film LUT", systemImage: "camera.filters").tag(Tool.film)
                        Label("Tone Curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath").tag(Tool.curve)
                        Label("Crop", systemImage: "crop").tag(Tool.crop)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .disabled(saving)
                    .task(id: recipe) {
                        let edit = recipe
                        do {
                            let image = try await session.preview(edit)
                            try Task.checkCancellation()
                            sourceSize = image.sourceSize
                            preview = image.image
                            renderedRecipe = edit
                        } catch {
                            if !Task.isCancelled { failure = error.localizedDescription }
                        }
                    }
                }
            }
            .padding(.bottom, 10)
            .appPageBackground(showsGradient: false)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .principal) {
                    if recipe != PhotoEditRecipe() {
                        Button("Reset") { recipe = .init(); selectedPoint = nil }.disabled(saving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else {
                        Button("Done", action: save).disabled(session == nil || recipe == session?.initialRecipe || renderedRecipe != recipe)
                    }
                }
            }
            .task(id: attempt) { await load() }
            .alert("Photo action failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                if session == nil {
                    Button("Retry") { attempt += 1 }
                    Button("Cancel", role: .cancel) { dismiss() }
                } else { Button("OK", role: .cancel) {} }
            } message: { Text(failure ?? "") }
        }
        .interactiveDismissDisabled(saving || recipe != session?.initialRecipe)
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            switch tool {
            case .film:
                if let session {
                    PhotoEditFilmStrip(session: session, films: films, recipe: $recipe)
                }
                if recipe.filmID != nil {
                    HStack {
                        Slider(value: $recipe.intensity, in: 0...1).accessibilityLabel("LUT intensity")
                        Text(recipe.intensity, format: .percent).monospacedDigit().frame(minWidth: 44)
                    }
                }
            case .curve:
                Menu {
                    ForEach(curves, id: \.self) { choice in
                        Button(choice.label) { recipe.curve = choice; selectedPoint = nil }
                    }
                    Button("Custom curve") {
                        recipe.curve = .custom(CustomFilmCurve(name: String(localized: "Custom curve")))
                        selectedPoint = nil
                    }
                } label: { Label(recipe.curve.label, systemImage: "chevron.up.chevron.down") }
                if case .custom(let curve) = recipe.curve {
                    PhotoshopCurveEditor(points: Binding(get: { curve.masterPoints }, set: { points in
                        var updated = curve
                        updated.masterPoints = points
                        recipe.curve = .custom(updated)
                    }), selectedIndex: $selectedPoint, accent: .yellow)
                    .frame(maxWidth: 340).frame(height: verticalSizeClass == .compact ? 52 : 92)
                } else {
                    CurveGraphView(curve: recipe.curve.resolved, accent: .primary)
                        .frame(width: 138, height: 60)
                }
            case .crop:
                HStack {
                    Button {
                        recipe.crop.turns = (recipe.crop.turns + 1) % 4
                        recipe.crop.x = 0.5
                        recipe.crop.y = 0.5
                    } label: { Image(systemName: "rotate.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Rotate left")
                    Spacer()
                    Picker("Aspect ratio", selection: $recipe.crop.aspect) {
                        ForEach(PhotoCropAspect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Spacer()
                    Text(String(format: "%.1f×", recipe.crop.zoom)).monospacedDigit()
                }
                Slider(value: $recipe.crop.zoom, in: 1...4).accessibilityLabel("Crop zoom")
            }
        }
        .padding(.horizontal, tool == .film ? 12 : 24)
        .disabled(saving)
    }

    private func pan(size: CGSize) -> some Gesture {
        DragGesture().onChanged { value in
            guard !saving, sourceSize.width > 0, sourceSize.height > 0 else { return }
            let start = dragStart ?? recipe.crop
            dragStart = start
            let sideways = start.turns % 2 == 1
            let extent = CGRect(x: 0, y: 0, width: sideways ? sourceSize.height : sourceSize.width,
                                height: sideways ? sourceSize.width : sourceSize.height)
            let rect = start.rect(in: extent)
            let scale = min(size.width / rect.width, size.height / rect.height)
            guard scale > 0 else { return }
            if extent.width > rect.width {
                recipe.crop.x = min(max(start.x - value.translation.width / scale / (extent.width - rect.width), 0), 1)
            }
            if extent.height > rect.height {
                recipe.crop.y = min(max(start.y - value.translation.height / scale / (extent.height - rect.height), 0), 1)
            }
        }.onEnded { _ in dragStart = nil }
    }

    private func load() async {
        let available = FilmPagePreferences.catalogPresets.map(FilmSource.preset) + customLUTs.map(FilmSource.from)
        do {
            let session = try await PhotoEditSession.open(id: assetID, films: available)
            try Task.checkCancellation()
            let library = FilmCurveLibrary.shared
            curves = library.entries.compactMap { entry in
                switch entry {
                case .builtIn(let preset): library.isBuiltInVisible(preset) ? .preset(preset) : nil
                case .custom(let curve): curve.isVisible ? .custom(curve) : nil
                }
            }
            films = available
            recipe = session.initialRecipe
            self.session = session
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private func save() {
        guard let session, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.save(recipe)
                onSave()
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct CropGuides: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for division in 1...2 {
                let fraction = CGFloat(division) / 3
                grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(grid, with: .color(.white.opacity(0.7)), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
