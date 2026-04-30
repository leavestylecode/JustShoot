import SwiftUI
import UIKit

// MARK: - 入口卡片（放在 ContentView 主菜单底部）

struct FilmCardLibraryEntryCard: View {
    private static let accent = Color(red: 0.85, green: 0.6, blue: 0.3)

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.accent)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("胶片图鉴")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("浏览 550 款胶片包装")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.3))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("胶片图鉴")
        .accessibilityHint("浏览所有胶片包装卡片")
    }
}

// MARK: - 颜色调色板（与离线脚本输出的桶名对齐）

enum CardColorPalette {
    /// 显示顺序：暖→冷→中性
    static let order: [String] = [
        "red", "orange", "yellow", "green", "blue", "purple", "brown", "black", "white", "gray"
    ]

    static func chineseName(_ key: String) -> String {
        switch key {
        case "red": return "红"
        case "orange": return "橙"
        case "yellow": return "黄"
        case "green": return "绿"
        case "blue": return "蓝"
        case "purple": return "紫"
        case "brown": return "棕"
        case "black": return "黑"
        case "white": return "白"
        case "gray": return "灰"
        default: return key
        }
    }

    static func swatch(_ key: String) -> Color {
        switch key {
        case "red": return Color(red: 0.95, green: 0.27, blue: 0.27)
        case "orange": return Color(red: 0.97, green: 0.58, blue: 0.20)
        case "yellow": return Color(red: 0.99, green: 0.83, blue: 0.20)
        case "green": return Color(red: 0.30, green: 0.75, blue: 0.40)
        case "blue": return Color(red: 0.25, green: 0.55, blue: 0.95)
        case "purple": return Color(red: 0.65, green: 0.40, blue: 0.85)
        case "brown": return Color(red: 0.55, green: 0.38, blue: 0.25)
        case "black": return Color(red: 0.10, green: 0.10, blue: 0.10)
        case "white": return Color(red: 0.95, green: 0.95, blue: 0.95)
        case "gray": return Color(red: 0.55, green: 0.55, blue: 0.55)
        default: return Color.gray
        }
    }
}

// MARK: - 图鉴主视图

struct FilmCardLibraryView: View {
    @State private var library = FilmCardLibrary.shared
    /// 品牌选择。可包含具体品牌名，或常量 `otherKey` 表示"其他（小品牌）"
    @State private var selectedBrands: Set<String> = []
    @State private var selectedFormats: Set<String> = []
    @State private var selectedColors: Set<String> = []
    /// ISO 选择。元素是 main 列表里的整数字符串（"50"/"100"/…）或 `otherKey` 表示"其他"
    @State private var selectedISOs: Set<String> = []
    @State private var showFilterSheet = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    /// 品牌 / 画幅阈值：count > 10 单列展示，其余收纳到"其他"
    private static let majorBrandThreshold = 10
    private static let majorFormatThreshold = 10
    /// 主 ISO 列表（覆盖率 ~73%），其他 ISO 与缺失 ISO 都进"其他"
    static let mainISOs: [Int] = [50, 100, 200, 400, 800, 1600]
    /// 颜色阈值：count >= 30 才显示为可选项；purple / brown 这种少量样本不进入筛选 UI
    private static let majorColorThreshold = 30
    /// "其他" 桶的字符串键。普通品牌/画幅/ISO 名称不会和这个字符串撞名。
    static let otherKey = "__OTHER__"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(filteredCards) { card in
                    NavigationLink(value: card) {
                        FilmCardThumbnail(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.black)
        .navigationTitle("胶片图鉴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 17, weight: hasActiveFilter ? .semibold : .medium))
                        .foregroundStyle(hasActiveFilter ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel(hasActiveFilter ? "筛选（已启用）" : "筛选")
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilmCardFilterSheet(
                brandChips: brandChips,
                formatChips: formatChips,
                availableColors: availableColors,
                isoChips: isoChips,
                selectedBrands: $selectedBrands,
                selectedFormats: $selectedFormats,
                selectedColors: $selectedColors,
                selectedISOs: $selectedISOs
            )
            .presentationDetents([.medium])
        }
        .navigationDestination(for: FilmCard.self) { card in
            FilmCardDetailView(card: card)
        }
        .task {
            await library.loadIfNeeded()
        }
        .overlay {
            if !library.isLoaded {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else if filteredCards.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text("调整筛选条件试试")
                }
                .foregroundColor(.white.opacity(0.6))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 过滤计算

    private var filteredCards: [FilmCard] {
        guard library.isLoaded else { return [] }
        let brands = selectedBrands
        let formats = selectedFormats
        let colors = selectedColors
        let isos = selectedISOs
        let majorBrands = majorBrandSet
        let majorFormats = majorFormatSet
        let mainISOSet = Set(Self.mainISOs)

        return library.all.filter { card in
            if !brands.isEmpty {
                if !brandMatches(card, selected: brands, majors: majorBrands) { return false }
            }
            if !formats.isEmpty {
                if !formatMatches(card, selected: formats, majors: majorFormats) { return false }
            }
            if !colors.isEmpty {
                guard let c = card.color, colors.contains(c) else { return false }
            }
            if !isos.isEmpty {
                if !isoMatches(card, selected: isos, mainISOSet: mainISOSet) { return false }
            }
            return true
        }
    }

    private func brandMatches(_ card: FilmCard, selected: Set<String>, majors: Set<String>) -> Bool {
        if let b = card.brand, majors.contains(b) {
            return selected.contains(b)
        }
        // 小品牌或无品牌 → 看是否选中"其他"
        return selected.contains(Self.otherKey)
    }

    private func formatMatches(_ card: FilmCard, selected: Set<String>, majors: Set<String>) -> Bool {
        if let f = card.format, majors.contains(f) {
            return selected.contains(f)
        }
        // 非主流画幅或无画幅 → 看是否选中"其他"
        return selected.contains(Self.otherKey)
    }

    private func isoMatches(_ card: FilmCard, selected: Set<String>, mainISOSet: Set<Int>) -> Bool {
        if let iso = card.iso, mainISOSet.contains(iso) {
            return selected.contains(String(iso))
        }
        // 长尾 ISO 或缺失 ISO → 看是否选中"其他"
        return selected.contains(Self.otherKey)
    }

    /// 主品牌集合（count > 阈值）
    private var majorBrandSet: Set<String> {
        Set(library.sortedBrands.filter { (library.byBrand[$0]?.count ?? 0) > Self.majorBrandThreshold })
    }

    /// 主画幅集合（count > 阈值）
    private var majorFormatSet: Set<String> {
        var counts: [String: Int] = [:]
        for c in library.all {
            if let f = c.format { counts[f, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value > Self.majorFormatThreshold }.keys)
    }

    /// 用于品牌 chip 渲染：主品牌按数量降序，再追加一个"其他"汇总
    private var brandChips: [BrandChipEntry] {
        var majors: [BrandChipEntry] = []
        var otherTotal = 0
        for brand in library.sortedBrands {
            let count = library.byBrand[brand]?.count ?? 0
            if count > Self.majorBrandThreshold {
                majors.append(BrandChipEntry(key: brand, displayName: brand, count: count))
            } else {
                otherTotal += count
            }
        }
        // 加上无 brand 的卡片
        let untagged = library.all.filter { $0.brand == nil }.count
        otherTotal += untagged
        if otherTotal > 0 {
            majors.append(BrandChipEntry(key: Self.otherKey, displayName: "其他", count: otherTotal))
        }
        return majors
    }

    /// ISO chip 列表：固定主 ISO 顺序 + "其他"
    private var isoChips: [BrandChipEntry] {
        guard library.isLoaded else { return [] }
        var counts: [Int: Int] = [:]
        var otherTotal = 0
        let mainSet = Set(Self.mainISOs)
        for card in library.all {
            if let iso = card.iso, mainSet.contains(iso) {
                counts[iso, default: 0] += 1
            } else {
                otherTotal += 1
            }
        }
        var entries: [BrandChipEntry] = Self.mainISOs.compactMap { iso in
            let n = counts[iso] ?? 0
            return n > 0 ? BrandChipEntry(key: String(iso), displayName: "ISO \(iso)", count: n) : nil
        }
        if otherTotal > 0 {
            entries.append(BrandChipEntry(key: Self.otherKey, displayName: "其他", count: otherTotal))
        }
        return entries
    }

    /// 用于画幅 chip 渲染：count > 阈值的画幅按数量降序，再追加"其他"
    private var formatChips: [BrandChipEntry] {
        var counts: [String: Int] = [:]
        var untagged = 0
        for card in library.all {
            if let f = card.format { counts[f, default: 0] += 1 }
            else { untagged += 1 }
        }
        let majors = counts
            .filter { $0.value > Self.majorFormatThreshold }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { BrandChipEntry(key: $0.key, displayName: $0.key, count: $0.value) }

        let majorKeys = Set(majors.map { $0.key })
        let otherTotal = counts.filter { !majorKeys.contains($0.key) }.values.reduce(0, +) + untagged
        if otherTotal > 0 {
            return majors + [BrandChipEntry(key: Self.otherKey, displayName: "其他", count: otherTotal)]
        }
        return majors
    }

    /// 仅显示主流颜色（count >= 阈值），按调色板顺序。purple/brown 等少量样本不进 UI。
    private var availableColors: [String] {
        var counts: [String: Int] = [:]
        for card in library.all {
            if let c = card.color { counts[c, default: 0] += 1 }
        }
        return CardColorPalette.order.filter { (counts[$0] ?? 0) >= Self.majorColorThreshold }
    }

    private var hasActiveFilter: Bool {
        !selectedBrands.isEmpty
            || !selectedFormats.isEmpty
            || !selectedColors.isEmpty
            || !selectedISOs.isEmpty
    }
}

/// 品牌 / 画幅 / ISO 这种"名称 + 数量徽标 + 其他"模式的 chip 数据。
struct BrandChipEntry: Hashable {
    let key: String
    let displayName: String
    let count: Int
}

// MARK: - 缩略图单元

struct FilmCardThumbnail: View {
    let card: FilmCard
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(card.product ?? "未知型号")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let iso = card.iso {
                        Text("ISO \(iso)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    if let format = card.format {
                        Text(format)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: card.id) {
            // 网格目标 ~120pt，按 3x 屏幕计算像素，最少 300px 满足缩略 API 要求
            let pixel = max(Int(120.0 * UIScreen.main.scale), 300)
            image = await FilmCardLibrary.shared.image(for: card, maxPixel: pixel)
        }
    }
}

// MARK: - 详情视图

struct FilmCardDetailView: View {
    let card: FilmCard
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                glassImageCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 14) {
                    if let brand = card.brand, !brand.isEmpty {
                        Text(brand)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                    if let product = card.product, !product.isEmpty {
                        Text(product)
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                    }

                    Divider().background(Color.white.opacity(0.08))

                    metaRow("画幅", card.format)
                    metaRow("ISO", card.iso.map { "\($0)" })
                    metaRow("冲洗工艺", card.process)
                    metaRow("张数", card.quantity)
                    metaRow("规格", card.subtype)
                    metaRow("备注", card.notes)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(card.product ?? card.brand ?? "胶片卡片")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .task {
            image = await FilmCardLibrary.shared.image(for: card, maxPixel: 1024)
        }
    }

    /// 直接在图片上裁圆角；iOS 26 在同形状上叠 `glassEffect`，更早的系统就只保留圆角
    @ViewBuilder
    private var glassImageCard: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        let roundedImage = Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white.opacity(0.05)
                    .overlay(ProgressView().tint(.white).scaleEffect(0.9))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)

        if #available(iOS 26.0, *) {
            roundedImage.glassEffect(.regular, in: shape)
        } else {
            roundedImage
        }
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 76, alignment: .leading)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 筛选 Sheet

struct FilmCardFilterSheet: View {
    let brandChips: [BrandChipEntry]
    let formatChips: [BrandChipEntry]
    let availableColors: [String]
    let isoChips: [BrandChipEntry]
    @Binding var selectedBrands: Set<String>
    @Binding var selectedFormats: Set<String>
    @Binding var selectedColors: Set<String>
    @Binding var selectedISOs: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    countedChipSection(title: "品牌", chips: brandChips, selection: $selectedBrands)
                    countedChipSection(title: "画幅", chips: formatChips, selection: $selectedFormats)
                    colorSection
                    countedChipSection(title: "ISO", chips: isoChips, selection: $selectedISOs)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("重置", action: reset)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }

    /// 统一渲染品牌 / 画幅 / ISO 这种"名称 + 数量徽标"的 chip 组
    @ViewBuilder
    private func countedChipSection(title: String, chips: [BrandChipEntry], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(chips, id: \.key) { entry in
                    let isOn = selection.wrappedValue.contains(entry.key)
                    Button {
                        if isOn { selection.wrappedValue.remove(entry.key) }
                        else { selection.wrappedValue.insert(entry.key) }
                    } label: {
                        BrandCountChipLabel(brand: entry.displayName, count: entry.count, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel("\(entry.displayName)，\(entry.count) 张")
                }
            }
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("颜色")
                .font(.headline)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(availableColors, id: \.self) { key in
                    let isOn = selectedColors.contains(key)
                    Button {
                        if isOn { selectedColors.remove(key) }
                        else { selectedColors.insert(key) }
                    } label: {
                        ColorSwatchChip(colorKey: key, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel(CardColorPalette.chineseName(key))
                }
            }
        }
    }

    private func reset() {
        selectedBrands = []
        selectedFormats = []
        selectedColors = []
        selectedISOs = []
    }
}

// MARK: - Chip 视觉元件

/// 品牌 chip：名称 + 数量徽标
struct BrandCountChipLabel: View {
    let brand: String
    let count: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(brand)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(selected
                                   ? Color.white.opacity(0.25)
                                   : Color.secondary.opacity(0.18))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected
                           ? Color.accentColor
                           : Color.secondary.opacity(0.15))
        )
        .foregroundColor(selected ? .white : .primary)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 颜色 chip：仅色块，无文字。选中态用粗白圈+轻微放大表示。
struct ColorSwatchChip: View {
    let colorKey: String
    let selected: Bool

    var body: some View {
        Circle()
            .fill(CardColorPalette.swatch(colorKey))
            .frame(width: 32, height: 32)
            .overlay(
                Circle().stroke(
                    selected ? Color.white : Color.white.opacity(0.18),
                    lineWidth: selected ? 2.5 : 0.5
                )
            )
            .scaleEffect(selected ? 1.08 : 1.0)
            .animation(.spring(duration: 0.18), value: selected)
            .padding(2) // 扩大点击热区
    }
}

// MARK: - 通用 Chip 流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            // Wrap only if we're not at the start of a row — otherwise let an
            // oversized item overflow on its own row, matching placeSubviews.
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: proposal.width ?? x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
