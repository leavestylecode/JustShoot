import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - 一键分享到其他 app
//
// 把照片的**全分辨率原始字节**（含 EXIF/GPS 元数据）写到临时文件，用文件 URL 喂给系统
// UIActivityViewController——走文件 URL 而不是 UIImage：保留完整元数据、正确扩展名 / UTI，
// AirDrop / 存储到「文件」/ 微信 / 邮件等都拿到原图质量（UIImage 路径会被重新编码、丢元数据、
// 退化成低质 JPEG）。
//
// 取字节走 PhotoImage.exifData —— 资产照片从系统相册取原始 data（PHImageManager
// requestImageDataAndOrientation），遗留内部照片读 blob。Live Photo 目前按静图分享：跨 app
// 普遍不消费动图资源、且需打包双资源，从简只分享主图。
//
// **作为「照片」分享，而不是「文件」——用 UIActivityItemSource 声明 public.jpeg**。两版弯路：
//   1. NSItemProvider(contentsOf:)：会注册 [public.jpeg, public.file-url, public.url] 三个类型。
//      微信分享扩展的激活规则是字典式的「图片 ≤9 张、文件 ≤1 个」——带 public.file-url 的 item
//      被计入「文件」桶，单张（1 个文件 ≤1）能过、**多张（N 个文件 >1）微信从面板消失**。
//   2. 裸 NSItemProvider + registerFileRepresentation(for: .jpeg)：类型对了（只剩 public.jpeg），
//      但 UIActivityViewController 官方支持的 activityItems 只有具体对象（String/UIImage/URL/Data）
//      和 UIActivityItemSource——lazy 注册的裸 provider 面板能弹出、**真机上跨进程交付为空**
//      （进程内 loadFileRepresentation 正常，是 activity 消费链路不认这种条目）。
// 终解 = SharePhotoItem（UIActivityItemSource）：dataTypeIdentifierForActivityType 声明
// public.jpeg（share extension 激活规则看到的 UTI，微信据此计入「图片」桶），itemForActivityType
// 按目标返回内容——AirDrop/存储到文件给文件 URL（保留可读文件名），其余给 mappedIfSafe 的文件
// Data（零常驻内存）。注意：一次选 >9 张时微信仍不出现——微信自己的硬上限，无解。
//
// **统一转成高质量 JPEG 分享（兼容性优先）**：原图是 HEIC，微信等接收方只稳定支持 JPEG/PNG。
// 转码 q=0.95、**保留 EXIF/GPS/朝向**，对所有 app 通吃；体积略大、画质几乎无损——分享场景可接受
// （接收方多数还会再压一遍）。原图归档质量不受影响（系统相册里仍是原始 HEIC，这里只动「分享出去
// 的副本」）。
//
// 呈现方式 = 直接从最顶层 VC present，而不是包进 SwiftUI .sheet：UIActivityViewController 包进
// .sheet 会变成「sheet 里再套一个分享面板」的双层叠床，体验割裂；直接 present 才是系统原生的
// 底部分享面板。

// MARK: - 导出临时文件

enum PhotoShareExporter {
    /// 导出一组照片为临时文件 URL（全分辨率原图字节）。失败的单张跳过，不阻断其余。
    @MainActor
    static func export(_ photos: [Photo]) async -> [URL] {
        let dir = cleanShareDirectory()
        var urls: [URL] = []
        for photo in photos where !photo.isDeleted {
            if let url = await exportFile(photo, into: dir) { urls.append(url) }
        }
        return urls
    }

    /// 导出单张照片为临时 JPEG 文件 URL（全分辨率，保留 EXIF/GPS/朝向）。失败返回 nil。
    @MainActor
    static func export(_ photo: Photo) async -> URL? {
        await exportFile(photo, into: cleanShareDirectory())
    }

    /// Share 临时目录，每轮导出前整体清掉重建——上一轮分享面板早已关闭、文件已被接收方拷走，
    /// 不清的话 48MP JPEG 会在 tmp 里无限累积。
    private static func cleanShareDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private static func exportFile(_ photo: Photo, into dir: URL) async -> URL? {
        guard let data = await PhotoImage.exifData(for: photo) else {
            Log.gallery.error("share_export_no_data id=\(photo.id.uuidString, privacy: .public)")
            return nil
        }
        // 转码到主线程外——48MP HEIC→JPEG 重编码有 CPU 成本，不阻塞 UI。
        let transcoded = await Task.detached(priority: .userInitiated) {
            jpegData(from: data)
        }.value
        guard let jpeg = transcoded else {
            Log.gallery.error("share_export_transcode_failed id=\(photo.id.uuidString, privacy: .public)")
            return nil
        }
        // 文件名带日期前缀，分享出去的图在对方设备上更可读（不是一串 UUID）。
        let stamp = photo.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let url = dir.appendingPathComponent("JustShoot-\(stamp)-\(photo.id.uuidString.prefix(8)).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return url
        } catch {
            Log.gallery.error("share_export_write_failed id=\(photo.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 把原图字节（HEIC/JPEG）转码成 JPEG，**保留全部元数据**（EXIF/TIFF/GPS/朝向经 source props 拷贝）。
    /// ⚠️ 必须显式设 lossy quality——CGImageDestinationAddImageFromSource 跨类型会按目标默认质量重编码，
    /// 不设质量会被压成几百 KB（与 FilmProcessor 里同一坑，见该文件 2026-06-06 注释）。
    nonisolated private static func jpegData(from data: Data, quality: CGFloat = 0.95) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1,
                                                          [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        else { return nil }
        // 单图属性同样带上 quality——destination 选项 + 单图属性双保险，确保高质量重编码。
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - 分享条目（UIActivityItemSource）

/// 单张照片的分享条目——UIActivityViewController 自定义条目的**官方契约**（裸 NSItemProvider
/// 不受支持，真机交付为空，见文件头注释）。
///   - placeholder = UIImage()：让系统按「图片」推断可用活动，零解码成本
///   - dataTypeIdentifier = public.jpeg：share extension 激活规则看到的 UTI——微信据此把条目
///     计入「图片」桶（≤9 张），不是「文件」桶（≤1 个）
///   - item：AirDrop / 存储到文件给 URL（接收方期待文件、保留可读文件名）；其余给 mappedIfSafe
///     的文件 Data（页按需换入，多张大图不顶高水位；字节即文件原文，EXIF/GPS 原样保留）
final class SharePhotoItem: NSObject, UIActivityItemSource {
    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        UIImage()
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if activityType == .airDrop || activityType?.rawValue == "com.apple.DocumentManagerUICore.SaveToFiles" {
            return fileURL
        }
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.jpeg.identifier
    }
}

// MARK: - 呈现系统分享面板

@MainActor
enum SharePresenter {
    /// 从最顶层已呈现的 VC present 系统分享面板。入参是 PhotoShareExporter 导出的图片临时文件 URL；
    /// 每个 URL 包成 SharePhotoItem（UIActivityItemSource），让接收方当**照片**而非文件处理。
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty, let top = topViewController() else { return }
        let items = urls.map { SharePhotoItem(fileURL: $0) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad / 弹出场景需要锚点（本 app 锁竖屏 iPhone，但 popover 控制器存在时不设会崩）。
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }

    /// 当前前台 window 场景里最顶层的 VC（穿透所有已 present 的层，含 fullScreenCover / sheet）。
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
