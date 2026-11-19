import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct FilmHomeView: View {
    let preparedHome: HomePreparationSnapshot
    @StateObject private var settings: FilmPageSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale
    @Environment(\.displayScale) private var displayScale
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
    @State private var showsManagement = false
    @State private var showsCatalog = false
    @State private var presetCovers: [FilmPreset: UIImage]
    @State private var pendingDelete: FilmSource?

    private var textVisibility: FilmTileTextVisibility { settings.textVisibility }

    private func gridColumns(availableWidth: CGFloat, textVisibility: FilmTileTextVisibility) -> [GridItem] {
        let isRegular = sizeClass == .regular
        let count = PageLayout.homeColumns(width: availableWidth, isRegular: isRegular, scale: gridScale,
            minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: textVisibility))
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    init(preparedHome: HomePreparationSnapshot, settings: FilmPageSettings? = nil) {
        self.preparedHome = preparedHome
        _settings = StateObject(wrappedValue: settings ?? .shared)
        _presetCovers = State(initialValue: preparedHome.presetCovers)
        _initialCustomFilters = State(initialValue: preparedHome.customFilters)
    }

    private var visibleCustomFilters: [HomeCustomFilter] {
        usesLiveCustomFilters ? customLUTs.filter { !$0.isDeleted }.map(HomeCustomFilter.init) : initialCustomFilters
    }

    var body: some View {
        let sources = FilmPreset.allCases.map(FilmSource.preset) + visibleCustomFilters.map(\.source)
        let visibleFilms = settings.preferences.ordered(sources).filter(settings.preferences.isVisible)
        let hasOfficialFilms = visibleFilms.contains { if case .preset = $0 { return true }; return false }
        let gridTextVisibility = FilmTileTextVisibility(showsTitle: textVisibility.showsTitle,
            showsSubtitle: textVisibility.showsSubtitle && hasOfficialFilms)

        return NavigationStack {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if visibleFilms.isEmpty {
                            ContentUnavailableView {
                                Label("No films shown", systemImage: "camera.filters")
                            } actions: {
                                Button("Add Films") { showsCatalog = true }
                                    .buttonStyle(.bordered)
                            }
                            .frame(minHeight: 300)
                        } else {
                            LazyVGrid(columns: gridColumns(availableWidth: geometry.size.width, textVisibility: gridTextVisibility),
                                spacing: FilmTileLayout.rowSpacing(showsText: gridTextVisibility.showsText)) {
                                ForEach(visibleFilms) { source in
                                    NavigationLink(value: source) {
                                        switch source {
                                        case .preset(let preset):
                                            FilmPresetTile(preset: preset, image: presetCovers[preset], textVisibility: textVisibility)
                                        case .custom(let id, let name, let iso, let fileName):
                                            CustomLUTTile(lut: HomeCustomFilter(id: id, displayName: name, iso: iso, fileName: fileName),
                                                image: preparedHome.customCover, textVisibility: textVisibility)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("films.film.\(source.id)")
                                    .contextMenu {
                                        if case .preset(let preset) = source {
                                            Button { settings.setVisible(preset, false) } label: {
                                                Label("Remove from Films", systemImage: "minus.circle")
                                            }
                                        } else {
                                            Button(role: .destructive) { pendingDelete = source } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 14)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appPageBackground()
                .navigationTitle("Films")
                .navigationBarTitleDisplayMode(.inline)
                .softScrollEdges()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showsManagement = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Manage Films")
                        .accessibilityIdentifier("films.manage")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showsCatalog = true } label: {
                                Label("Film Vault", systemImage: "shippingbox")
                            }
                            Button { showFileImporter = true } label: {
                                Label("Import LUT", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel("Add Films")
                        .accessibilityIdentifier("films.add")
                    }
                }
                .navigationDestination(for: FilmSource.self) { source in
                    CameraView(source: source, filmSettings: settings)
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
                .sheet(isPresented: $showsManagement) {
                    FilmManagementView(settings: settings, sources: sources,
                        presetCovers: presetCovers, onDelete: deleteCustomLUT)
                }
                .sheet(isPresented: $showsCatalog) {
                    NavigationStack {
                        FilmCardLibraryView(settings: settings)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showsCatalog = false }
                                }
                            }
                    }
                }
                .modifier(FilmDeletionConfirmation(pending: $pendingDelete, onDelete: deleteCustomLUT))
                .alert(operationErrorTitle, isPresented: $showImportError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(importError ?? String(localized: "Unknown error"))
                }
            }
            .mainTabRoot(.films)
        }
        .task(id: settings.preferences.addedPresetIDs) {
            let presets = settings.preferences.addedPresets
            presetCovers = presetCovers.filter { settings.preferences.addedPresetIDs.contains($0.key.rawValue) }
            let missing = presets.filter { presetCovers[$0] == nil }
            guard !missing.isEmpty else { return }
            do {
                let covers = try await FilmPresetCoverPreparation.prepareHome(presets: missing, displayScale: displayScale)
                try Task.checkCancellation()
                presetCovers.merge(covers) { _, new in new }
            } catch is CancellationError {
                return
            } catch {
                Diagnostics.emit("film_home_covers_failed", fields: Diagnostics.errorFields(error))
            }
        }
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

    private func deleteCustomLUT(_ id: UUID) throws {
        _ = try CustomLUTPersistence.deletePreparedCustomFilter(id: id, queried: customLUTs, in: modelContext)
        initialCustomFilters.removeAll { $0.id == id }
        settings.removeCustomFilm(id: id)
    }
}
