import Foundation
import SwiftData

@Model
final class Photo: Identifiable {
    var id: UUID
    var timestamp: Date
    /// 系统相册 PHAsset 的本地标识符——**真相源**。迁移完成后所有照片都有值；仅在「拍摄时相册
    /// 写入失败、字节兜底暂存待迁移」或「旧版本遗留尚未迁移」时为 nil。
    var assetLocalIdentifier: String?
    /// 遗留 / 兜底内部字节：新架构默认 nil（真相源在系统相册）。仅当相册写入失败兜底暂存、或旧
    /// 版本数据尚未迁移时有值；迁入相册后置 nil 以释放 externalStorage。
    @Attribute(.externalStorage) var imageData: Data?
    var filmPresetName: String?
    var filmDisplayLabel: String?
    var captureCurveData: Data?
    /// 是否为 Live Photo（拍摄时套了 LUT 的静态图 + 配对视频）。拍摄写入，画廊角标 / 详情页是否启用
    /// PHLivePhotoView 播放都读它——避免每个 cell 异步查 PHAsset.mediaSubtypes。旧照片默认 false。
    var isLivePhoto: Bool = false
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var locationTimestamp: Date?

    /// EXIF 解析缓存（Transient：不持久化，按需解析一次）
    @Transient private var _parsedExif: ParsedExifInfo?

    init(assetLocalIdentifier: String?, imageData: Data?, filmPresetName: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.assetLocalIdentifier = assetLocalIdentifier
        self.imageData = imageData
        self.filmPresetName = filmPresetName
    }

    /// 一次性解析并缓存所有 EXIF 信息。仅对遗留内部字节有效；资产照片的 EXIF 由
    /// `PhotoImage.exifData` 异步从相册取数据后解析（见 PhotoInfoPanel）。
    var parsedExif: ParsedExifInfo {
        if let cached = _parsedExif { return cached }
        guard let data = imageData else { return .empty }
        let info = ParsedExifInfo.parse(from: data)
        _parsedExif = info
        return info
    }

    // MARK: - 便捷属性（全部从缓存读取，不再重复解析）
    var iso: String { parsedExif.iso }
    var shutterSpeed: String { parsedExif.shutterSpeed }
    var aperture: String { parsedExif.aperture }
    var focalLength: String { parsedExif.focalLength }
    var exposureMode: String { parsedExif.exposureMode }
    var flashMode: String { parsedExif.flashMode }
    var gpsInfo: (latitude: String, longitude: String, altitude: String)? { parsedExif.gpsInfo }
    var deviceInfo: (make: String, model: String, software: String)? { parsedExif.deviceInfo }
    var lensInfo: String { parsedExif.lensInfo }
}

// Lets the `KeyPath<Photo, String?>` captured by the `#Predicate` macro
// expansion satisfy Swift 6 strict-concurrency's Sendable requirement on
// captures. The standard library does not declare `AnyKeyPath: Sendable`,
// but property KeyPaths are immutable values. The conformance here covers
// every KeyPath subclass (KeyPath / WritableKeyPath / ReferenceWritableKeyPath
// all inherit from AnyKeyPath).
extension AnyKeyPath: @retroactive @unchecked Sendable {}
