import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UIKit
import CoreLocation
import os

// MARK: - 照片信息面板
struct PhotoInfoPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let photo: Photo
    /// 离主线程解析后填入；初始 .empty 让首帧显示占位（"Unknown"），解析完成再刷新。
    /// 关键：解析（CGImageSource + 元数据 copy）从前述 body 内的 @MainActor 同步路径挪到 .task
    /// 的 detached 子任务，info 面板首次展开不再卡主线程 fault + 解析整张 22MP HEIF。
    @State private var exif: ParsedExifInfo = .empty
    @State private var filename: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(photo.timestamp, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: 14))
                        if let filename {
                            Text(verbatim: filename)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    Image(systemName: "film")
                        .foregroundStyle(.tint)
                    Text(photo.filmDisplayName)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ExifInfoCard(icon: "camera.aperture", title: "Aperture", value: exif.aperture)
                    ExifInfoCard(icon: "timer", title: "Shutter", value: exif.shutterSpeed)
                    ExifInfoCard(icon: "speedometer", title: "ISO", value: exif.iso)
                    ExifInfoCard(icon: "scope", title: "Focal length", value: exif.focalLength)
                    ExifInfoCard(icon: "bolt.fill", title: "Flash", value: exif.flashMode)
                    if let w = exif.pixelWidth, let h = exif.pixelHeight {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: "\(w)×\(h)")
                    } else {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: String(localized: "Unknown"))
                    }
                }

                if let lat = photo.latitude, let lon = photo.longitude {
                    Divider()
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.6f, %.6f", lat, lon))
                                .font(.system(size: 13, design: .monospaced))
                            if let alt = photo.altitude {
                                Text("Altitude \(String(format: "%.1f", alt))m")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                if let device = exif.deviceInfo {
                    Divider()
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(.tint)
                        Text("\(device.make) \(device.model)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
        }
        .appPageBackground(showsGradient: false)
        .tint(colorScheme == .dark ? .yellow : .primary)
        .task(id: PhotoFileReference(photo)) {
            let file = PhotoFileReference(photo)
            exif = .empty
            filename = nil
            if file.assetID != nil {
                let name = await Task.detached(priority: .userInitiated) { file.filename() }.value
                guard !Task.isCancelled else { return }
                filename = name
            }
            let data = await PhotoImage.exifData(for: photo)
            guard !Task.isCancelled else { return }
            let (info, localName) = await Task.detached(priority: .userInitiated) {
                let info = data.map(ParsedExifInfo.parse) ?? .empty
                let name = file.assetID == nil ? file.filename(localExtension: info.fileFormat) : nil
                return (info, name)
            }.value
            guard !Task.isCancelled else { return }
            exif = info
            if let localName { filename = localName }
        }
    }
}

// MARK: - EXIF 信息卡片
private struct ExifInfoCard: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
