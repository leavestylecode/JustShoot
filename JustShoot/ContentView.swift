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

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    let counts = presetCountMap

                    // 内置胶片
                    ForEach(FilmPreset.allCases) { preset in
                        NavigationLink(value: FilmSource.preset(preset)) {
                            FilmPresetCard(preset: preset, photoCount: counts[preset.rawValue] ?? 0)
                        }
                    }

                    // 自定义 LUT 区域
                    if !customLUTs.isEmpty {
                        HStack {
                            Text("自定义滤镜")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                            Spacer()
                        }
                        .padding(.top, 8)

                        ForEach(customLUTs) { lut in
                            let source = FilmSource.from(lut)
                            NavigationLink(value: source) {
                                CustomLUTCard(
                                    lut: lut,
                                    photoCount: counts[source.photoFilterName] ?? 0
                                )
                            }
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
                .padding(.horizontal, 20)
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
                        Image(systemName: "plus.circle")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: "gallery") {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 15, weight: .medium))
                            if totalPhotoCount > 0 {
                                Text("\(totalPhotoCount)")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { _ in
                GalleryView()
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

    private var totalPhotoCount: Int {
        photos.count
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

    private func handleFileImport(_ result: Result<[URL], Error>) {
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
        await Task.detached(priority: .userInitiated) {
            for preset in FilmPreset.allCases {
                FilmProcessor.shared.preload(preset: preset)
            }
        }.value

        // 预加载自定义 LUT
        let luts = customLUTs
        if !luts.isEmpty {
            await Task.detached(priority: .utility) {
                for lut in luts {
                    FilmProcessor.shared.preload(source: .from(lut))
                }
            }.value
        }

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

// MARK: - 胶片卡片
struct FilmPresetCard: View {
    let preset: FilmPreset
    let photoCount: Int

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
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(preset.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Text("ISO \(Int(preset.iso))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))

                    if photoCount > 0 {
                        Text("\(photoCount) 张")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                    }
                }
            }

            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 自定义 LUT 卡片
struct CustomLUTCard: View {
    let lut: CustomLUT
    let photoCount: Int

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.6, green: 0.5, blue: 0.8))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(lut.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Text("ISO \(Int(lut.iso))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))

                    if photoCount > 0 {
                        Text("\(photoCount) 张")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 0.6, green: 0.5, blue: 0.8))
                    }
                }
            }

            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
