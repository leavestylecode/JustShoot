import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @Query(sort: \CustomLUT.createdAt, order: .reverse) private var customLUTs: [CustomLUT]
    @State private var isPreloading = true
    @State private var showFileImporter = false
    @State private var importedFileURL: URL?
    @State private var importedCube: CubeLUT?
    @State private var showImportSheet = false
    @State private var importName = ""
    @State private var importISO = "200"
    @State private var importError: String?
    @State private var showImportError = false

    /// Three-column grid of preset / custom-LUT tiles.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                let counts = presetCountMap

                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(FilmPreset.allCases) { preset in
                            NavigationLink(value: FilmSource.preset(preset)) {
                                FilmPresetTile(preset: preset, photoCount: counts[preset.rawValue] ?? 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !customLUTs.isEmpty {
                        Text("自定义滤镜")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.4))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 4)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(customLUTs) { lut in
                                let source = FilmSource.from(lut)
                                NavigationLink(value: source) {
                                    CustomLUTTile(
                                        lut: lut,
                                        photoCount: counts[source.photoFilterName] ?? 0
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteCustomLUT(lut)
                                    } label: {
                                        Label("删除", systemImage: "trash")
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
            .navigationTitle("JustShoot")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("导入 LUT")
                    .accessibilityHint("选择一个 .cube 文件作为自定义滤镜")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: "cards") {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .accessibilityLabel("胶片图鉴")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: "gallery") {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .accessibilityLabel("相册")
                }
            }
            .navigationDestination(for: String.self) { value in
                switch value {
                case "cards": FilmCardLibraryView()
                default:      GalleryView()
                }
            }
            .navigationDestination(for: FilmSource.self) { source in
                CameraView(source: source)
            }
            .safeAreaInset(edge: .bottom) {
                if isPreloading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("正在准备相机...")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.9))
                }
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
            .alert("导入失败", isPresented: $showImportError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(importError ?? "未知错误")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await preloadResources()
        }
    }

    private var presetCountMap: [String: Int] {
        var counts: [String: Int] = [:]
        for photo in photos {
            if let name = photo.filmPresetName {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "无法访问文件"
                showImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let cube = try FilmProcessor.parseCubeFile(text)
                importedFileURL = url
                importedCube = cube
                importName = url.deletingPathExtension().lastPathComponent
                importISO = "200"
                showImportSheet = true
            } catch {
                importError = "无法解析 .cube 文件：\(error.localizedDescription)"
                showImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func confirmImport() {
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
                importError = "无法访问文件"
                showImportError = true
                return
            }
            defer { sourceURL.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destURL)

            let customLUT = CustomLUT(displayName: importName.isEmpty ? "自定义" : importName,
                                      fileName: fileName, iso: iso, dimension: cube.dimension)
            customLUT.id = id
            modelContext.insert(customLUT)
            try modelContext.save()

            // 预加载到缓存
            let source = FilmSource.from(customLUT)
            Task.detached(priority: .userInitiated) {
                FilmProcessor.shared.preload(source: source)
            }
        } catch {
            importError = "保存失败：\(error.localizedDescription)"
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

    private func deleteCustomLUT(_ lut: CustomLUT) {
        // 删除文件
        try? FileManager.default.removeItem(at: lut.fileURL)
        modelContext.delete(lut)
        try? modelContext.save()
    }

    // MARK: - Preload

    private func preloadResources() async {
        // 在主 actor 上把 @Model 的 CustomLUT 投影为 Sendable 的 FilmSource，
        // 避免把非 Sendable 的 SwiftData 模型带入 Task.detached
        let customSources: [FilmSource] = customLUTs.map { FilmSource.from($0) }

        // LUT 解析彼此独立，并行加载减少冷启动耗时（FilmProcessor 内部有锁保护缓存）
        await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for preset in FilmPreset.allCases {
                    group.addTask { FilmProcessor.shared.preload(preset: preset) }
                }
                for source in customSources {
                    group.addTask { FilmProcessor.shared.preload(source: source) }
                }
            }
        }.value

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                isPreloading = false
            }
        }
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
                Section("滤镜名称") {
                    TextField("名称", text: $name)
                }
                Section("ISO") {
                    TextField("200", text: $iso)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("导入 LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: onConfirm)
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
    let photoCount: Int
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var accentColor: Color {
        switch preset {
        case .fujiC200: return Color(red: 0.2, green: 0.7, blue: 0.6)
        case .fujiPro400H: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .fujiProvia100F: return Color(red: 0.3, green: 0.5, blue: 0.9)
        case .kodakPortra400: return Color(red: 0.95, green: 0.5, blue: 0.5)
        case .kodakVision5219: return Color(red: 0.4, green: 0.3, blue: 0.7)
        case .kodakVision5203: return Color(red: 0.3, green: 0.7, blue: 0.8)
        case .kodak5207: return Color(red: 0.4, green: 0.8, blue: 0.6)
        case .harmanPhoenix200: return Color(red: 0.9, green: 0.3, blue: 0.3)
        }
    }

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

                HStack(spacing: 4) {
                    Text("ISO \(Int(preset.iso))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                    if photoCount > 0 {
                        Text("\(photoCount) 张")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accentColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: preset.rawValue) {
            // 3-column grid → tiles ~120pt; multiply by display scale,
            // floor at 300 to match the film-card library cells.
            let pixel = max(Int(140.0 * displayScale), 300)
            image = await FilmCardImageCache.shared.loadImage(
                imageName: preset.libraryCardImage,
                cacheKey: "preset_\(preset.rawValue)",
                maxPixel: pixel
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(photoCount > 0
            ? "\(preset.displayName)，ISO \(Int(preset.iso))，已拍 \(photoCount) 张"
            : "\(preset.displayName)，ISO \(Int(preset.iso))")
        .accessibilityHint("开始使用此胶片拍摄")
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
        .glassEffect(.regular, in: shape)
    }
}

/// Cover-art tile for a custom LUT. No matching catalog image, so we
/// render an accent-tinted icon in the same square cell shape.
struct CustomLUTTile: View {
    let lut: CustomLUT
    let photoCount: Int

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

                HStack(spacing: 4) {
                    Text("ISO \(Int(lut.iso))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                    if photoCount > 0 {
                        Text("\(photoCount) 张")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Self.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(photoCount > 0
            ? "自定义滤镜 \(lut.displayName)，ISO \(Int(lut.iso))，已拍 \(photoCount) 张"
            : "自定义滤镜 \(lut.displayName)，ISO \(Int(lut.iso))")
        .accessibilityHint("开始使用此滤镜拍摄")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Self.accent.opacity(0.18)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(Self.accent)
        }
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
    }
}
