import SwiftUI

// MARK: - 照片信息面板
struct PhotoInfoPanel: View {
    let photo: Photo
    let getImageDimensions: (Data) -> (width: Int, height: Int)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.yellow)
                    Text(photo.timestamp, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 14))
                    Spacer()
                }

                Divider()

                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.yellow)
                    Text(photo.filmDisplayName)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ExifInfoCard(icon: "camera.aperture", title: "Aperture", value: photo.aperture)
                    ExifInfoCard(icon: "timer", title: "Shutter", value: photo.shutterSpeed)
                    ExifInfoCard(icon: "speedometer", title: "ISO", value: photo.iso)
                    ExifInfoCard(icon: "scope", title: "Focal length", value: photo.focalLength)
                    ExifInfoCard(icon: "bolt.fill", title: "Flash", value: photo.flashMode)
                    if let dims = getImageDimensions(photo.imageData) {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: "\(dims.width)×\(dims.height)")
                    } else {
                        ExifInfoCard(icon: "aspectratio", title: "Size", value: String(localized: "Unknown"))
                    }
                }

                if let lat = photo.latitude, let lon = photo.longitude {
                    Divider()
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundColor(.yellow)
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

                if let device = photo.deviceInfo {
                    Divider()
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundColor(.yellow)
                        Text("\(device.make) \(device.model)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - EXIF 信息卡片
struct ExifInfoCard: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.yellow.opacity(0.8))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
