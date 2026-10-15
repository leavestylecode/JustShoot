import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    let preparedHome: HomePreparationSnapshot
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @State private var showFileImporter = false
    @State private var importedFileURL: URL?
    @State private var importedCube: CubeLUT?
    @State private var showImportSheet = false
    @State private var importName = ""
    @State private var importISO = "200"
    @State private var importError: String?
    @State private var showImportError = false
    @State private var operationErrorTitle: LocalizedStringKey = "Import failed"
    @State private var importTask: Task<Void, Never>?
    @State private var initialCustomFilters: [HomeCustomFilter]
    @State private var usesLiveCustomFilters = false
    /// 命名空间用于把列表 tile 的封面与拍摄页通过 zoom 过渡关联。
    /// 每个 tile 用 source.id 作为匹配键；拍摄页 destination 同 id 应用 navigationTransition(.zoom)。
    @Namespace private var coverZoom

    /// Adaptive grid of preset / custom-LUT tiles. `minimum: 100` keeps three
    /// columns on iPhone (incl. 13 mini → ~109pt tiles) and expands to 6+
    /// columns on iPad portrait without per-device math.
    private let gridColumns = [
        GridItem(.adaptive(minimum: 100), spacing: 10)
    ]

    init(preparedHome: HomePreparationSnapshot) {
        self.preparedHome = preparedHome
        _initialCustomFilters = State(initialValue: preparedHome.customFilters)
    }

    private var visibleCustomFilters: [HomeCustomFilter] {
        usesLiveCustomFilters ? customLUTs.filter { !$0.isDeleted }.map(HomeCustomFilter.init) : initialCustomFilters
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(FilmPreset.allCases) { preset in
                            let source = FilmSource.preset(preset)
                            NavigationLink(value: source) {
                                FilmPresetTile(preset: preset, image: preparedHome.presetCovers[preset])
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: source.id, in: coverZoom)
                        }
                    }

                    if !visibleCustomFilters.isEmpty {
                        Text("Custom filters")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.4))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 4)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(visibleCustomFilters) { lut in
                                let source = lut.source
                                NavigationLink(value: source) {
                                    CustomLUTTile(lut: lut, image: preparedHome.customCover)
                                }
                                .buttonStyle(.plain)
                                .matchedTransitionSource(id: source.id, in: coverZoom)
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
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(Color.black)
            // 首页不再显示大标题"JustShoot"（改用底部 tab 栏导航）；保留紧凑 nav bar 承载左上
            // 的 + 导入按钮。相册 / 卡片库已提升为 tab，原工具栏入口与其字符串 destination 一并移除。
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
                    .navigationTransition(.zoom(sourceID: source.id, in: coverZoom))
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
                    onConfirm: confirmImport,
                    onCancel: cancelImport
                )
                .presentationDetents([.height(280)])
            }
            .alert(operationErrorTitle, isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? String(localized: "Unknown error"))
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
                    let cube = try await Task.detached(priority: .userInitiated) {
                        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                        defer { url.stopAccessingSecurityScopedResource() }
                        return try FilmProcessor.parseCubeFile(FilmProcessor.readCubeText(from: url))
                    }.value
                    guard !Task.isCancelled else { return }
                    importedFileURL = url
                    importedCube = cube
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
        guard let sourceURL = importedFileURL, let cube = importedCube else { return }

        let iso = Float(importISO) ?? 200
        let id = UUID()
        let fileName = "\(id.uuidString).cube"

        // 确保目录存在
        let dir = CustomLUT.storageDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destURL = dir.appendingPathComponent(fileName)

        do {
            guard sourceURL.startAccessingSecurityScopedResource() else {
                importError = String(localized: "Couldn't access the file")
                showImportError = true
                return
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destURL)

            let displayName = importName.isEmpty ? String(localized: "Custom") : importName
            let customLUT = CustomLUT(displayName: displayName,
                                      fileName: fileName, iso: iso, dimension: cube.dimension)
            customLUT.id = id
            modelContext.insert(customLUT)
            try modelContext.save()
            initialCustomFilters.insert(HomeCustomFilter(customLUT), at: 0)

            // Load the table when selected; importing an unused LUT needs no second parse or cache entry.
        } catch {
            modelContext.rollback()
            // 文件可能已写入而行保存失败——删掉孤儿 .cube，否则 Documents/CustomLUTs 里
            // 累积无主文件（文件未写入时 removeItem 是无害 no-op）。
            try? FileManager.default.removeItem(at: destURL)
            importError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
            showImportError = true
        }

        showImportSheet = false
        importedFileURL = nil
        importedCube = nil
    }

    private func cancelImport() {
        showImportSheet = false
        importedFileURL = nil
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
            }
            .navigationTitle("Import LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                        .bold()
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("ISO \(Int(preset.iso))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(preset.displayName), ISO \(Int(preset.iso))"))
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

    private static let accent = Color(red: 0.6, green: 0.5, blue: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(lut.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("ISO \(Int(lut.iso))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
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
