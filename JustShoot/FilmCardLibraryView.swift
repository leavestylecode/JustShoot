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
                Text("浏览 629 款胶片包装")
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
    @State private var selectedBrands: Set<String> = []
    @State private var selectedFormats: Set<String> = []
    @State private var selectedColors: Set<String> = []
    @State private var minISO: Int = 0
    @State private var maxISO: Int = 3200
    @State private var showFilterSheet = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

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
                    Image(systemName: hasActiveFilter
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel(hasActiveFilter ? "筛选（已启用）" : "筛选")
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilmCardFilterSheet(
                brandsByCount: brandsByCount,
                availableFormats: availableFormats,
                availableColors: availableColors,
                selectedBrands: $selectedBrands,
                selectedFormats: $selectedFormats,
                selectedColors: $selectedColors,
                minISO: $minISO,
                maxISO: $maxISO
            )
            .presentationDetents([.medium, .large])
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
                    Label("没有匹配", systemImage: "line.3.horizontal.decrease.circle")
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
        let isoLo = minISO
        let isoHi = maxISO
        let isoFiltered = isoLo > 0 || isoHi < 3200

        return library.all.filter { card in
            if !brands.isEmpty {
                guard let b = card.brand, brands.contains(b) else { return false }
            }
            if !formats.isEmpty {
                guard let f = card.format, formats.contains(f) else { return false }
            }
            if !colors.isEmpty {
                guard let c = card.color, colors.contains(c) else { return false }
            }
            if isoFiltered {
                guard let iso = card.iso, iso >= isoLo, iso <= isoHi else { return false }
            }
            return true
        }
    }

    /// (品牌, 数量) 按数量降序，同数量按字母升序
    private var brandsByCount: [(brand: String, count: Int)] {
        library.sortedBrands.compactMap { brand in
            guard let cards = library.byBrand[brand] else { return nil }
            return (brand, cards.count)
        }
    }

    private var availableFormats: [String] {
        Array(Set(library.all.compactMap { $0.format })).sorted()
    }

    /// 仅显示实际出现过的颜色，按调色板顺序
    private var availableColors: [String] {
        let present = Set(library.all.compactMap { $0.color })
        return CardColorPalette.order.filter { present.contains($0) }
    }

    private var hasActiveFilter: Bool {
        !selectedBrands.isEmpty
            || !selectedFormats.isEmpty
            || !selectedColors.isEmpty
            || minISO > 0
            || maxISO < 3200
    }
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
    let brandsByCount: [(brand: String, count: Int)]
    let availableFormats: [String]
    let availableColors: [String]
    @Binding var selectedBrands: Set<String>
    @Binding var selectedFormats: Set<String>
    @Binding var selectedColors: Set<String>
    @Binding var minISO: Int
    @Binding var maxISO: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    brandSection
                    chipSection(title: "画幅", items: availableFormats, selected: $selectedFormats)
                    colorSection
                    isoSection
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

    @ViewBuilder
    private var brandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("品牌")
                .font(.headline)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(brandsByCount, id: \.brand) { entry in
                    let isOn = selectedBrands.contains(entry.brand)
                    Button {
                        if isOn { selectedBrands.remove(entry.brand) }
                        else { selectedBrands.insert(entry.brand) }
                    } label: {
                        BrandCountChipLabel(brand: entry.brand, count: entry.count, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel("\(entry.brand)，\(entry.count) 张")
                }
            }
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("颜色")
                .font(.headline)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(availableColors, id: \.self) { key in
                    let isOn = selectedColors.contains(key)
                    Button {
                        if isOn { selectedColors.remove(key) }
                        else { selectedColors.insert(key) }
                    } label: {
                        ColorChipLabel(colorKey: key, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel(CardColorPalette.chineseName(key))
                }
            }
        }
    }

    @ViewBuilder
    private func chipSection(title: String, items: [String], selected: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ChipFlow(items: items, selected: selected)
        }
    }

    @ViewBuilder
    private var isoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ISO 范围")
                    .font(.headline)
                Spacer()
                Text("\(minISO) – \(maxISO)")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Text("最低").font(.caption).foregroundColor(.secondary).frame(width: 32, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(minISO) },
                        set: { minISO = min(Int($0), maxISO) }
                    ),
                    in: 0...3200,
                    step: 25
                )
            }
            HStack(spacing: 8) {
                Text("最高").font(.caption).foregroundColor(.secondary).frame(width: 32, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(maxISO) },
                        set: { maxISO = max(Int($0), minISO) }
                    ),
                    in: 0...3200,
                    step: 25
                )
            }
        }
    }

    private func reset() {
        selectedBrands = []
        selectedFormats = []
        selectedColors = []
        minISO = 0
        maxISO = 3200
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
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
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
    }
}

/// 颜色 chip：色块 + 名称
struct ColorChipLabel: View {
    let colorKey: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(CardColorPalette.swatch(colorKey))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            Text(CardColorPalette.chineseName(colorKey))
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected
                           ? Color.accentColor
                           : Color.secondary.opacity(0.15))
        )
        .foregroundColor(selected ? .white : .primary)
    }
}

// MARK: - 通用 Chip 流式布局

struct ChipFlow: View {
    let items: [String]
    @Binding var selected: Set<String>

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    if selected.contains(item) { selected.remove(item) }
                    else { selected.insert(item) }
                } label: {
                    Text(item)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selected.contains(item)
                                           ? Color.accentColor
                                           : Color.secondary.opacity(0.15))
                        )
                        .foregroundColor(selected.contains(item) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(item) ? .isSelected : [])
            }
        }
    }
}

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
