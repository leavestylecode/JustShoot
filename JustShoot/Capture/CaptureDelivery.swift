import Foundation
import CoreMedia

/// 一次拍照的完整产出，跨 actor 边界传给 CameraView 的后处理。非 live 时只有 imageData，
/// 其余为 nil/invalid。live 时还带配对视频文件 URL + content identifier + still-image-time，
/// 供 LivePhotoProcessor 套 LUT 并重写配对元数据后存为 Live Photo。
struct CaptureResult: Sendable {
    let imageData: Data
    let livePhotoMovieURL: URL?
    let photoDisplayTime: CMTime
    let warning: CaptureWarning?
    let deferredPhoto: DeferredPhotoState?

    init(imageData: Data, livePhotoMovieURL: URL?, photoDisplayTime: CMTime, requestedLive: Bool = false,
         deferredPhoto: DeferredPhotoState? = nil) {
        self.imageData = imageData
        self.livePhotoMovieURL = livePhotoMovieURL
        self.photoDisplayTime = photoDisplayTime
        warning = requestedLive && livePhotoMovieURL == nil ? .livePhotoMovieUnavailable : nil
        self.deferredPhoto = deferredPhoto
    }
}

enum CaptureWarning: Equatable, Sendable {
    case livePhotoMovieUnavailable

    var message: String {
        switch self {
        case .livePhotoMovieUnavailable:
            String(localized: "The still photo will be saved, but its Live Photo video could not be captured.")
        }
    }
}

struct CaptureStill: Sendable {
    let imageData: Data
    let pendingLivePhotoMovieURL: URL?
    var deferredPhoto: DeferredPhotoState? = nil
}
