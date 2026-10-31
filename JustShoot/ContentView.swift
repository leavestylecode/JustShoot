import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    let preparedHome: HomePreparationSnapshot
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var gridScale = 1.0
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @State private var showFileImporter = false
    @State private var importedCube: CubeLUT?
    @State private var importEncoding = LUTColorEncoding.sRGB
    @State private var isImporting = false
    @State private var showImportSheet = false
    @State private var importName = ""
    @State private var importISO = "200"
    @State private var importError: String?
    @State private var showImportError = false
    @State private var operationErrorTitle: LocalizedStringKey = "Import failed"
    @State private var importTask: Task<Void, Never>?
    @State private var initialCustomFilters: [HomeCustomFilter]
    @State private var usesLiveCustomFilters = false
    private func gridColumns(availableWidth: CGFloat) -> [GridItem] {
        let isRegular = sizeClass == .regular
        let width = (isRegular ? min(availableWidth, PageLayout.browseWidth) : availableWidth) - (isRegular ? 48 : 28)
        let count = PageLayout.gridColumns(width: width,
            minimum: (isRegular ? 176 : 100) * gridScale, spacing: 14, maximum: 4)
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    init(preparedHome: HomePreparationSnapshot) {
        self.preparedHome = preparedHome
        _initialCustomFilters = State(initialValue: preparedHome.customFilters)
    }

    private var visibleCustomFilters: [HomeCustomFilter] {
        usesLiveCustomFilters ? customLUTs.filter { !$0.isDeleted }.map(HomeCustomFilter.init) : initialCustomFilters
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: gridColumns(availableWidth: geometry.size.width), spacing: 12) {
                            ForEach(FilmPreset.allCases) { preset in
                                let source = FilmSource.preset(preset)
                                NavigationLink(value: source) {
                                    FilmPresetTile(preset: preset, image: preparedHome.presetCovers[preset])
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !visibleCustomFilters.isEmpty {
                            Text("Custom filters")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.4))
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, 4)

                            LazyVGrid(columns: gridColumns(availableWidth: geometry.size.width), spacing: 12) {
                                ForEach(visibleCustomFilters) { lut in
                                    let source = lut.source
                                    NavigationLink(value: source) {
                                        CustomLUTTile(lut: lut, image: preparedHome.customCover)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            deleteCustomLUT(lut)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 14)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                    .pageContentWidth(PageLayout.browseWidth)
                }
                .background(Color.black)
                .navigationTitle("Films")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel("Import LUT")
                        .accessibilityHint("Pick a .cube file to use as a custom filter")
                    }
                }
                .navigationDestination(for: FilmSource.self) { source in
                    CameraView(source: source)
                }
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result)
                }
                .sheet(isPresented: $showImportSheet) {
                    ImportLUTSheet(
                        name: $importName,
                        iso: $importISO,
                        encoding: $importEncoding,
                        isImporting: isImporting,
                        onConfirm: confirmImport,
                        onCancel: cancelImport
                    )
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled(isImporting)
                    .onDisappear { if !isImporting { cancelImport() } }
                }
                .alert(operationErrorTitle, isPresented: $showImportError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(importError ?? String(localized: "Unknown error"))
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Keep the prepared rows until the live query actually has a result. An initial
            // empty delivery must not flash away already prepared custom filters.
            if !customLUTs.isEmpty || initialCustomFilters.isEmpty { usesLiveCustomFilters = true }
            else if let current = try? modelContext.fetch(FetchDescriptor<CustomLUT>(sortBy: [SortDescriptor(\CustomLUT.createdAt, order: .reverse)])) {
                initialCustomFilters = current.filter { !$0.isDeleted }.map(HomeCustomFilter.init)
                if initialCustomFilters.isEmpty { usesLiveCustomFilters = true }
            }
        }
        .onChange(of: customLUTs.filter { !$0.isDeleted }.map(\.id)) { oldIDs, newIDs in
            if !newIDs.isEmpty || !oldIDs.isEmpty || initialCustomFilters.isEmpty { usesLiveCustomFilters = true }
        }
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        operationErrorTitle = "Import failed"
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importTask?.cancel()
            importTask = Task {
                do {
                    let cube = try await LUTImportPreparation.shared.read(url)
                    guard !Task.isCancelled else { return }
                    importedCube = cube
                    importEncoding = .sRGB
                    importName = url.deletingPathExtension().lastPathComponent
                    importISO = "200"
                    showImportSheet = true
                } catch {
                    guard !Task.isCancelled else { return }
                    importError = String(format: String(localized: "Couldn't parse the .cube file: %@"), error.localizedDescription)
                    showImportError = true
                }
            }

        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func confirmImport() {
        operationErrorTitle = "Import failed"
        guard let cube = importedCube, !isImporting else { return }

        let enteredISO = Float(importISO) ?? 200
        let iso = enteredISO.isFinite && enteredISO > 0 ? min(enteredISO, 102_400) : 200
        let id = UUID()
        let fileName = "\(id.uuidString).jslut"

        let dir = CustomLUT.storageDirectory
        let destURL = dir.appendingPathComponent(fileName)
        let encoding = importEncoding
        let displayName = importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Custom") : importName
        isImporting = true
        importTask = Task {
            defer { isImporting = false }
            do {
                let dimension = try await LUTImportPreparation.shared.save(cube, encoding: encoding, to: destURL)
                try Task.checkCancellation()
                let customLUT = CustomLUT(displayName: displayName, fileName: fileName, iso: iso, dimension: dimension)
                customLUT.id = id
                modelContext.insert(customLUT)
                do { try modelContext.save() }
                catch { modelContext.rollback(); throw error }
                initialCustomFilters.insert(HomeCustomFilter(customLUT), at: 0)
                showImportSheet = false
                importedCube = nil
            } catch {
                // Roll back only the import's index save, then remove its orphan off-main.
                _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: destURL) }.value
                guard !Task.isCancelled else { return }
                importError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
                showImportError = true
            }
        }
    }

    private func cancelImport() {
        showImportSheet = false
        importTask?.cancel()
        importedCube = nil
    }

    private func deleteCustomLUT(_ snapshot: HomeCustomFilter) {
        do {
            _ = try Self.deletePreparedCustomFilter(id: snapshot.id, queried: customLUTs, in: modelContext)
            initialCustomFilters.removeAll { $0.id == snapshot.id }
        } catch {
            operationErrorTitle = "Could not delete filter"
            importError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
            showImportError = true
        }
    }

    /// A prepared tile can be actionable before @Query delivers its first model array.
    /// Missing records only retire the tile; their former file is left for normal maintenance.
    static func deletePreparedCustomFilter(id: UUID, queried: [CustomLUT], in context: ModelContext) throws -> Bool {
        let model: CustomLUT?
        if let cached = queried.first(where: { !$0.isDeleted && $0.id == id }) { model = cached }
        else {
            var descriptor = FetchDescriptor<CustomLUT>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            model = try context.fetch(descriptor).first { !$0.isDeleted }
        }
        guard let model else { return false }
        try CustomLUTPersistence.delete(model, in: context)
        return true
    }

}

// MARK: - 导入确认 Sheet
struct ImportLUTSheet: View {
    @Binding var name: String
    @Binding var iso: String
    @Binding var encoding: LUTColorEncoding
    let isImporting: Bool
    @State private var showCompatibility = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter name") {
                    TextField("Name", text: $name)
                }
                Section("ISO") {
                    TextField("200", text: $iso)
                        .keyboardType(.numberPad)
                }
                Section {
                    Picker("LUT color space", selection: $encoding) {
                        Text(verbatim: "sRGB").tag(LUTColorEncoding.sRGB)
                        Text(verbatim: "Rec.709 Gamma 2.4").tag(LUTColorEncoding.rec709Gamma24)
                    }
                    Button("LUT compatibility", systemImage: "info.circle") { showCompatibility = true }
                }
            }
            .disabled(isImporting)
            .navigationTitle("Import LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                        .bold()
                        .disabled(isImporting)
                }
            }
            .overlay { if isImporting { ProgressView() } }
            .alert("LUT compatibility", isPresented: $showCompatibility) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Import a 3D .cube with a 0–1 input range. Input and output must both use the selected SDR color space. Camera Log, HDR and 1D shaper LUTs must first be converted to an sRGB-to-sRGB look in a color-managed editor. A .cube file cannot reliably identify its color space. Existing imports keep their sRGB interpretation.")
            }
        }
    }
}

// MARK: - Grid tiles

/// Cover-art tile for a built-in film preset. The image is sourced from the
/// bundled film-card library via `FilmPreset.libraryCardImage`.
struct FilmPresetTile: View {
    let preset: FilmPreset
    let image: UIImage?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Text(preset.rawSimulation?.displayName ?? preset.displayName)
                .font(.system(size: (sizeClass == .regular ? 15 : 11) * captionScale, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.rawSimulation != nil ? Text(verbatim: preset.displayName) : Text("\(preset.displayName), ISO \(Int(preset.iso))"))
        .accessibilityHint("Start shooting with this film")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Color.white.opacity(0.05)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .clipShape(shape)
    }
}

/// Cover-art tile for a custom LUT. No matching catalog image, so we
/// render an accent-tinted icon in the same square cell shape.
struct CustomLUTTile: View {
    let lut: HomeCustomFilter
    let image: UIImage?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    private static let accent = Color(red: 0.6, green: 0.5, blue: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Text(lut.displayName)
                .font(.system(size: (sizeClass == .regular ? 15 : 11) * captionScale, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Custom filter \(lut.displayName), ISO \(Int(lut.iso))"))
        .accessibilityHint("Start shooting with this filter")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Self.accent.opacity(0.18)
            if let image {
                Image(uiImage: image).renderingMode(.template)
                    .foregroundColor(Self.accent)
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(Self.accent)
            }
        }
        .clipShape(shape)
    }
}
