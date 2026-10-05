import SwiftUI
import SwiftData
import UIKit

struct RecentPhotoThumbnail {
    let id: UUID
    let filterName: String
    let image: UIImage?
}

/// A presentation uses one committed snapshot, rather than reading a changing @Query in a sheet.
struct RecentPhotoPresentation: Identifiable {
    let id = UUID()
    let startPhoto: Photo
    let photos: [Photo]

    @MainActor
    static func load(in context: ModelContext, filterName: String) throws -> Self? {
        let descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.filmPresetName == filterName },
            sortBy: [SortDescriptor(\Photo.timestamp)])
        let photos = try context.fetch(descriptor).filter { !$0.isDeleted }
        guard let latest = photos.last else { return nil }
        return Self(startPhoto: latest, photos: photos)
    }

    @MainActor
    static func latest(in context: ModelContext, filterName: String) throws -> Photo? {
        var descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { $0.filmPresetName == filterName },
            sortBy: [SortDescriptor(\Photo.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// MARK: - 左下角最近照片 badge
/// 拍摄页左下角"最近一张"缩略图。持有按当前 `source.photoFilterName` 过滤的 @Query——
/// CameraView 切换 `source` 时此视图随 `init` 重建，predicate 自动更新到新胶片。
///
/// Hint carries the committed photo ID as well as its thumbnail. @Query drives refreshes;
/// tapping fetches a committed snapshot so a just-finished capture opens before @Query catches up.
struct RecentPhotosBadge: View {
    let source: FilmSource
    @Binding var lastThumbnailHint: RecentPhotoThumbnail?
    let isShutterBusy: Bool
    let isProcessing: Bool
    let controlRotationAngle: Angle
    let orientation: UIDeviceOrientation

    @Query private var photos: [Photo]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedDetail: RecentPhotoPresentation?
    @State private var openError: String?

    private struct ThumbnailRequest: Hashable {
        let sourceID: String
        let photoID: UUID?
    }

    private var currentHint: RecentPhotoThumbnail? {
        lastThumbnailHint?.filterName == source.photoFilterName ? lastThumbnailHint : nil
    }

    private static let thumbnailMaxPixel = 88

    init(
        source: FilmSource,
        lastThumbnailHint: Binding<RecentPhotoThumbnail?>,
        isShutterBusy: Bool,
        isProcessing: Bool,
        controlRotationAngle: Angle,
        orientation: UIDeviceOrientation
    ) {
        self.source = source
        self._lastThumbnailHint = lastThumbnailHint
        self.isShutterBusy = isShutterBusy
        self.isProcessing = isProcessing
        self.controlRotationAngle = controlRotationAngle
        self.orientation = orientation
        let filterName = source.photoFilterName
        _photos = Query(
            filter: #Predicate<Photo> { photo in
                photo.filmPresetName == filterName
            },
            sort: \Photo.timestamp
        )
    }

    var body: some View {
        Button { openRecentPhotos() } label: {
            ZStack {
                if let thumb = currentHint?.image {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
                if isShutterBusy || isProcessing {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.4))
                        .frame(width: 46, height: 46)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.7)
                }
            }
            .rotationEffect(controlRotationAngle)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
        }
        .accessibilityLabel(photos.isEmpty ? Text("Most recent photo") : Text("Most recent photo — \(photos.count) total"))
        .accessibilityHint(photos.isEmpty ? Text("No photos yet") : Text("Open larger view"))
        // 仅在快门 race 窗口禁用，让详情页可以在后处理进行中正常打开历史照片。
        .disabled((photos.isEmpty && currentHint == nil) || isShutterBusy)
        .task(id: ThumbnailRequest(sourceID: source.id, photoID: photos.last?.id)) {
            if lastThumbnailHint?.filterName != source.photoFilterName { lastThumbnailHint = nil }
            await loadFromQuery()
        }
        .sheet(item: $selectedDetail) { payload in
            NavigationStack {
                PhotoDetailView(photo: payload.startPhoto, allPhotos: payload.photos)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { selectedDetail = nil } label: {
                                Image(systemName: "xmark")
                                    .fontWeight(.semibold)
                            }
                            .tint(.white)
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(false)
            .preferredColorScheme(.dark)
        }
        .alert("Unable to open photos", isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } }
        )) {
            Button("OK", role: .cancel) { openError = nil }
        } message: { Text(openError ?? "") }
    }

    @MainActor
    private func openRecentPhotos() {
        let trace = DiagnosticTrace(id: currentHint?.id.uuidString ?? "recent-photos")
        trace.event("recent_photos_open_requested", "query_count=\(photos.count) has_hint=\(currentHint != nil)")
        do {
            // CaptureCompletion is emitted after the index commit, before @Query necessarily
            // observes it. Fetch on tap so the newly displayed thumbnail opens the new photo.
            guard let payload = try RecentPhotoPresentation.load(in: modelContext, filterName: source.photoFilterName) else {
                lastThumbnailHint = nil
                trace.event("recent_photos_open_failed", "reason=no_indexed_photos")
                openError = String(localized: "No saved photos are available yet. Please try again.")
                return
            }
            selectedDetail = payload
            trace.event("recent_photos_open_ready", "count=\(payload.photos.count) selected=\(payload.startPhoto.id)")
        } catch {
            trace.event("recent_photos_open_failed", Diagnostics.errorFields(error))
            openError = String(localized: "Photos could not be loaded. Please try again.")
        }
    }

    @MainActor
    private func loadFromQuery() async {
        let filterName = source.photoFilterName
        let previousHintID = lastThumbnailHint?.id
        do {
            guard let photo = try RecentPhotoPresentation.latest(in: modelContext, filterName: filterName) else {
                lastThumbnailHint = nil
                return
            }
            if currentHint?.id == photo.id, currentHint?.image != nil { return }
            let thumb = await PhotoImage.thumbnail(for: photo, maxPixel: Self.thumbnailMaxPixel)
            guard !Task.isCancelled, lastThumbnailHint?.id == previousHintID else { return }
            lastThumbnailHint = RecentPhotoThumbnail(id: photo.id, filterName: filterName, image: thumb)
        } catch {
            Diagnostics.emit("recent_thumbnail_failed", fields: Diagnostics.errorFields(error))
        }
    }
}

// MARK: - 底部胶片选择条
/// 右下角胶片封面点开后从底部弹出的横向胶片选择条。胶片顺序：
///   1. 内置预设（FilmPreset.allCases）
///   2. 用户导入的自定义 LUT（按 createdAt 倒序，与首页一致）
/// 当前选中胶片用黄色描边标识；点击后通过 onSelect 更新预览，面板保持展开以便连续比较。
/// 展开瞬间 ScrollViewReader 自动滚到当前胶片，便于看到"我现在在哪一张"。
struct FilmSourcePickerStrip: View {
    let current: FilmSource
    let customLUTs: [CustomLUT]
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onSelect: (FilmSource) -> Void

    /// 预热全部内置预设的封面缩略图缓存。第一次展开 picker 时 8 个 cell 会同帧从磁盘冷解码封面，
    /// 叠上展开动画 → 掉帧。进入拍摄页时调用本方法在后台先把这些封面解码进 NSCache，
    /// 真正展开时全部命中、零解码。cacheKey / maxPixel 必须与 `FilmSourcePickerCell.task` 一致，
    /// 否则缓存 key 对不上、预热作废。custom LUT 用占位图标渲染、无需预热。
    @MainActor
    static func preloadCovers(displayScale: CGFloat) {
        let pixel = FilmSourcePickerCell.coverPixel(displayScale: displayScale)
        for preset in FilmPreset.allCases {
            Task.detached(priority: .utility) {
                _ = await FilmCardImageCache.shared.loadImage(
                    imageName: preset.libraryCardImage,
                    cacheKey: "picker_\(preset.rawValue)",
                    maxPixel: pixel
                )
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmPreset.allCases) { preset in
                        let s = FilmSource.preset(preset)
                        FilmSourcePickerCell(
                            source: s,
                            isSelected: s.id == current.id,
                            contentRotation: contentRotation,
                            orientation: orientation
                        ) { onSelect(s) }
                        .id(s.id)
                    }
                    ForEach(customLUTs) { lut in
                        let s = FilmSource.from(lut)
                        FilmSourcePickerCell(
                            source: s,
                            isSelected: s.id == current.id,
                            contentRotation: contentRotation,
                            orientation: orientation
                        ) { onSelect(s) }
                        .id(s.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 68)
            .onAppear {
                // 展开后下一帧滚到当前胶片，避免 ScrollView 还没布局完就 scrollTo 失效。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .onChange(of: current.id) { _, newId in
                // 预览区左右滑动切胶片时 picker 条同步把新选中胶片滚到中心。
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Film picker"))
        }
    }
}

// MARK: - 曲线选择条
/// 只展示用户启用的内置/自定义曲线；末尾的管理入口可直接调整显隐或创建新效果。
struct FilmCurvePickerStrip: View {
    let curves: [FilmCurve]
    let current: FilmCurve
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onManage: () -> Void
    let onSelect: (FilmCurve) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(curves) { curve in
                        FilmCurvePickerCell(
                            curve: curve,
                            isSelected: curve == current,
                            contentRotation: contentRotation,
                            orientation: orientation
                        ) { onSelect(curve) }
                        .id(curve.id)
                    }
                    CurveManagerPickerCell(
                        contentRotation: contentRotation,
                        orientation: orientation,
                        onTap: onManage
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .frame(height: 78)
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
            .onChange(of: current.id) { _, newID in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Curve picker"))
        }
    }
}

// MARK: - 曲线效果卡
struct FilmCurvePickerCell: View {
    let curve: FilmCurve
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            FilmCurvePreviewCard(curve: curve, isSelected: isSelected)
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
            .scaleEffect(reduceMotion ? 1.0 : (isSelected ? 1.04 : 1.0))
            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.22), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(curve.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 拍摄条与曲线管理页共用的视觉组件，确保两处展示的是同一套名称、曲线差异和输出色阶。
struct FilmCurvePreviewCard: View {
    let curve: FilmCurve
    let isSelected: Bool
    var cardSize = CGSize(width: 68, height: 68)
    var graphSize = CGSize(width: 54, height: 34)

    var body: some View {
        VStack(spacing: 3) {
            Text(curve.displayName)
                .font(.system(
                    size: cardSize.width > 80 ? 11 : 9,
                    weight: isSelected ? .bold : .semibold,
                    design: .rounded
                ))
                .foregroundStyle(isSelected ? .yellow : .white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            CurveGraphView(curve: curve, accent: accentColor)
                .frame(width: graphSize.width, height: graphSize.height)

            CurveOutputStrip(curve: curve)
                .frame(width: graphSize.width, height: 5)
        }
        .padding(6)
        .frame(width: cardSize.width, height: cardSize.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            isSelected ? accentColor.opacity(0.22) : .white.opacity(0.10),
                            .white.opacity(0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.yellow : .white.opacity(0.14),
                    lineWidth: isSelected ? 2 : 0.5
                )
        }
        .shadow(
            color: isSelected ? accentColor.opacity(0.35) : .clear,
            radius: 7,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var accentColor: Color {
        switch curve.builtInPreset {
        case .some(.none): return Color(white: 0.82)
        case .some(.filmSoft): return Color(red: 0.96, green: 0.70, blue: 0.32)
        case .some(.openShadows): return Color(red: 0.35, green: 0.72, blue: 0.96)
        case .some(.punch): return Color(red: 1.00, green: 0.38, blue: 0.30)
        case .some(.matte): return Color(red: 0.78, green: 0.66, blue: 0.52)
        case .some(.fade): return Color(red: 0.70, green: 0.55, blue: 0.92)
        case .some(.warmPrint): return Color(red: 1.00, green: 0.56, blue: 0.22)
        case .some(.crossProcess): return Color(red: 0.92, green: 0.34, blue: 0.72)
        case nil: return Color(red: 0.38, green: 0.82, blue: 0.72)
        }
    }
}

private struct CurveManagerPickerCell: View {
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                Text("Manage")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.84))
            .frame(width: 68, height: 68)
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            }
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage film curves")
    }
}

// MARK: - 曲线差异图
/// 虚线是恒等响应；半透明面积直接显示预设相对恒等线提亮/压暗了多少。
/// 只有真正逐通道分离的 Warm Print / X-Pro 才画 RGB 三线，其他预设保持单线清晰度。
struct CurveGraphView: View {
    let curve: FilmCurve
    let accent: Color

    private static let red = Color(red: 1.00, green: 0.30, blue: 0.28)
    private static let green = Color(red: 0.22, green: 0.86, blue: 0.40)
    private static let blue = Color(red: 0.26, green: 0.52, blue: 1.00)

    var body: some View {
        Canvas { context, size in
            let data = curve.previewData
            let identity = FilmCurve.builtIn(.none).previewData.master

            var midtoneGuide = Path()
            midtoneGuide.move(to: CGPoint(x: size.width / 2, y: 2))
            midtoneGuide.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            context.stroke(midtoneGuide, with: .color(.white.opacity(0.07)), lineWidth: 0.5)

            let identityPath = Self.linePath(from: identity, in: size)
            context.stroke(
                identityPath,
                with: .color(.white.opacity(0.24)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [2, 2])
            )

            if !curve.isNeutral {
                context.fill(
                    Self.deltaPath(curve: data.master, identity: identity, in: size),
                    with: .color(accent.opacity(0.20))
                )
            }

            if curve.usesChannelCurves {
                for (values, color) in [
                    (data.red, Self.red),
                    (data.green, Self.green),
                    (data.blue, Self.blue)
                ] {
                    context.stroke(
                        Self.linePath(from: values, in: size),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            context.stroke(
                Self.linePath(from: data.master, in: size),
                with: .color(curve.usesChannelCurves ? .white.opacity(0.88) : accent),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func linePath(from values: [Float], in size: CGSize) -> Path {
        var path = Path()
        let inset: CGFloat = 2
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        for (i, v) in values.enumerated() {
            let x = inset + width * CGFloat(i) / CGFloat(values.count - 1)
            let y = inset + height * CGFloat(1.0 - Double(v))
            let point = CGPoint(x: x, y: y)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private static func deltaPath(curve: [Float], identity: [Float], in size: CGSize) -> Path {
        var path = linePath(from: curve, in: size)
        let inset: CGFloat = 2
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        for index in identity.indices.reversed() {
            let x = inset + width * CGFloat(index) / CGFloat(identity.count - 1)
            let y = inset + height * CGFloat(1.0 - Double(identity[index]))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 五档输出色阶
/// 比曲线图更直接地显示黑位、暗部、中间调、高光和白点；RGB 曲线的色偏也会真实显现。
struct CurveOutputStrip: View {
    let curve: FilmCurve

    private static let inputs: [Float] = [0.03, 0.18, 0.42, 0.70, 0.96]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Self.inputs.indices, id: \.self) { index in
                let sample = curve.sampleGray(Self.inputs[index])
                Rectangle()
                    .fill(
                        Color(
                            red: Double(sample.red),
                            green: Double(sample.green),
                            blue: Double(sample.blue)
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

// MARK: - 胶片单 cell
/// Picker 条里单个胶片格子：纯 52×52 封面。选中态用黄色描边标识；用户可通过封面图本身
/// 辨识胶片，不再叠加文字（节省空间 + 减少视觉噪声）。VoiceOver 仍朗读 source.displayName。
struct FilmSourcePickerCell: View {
    let source: FilmSource
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onTap: () -> Void

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    /// Reduce Motion 时关闭 selected 状态的 scaleEffect bounce——它是装饰性放大，
    /// 黄色描边已足以表达选中。rotation 跟随设备方向是功能性的（让用户横握时看清内容），
    /// HIG 不视为应抑制的 motion，保留。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let customAccent = Color(red: 0.6, green: 0.5, blue: 0.8)
    static let coverSize: CGFloat = 52

    /// 封面解码像素：52pt × scale × 1.5 余量，下限 100。供 cell 的 .task 与
    /// `FilmSourcePickerStrip.preloadCovers` 共用，确保预热与实际加载的 maxPixel 一致。
    static func coverPixel(displayScale: CGFloat) -> Int {
        max(Int(coverSize * displayScale * 1.5), 100)
    }

    var body: some View {
        Button(action: onTap) {
            // 整块随设备方向旋转，与右下角封面 / 左下角照片角标同款手感。cell 只有极淡描边
            // （未选 0.08 / 选中黄 2pt），不像 glass 那样有高光，整块旋转不显得放大。
            cover
                .frame(width: Self.coverSize, height: Self.coverSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.yellow : .white.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
                }
                .rotationEffect(contentRotation)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
                .scaleEffect(reduceMotion ? 1.0 : (isSelected ? 1.06 : 1.0))
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(source.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: source.id) {
            // 仅 preset 有 catalog 封面；custom LUT 用占位图标渲染。
            guard case .preset(let preset) = source else {
                image = nil
                return
            }
            image = await FilmCardImageCache.shared.loadImage(
                imageName: preset.libraryCardImage,
                cacheKey: "picker_\(preset.rawValue)",
                maxPixel: Self.coverPixel(displayScale: displayScale)
            )
        }
    }

    @ViewBuilder
    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            switch source {
            case .preset:
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            case .custom:
                Self.customAccent.opacity(0.18)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Self.customAccent)
            }
        }
        .clipShape(shape)
    }
}
