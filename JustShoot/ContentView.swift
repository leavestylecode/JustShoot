import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
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
    /// 命名空间用于把列表 tile 的封面与拍摄页通过 zoom 过渡关联。
    /// 每个 tile 用 source.id 作为匹配键；拍摄页 destination 同 id 应用 navigationTransition(.zoom)。
    @Namespace private var coverZoom

    /// Adaptive grid of preset / custom-LUT tiles. `minimum: 100` keeps three
    /// columns on iPhone (incl. 13 mini → ~109pt tiles) and expands to 6+
    /// columns on iPad portrait without per-device math.
    private let gridColumns = [
        GridItem(.adaptive(minimum: 100), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(FilmPreset.allCases) { preset in
                            let source = FilmSource.preset(preset)
                            NavigationLink(value: source) {
                                FilmPresetTile(preset: preset)
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: source.id, in: coverZoom)
                        }
                    }

                    if !customLUTs.isEmpty {
                        Text("Custom filters")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.4))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 4)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(customLUTs) { lut in
                                let source = FilmSource.from(lut)
                                NavigationLink(value: source) {
                                    CustomLUTTile(lut: lut)
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
            .alert("Import failed", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? String(localized: "Unknown error"))
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await preloadResources()
        }
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = String(localized: "Couldn't access the file")
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
                importError = String(format: String(localized: "Couldn't parse the .cube file: %@"), error.localizedDescription)
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

            // 预加载到缓存
            let source = FilmSource.from(customLUT)
            Task.detached(priority: .userInitiated) {
                FilmProcessor.shared.preload(source: source)
            }
        } catch {
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

    private func deleteCustomLUT(_ lut: CustomLUT) {
        // 删除文件
        try? FileManager.default.removeItem(at: lut.fileURL)
        // 同步清理 FilmProcessor 内存里这枚 LUT 的缓存——否则进程存活期间会一直占用
        //（一个 64³ cube ≈ 3MB），随导入/删除次数无上限增长。趁 lut 仍有效先取 cacheKey。
        FilmProcessor.shared.removeCachedLUT(cacheKey: FilmSource.from(lut).lutCacheKey)
        modelContext.delete(lut)
        try? modelContext.save()
    }

    // MARK: - Preload

    private func preloadResources() async {
        // 在主 actor 上把 @Model 的 CustomLUT 投影为 Sendable 的 FilmSource，
        // 避免把非 Sendable 的 SwiftData 模型带入 Task.detached
        let customSources: [FilmSource] = customLUTs.map { FilmSource.from($0) }

        // 首屏只等待内置 LUT。它们已在构建期编译为约 250KB 的 .jslut，8 个合计约 10ms。
        // 直接在当前启动任务串行读取，避免为极短工作创建 detached task 时触发 Swift 并发
        // 执行器冷启动、线程调度及返回 MainActor 的额外等待（真机曾额外消耗约 1.6s）。
        let builtInTimer = Log.perf("startup_builtin_luts", logger: Log.lut)
        for preset in FilmPreset.allCases {
            FilmProcessor.shared.preload(preset: preset)
        }
        builtInTimer.end("count=\(FilmPreset.allCases.count)")

        // 内置 LUT 已完成。首页始终直接展示，不再维护额外 loading UI。
        // 相机权限请求（首次会弹系统 alert）放到 LUT 之后异步触发。
        // 进入 CameraView 时 requestCameraPermission 也会再走一次 .notDetermined 分支，
        // 这里预触发只是为了首次启动用户点 tile 前权限就准备好。
        // 首屏稳定后再按顺序做剩余重活，杜绝旧实现的启动资源风暴：
        //   1. 编译实时预览 PSO；
        //   2. 创建静态照片 Metal CIContext；
        //   3. 串行解析用户自定义 LUT（不再阻塞首屏）；
        //   4. 稍作让步后拉起 Core Image + VideoToolbox 的 Live Photo 冷管线。
        Task.detached(priority: .utility) {
            let postwarmTimer = Log.perf("startup_postwarm", logger: Log.lut)
            PreviewMetalResources.prepare()
            FilmProcessor.shared.prepareRendering()
            for source in customSources {
                FilmProcessor.shared.preload(source: source)
            }
            try? await Task.sleep(for: .milliseconds(400))
            await LivePhotoProcessor.prewarm()
            postwarmTimer.end("custom_luts=\(customSources.count)")
        }

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
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
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

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
        .task(id: preset.rawValue) {
            // Adaptive grid → tiles range from ~100pt (iPad) up to ~170pt
            // (iPhone Pro Max with 2 cols). Size at the upper bound × scale,
            // floored at 300 to satisfy the thumbnail API's minimum.
            let pixel = max(Int(180.0 * displayScale), 300)
            image = await FilmCardImageCache.shared.loadImage(
                imageName: preset.libraryCardImage,
                cacheKey: "preset_\(preset.rawValue)",
                maxPixel: pixel
            )
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
    let lut: CustomLUT

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
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(Self.accent)
        }
        .clipShape(shape)
    }
}
