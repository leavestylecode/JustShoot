import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct FilmHomeView: View {
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
        let count = PageLayout.homeColumns(width: availableWidth, isRegular: isRegular, scale: gridScale)
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
            _ = try CustomLUTPersistence.deletePreparedCustomFilter(id: snapshot.id, queried: customLUTs, in: modelContext)
            initialCustomFilters.removeAll { $0.id == snapshot.id }
        } catch {
            operationErrorTitle = "Could not delete filter"
            importError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
            showImportError = true
        }
    }
}
