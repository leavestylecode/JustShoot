import SwiftUI
import UIKit

// MARK: - 底部缩略图 scrubber
//
// 设计要点（之前的实现踩过的坑都在这里说明）：
//
// 1) **Selection 来源 = `currentIndex`，不是 `scrollPosition.viewID()`**。
//    旧实现把 cell 的 isSelected 绑到 viewID()——程序化 `scrollTo` 后 viewID() 不一定同步刷新，
//    首次 onAppear 没有任何 cell 显示选中态，"当前 cell"既不放大也无白边，视觉上"不在中心"。
//
// 2) **Tap 直接改 `currentIndex`，不要先 `scrollTo` 再等 commit**。
//    旧实现：tap → scrollTo（程序化）→ 期待 `.idle` phase 触发 `commitFromScroll` 写回
//    currentIndex。但程序化滚动后 viewID() 立即就是目标 id，commitFromScroll 里
//    `idx != currentIndex` 判定不成立——currentIndex **永远不动**，主图不切换。新实现：tap
//    直接 `currentIndex = index`，外层的 `.onChange` 自然把 scrubber 滚到位，TabView 跟着翻页。
//
// 3) **用户手动 scrub 时仅在 `.interacting` → `.idle` 路径上 commit**。
//    程序化 scrollTo 走 `idle → animating → idle`，不经过 interacting；用户手指 drag 走
//    `idle → tracking → interacting → (decelerating) → idle`。用 `userIsScrolling` 标记区
//    分两条路径，杜绝 TabView↔Scrubber 互相覆盖的反馈环（旧实现里 `.idle` 无差别 commit，
//    程序化滚动结束也回写 currentIndex，跟 TabView 滑动产生抢占式覆盖）。
//
// 4) **cell 选中态用 `scaleEffect`，不改 frame size**。
//    旧实现 frame 在 40 ↔ 50 之间切换，LazyHStack 每帧重排 → 滚动位置漂移 → centeredID 又变
//    → 反复抖动。scaleEffect 是渲染层变换，不影响布局，cell 在 strip 里的中心永远在固定栅格上。
struct PhotoScrubber: View {
    let photos: [Photo]
    /// 与 PhotoDetailView 同源——`UUID?` 而不是 `UUID`：上游 `.scrollPosition(id:)` 会在视口暂时
    /// 找不到任何 item 时把 binding 写成 nil（极少出现，但类型协议里允许）。比较点 `photo.id == currentPhotoID`
    /// 仍按 Optional 的 Equatable lift 规则正常工作。
    @Binding var currentPhotoID: UUID?

    /// 首次 layout 完成后才允许 scrollTo——padding 依赖 geo.size.width，width=0 那一帧
    /// 滚到的位置是错的。latch 一次性置位，避免后续 size 微调反复滚。
    @State private var didInitialScroll = false

    private static let itemSize: CGFloat = 40
    private static let spacing: CGFloat = 6
    /// 选中态视觉放大比例：40 × 1.25 = 50（与旧实现的 selectedSize 视觉一致）。
    /// 用 scaleEffect 实现——不影响 LazyHStack 的布局栅格。
    private static let selectedScale: CGFloat = 1.25

    var body: some View {
        GeometryReader { geo in
            // ScrollViewReader 比 ScrollPosition 更适合这里：
            // proxy.scrollTo(id:anchor: .center) 的 anchor 语义干净——target 中心对齐 viewport
            // 中心，独立于 scrollTargetBehavior 之类的 modifier。
            // 旧实现叠了 .scrollTargetBehavior(.viewAligned) + .scrollPosition($pos, anchor: .center)
            // + scrollPosition.scrollTo(anchor: .center)，三条互相打架——viewAligned 默认按 cell
            // 边缘对齐 viewport 边缘，再加上 scrollPosition 的 binding 写回，最终 cell 被 re-snap
            // 到 viewport trailing edge（**用户感知就是"选中的图片一直在最右边"**）。
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: Self.spacing) {
                        ForEach(photos) { photo in
                            ThumbnailStripCell(
                                photo: photo,
                                isSelected: photo.id == currentPhotoID,
                                selectedScale: Self.selectedScale
                            )
                            .id(photo.id)
                            .onTapGesture { handleTap(photo: photo) }
                        }
                    }
                    // 留白让首/末 cell 也能被 anchor: .center 滚到正中央。
                    // 用 itemSize（布局尺寸），不是放大后的视觉尺寸——padding 跟 layout 走。
                    .padding(.horizontal, max(0, (geo.size.width - Self.itemSize) / 2))
                }
                // initial: true 让 onChange 在 onAppear 那一帧也跑；guard `w > 0` 拦掉布局
                // 未就绪的早期触发；didInitialScroll latch 防止后续 size 微调重复滚动。
                .onChange(of: geo.size.width, initial: true) { _, w in
                    guard !didInitialScroll, w > 0, let id = currentPhotoID else { return }
                    didInitialScroll = true
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: currentPhotoID) { _, newID in
                    // 曲线 .smooth(0.32) 接近外层 ScrollView `.scrollTargetBehavior(.paging)` 的 settle
                    // 时长（≈0.3s spring）。旧 easeOut 时长接近但 in/out 节奏不一致，快速连翻时 scrubber
                    // 明显落后于主图；.smooth 在中段加速，与主图 paging settle 同步更好。
                    guard let newID else { return }
                    withAnimation(.smooth(duration: 0.32)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        // 给 scaleEffect 留垂直空间：itemSize × selectedScale + 一点边距。
        .frame(height: Self.itemSize * Self.selectedScale + 6)
    }

    /// 远距离跳转（|Δ|>1）禁用外层 ScrollView 的逐帧 fly-by 动画——用 `Transaction.disablesAnimations`
    /// 强制瞬切。否则从第 1 张点跳到第 20 张，paging ScrollView 会逐帧滑过中间所有页面，慢且会触发
    /// 中间所有 PagerImage 的短暂挂载/卸载，浪费 NSCache 命中。近邻（|Δ|=1）保留动画感。
    private func handleTap(photo: Photo) {
        UISelectionFeedbackGenerator().selectionChanged()
        guard photo.id != currentPhotoID else { return }
        let currentIdx = photos.firstIndex(where: { $0.id == currentPhotoID }) ?? 0
        let newIdx = photos.firstIndex(where: { $0.id == photo.id }) ?? 0
        let distance = abs(newIdx - currentIdx)

        if distance > 1 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentPhotoID = photo.id
            }
        } else {
            withAnimation(.smooth(duration: 0.32)) {
                currentPhotoID = photo.id
            }
        }
    }
}

// MARK: - 缩略图 cell
//
// 选中态用 `scaleEffect` 放大（不影响布局栅格），并加白边、提亮 opacity。
// **关键**：旧实现切换 frame size，LazyHStack 重排，跟外层 ScrollPosition 互相干扰，
// 滑动时整条 strip 抖动；改成 scaleEffect 后布局完全静止，只有渲染层做仿射变换。
//
// 缩略图统一按 600px 解码（与 PhotoDetailView.placeholderMaxPixel 对齐）——scrubber 与详
// 情页占位共享同一份 NSCache 命中，PhotoDetailView.schedulePreheat 预热完后，scrubber 滚到哪
// 都瞬间有图。
private struct ThumbnailStripCell: View {
    let photo: Photo
    let isSelected: Bool
    let selectedScale: CGFloat
    @State private var thumb: UIImage?

    private static let itemSize: CGFloat = 40
    /// 与 PhotoDetailView.placeholderMaxPixel 同值——共享 NSCache 命中
    private static let loadMaxPixel = 600

    var body: some View {
        Group {
            if let image = thumb {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.1))
            }
        }
        .frame(width: Self.itemSize, height: Self.itemSize)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? .white : .clear, lineWidth: 2)
        )
        .opacity(isSelected ? 1.0 : 0.5)
        .scaleEffect(isSelected ? selectedScale : 1.0)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .task {
            if thumb == nil {
                thumb = await ImageLoader.shared.loadThumbnail(for: photo, maxPixel: Self.loadMaxPixel)
            }
        }
    }
}
