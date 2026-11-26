import SwiftUI

struct PhotoInfoPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let photo: Photo
    @State private var exif: ParsedExifInfo?
    @State private var captureLook: PhotoFilmLook?
    @State private var editedLook: PhotoFilmLook?
    @State private var filename: String?
    @State private var byteCount: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileHeader

                if let exif {
                    cameraDetails(exif)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }

                if let editedLook {
                    PhotoLookCard(look: editedLook.displayed(over: captureLook),
                                  showsNoLUT: editedLook.filmID == nil && captureLook == nil)
                    if let captureLook, captureLook.hasRecord {
                        DisclosureGroup("As Shot") {
                            PhotoLookCard(look: captureLook).padding(.top, 8)
                        }
                        .font(.subheadline)
                        .tint(.secondary)
                    }
                } else if let captureLook, captureLook.hasRecord {
                    PhotoLookCard(look: captureLook)
                }

                if let lat = photo.latitude, let lon = photo.longitude {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: String(format: "%.6f°, %.6f°", lat, lon))
                            if let alt = photo.altitude {
                                Text("Altitude \(String(format: "%.1f", alt))m")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: "location") }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .appPageBackground(showsGradient: false)
        .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityAction(.escape) { dismiss() }
        .task(id: PhotoFileReference(photo)) {
            let file = PhotoFileReference(photo)
            let asShot = PhotoFilmLook(filmID: photo.filmPresetName, filmName: photo.filmDisplayLabel,
                                       curve: photo.captureCurveData.flatMap { try? JSONDecoder().decode(PhotoEditCurve.self, from: $0) })
            captureLook = nil
            editedLook = nil
            exif = nil
            filename = nil
            byteCount = nil
            let assetID = file.assetID
            if asShot.hasRecord || assetID == nil { captureLook = asShot }
            if assetID != nil {
                let name = await Task.detached(priority: .userInitiated) { file.filename() }.value
                guard !Task.isCancelled else { return }
                filename = name
            }
            if let assetID, let info = try? await PhotoLibrary.currentFileInfo(id: assetID) {
                guard !Task.isCancelled else { return }
                byteCount = info.bytes
                exif = info.exif
                let looks = info.adjustment?.looks(asShot: asShot) ?? (asShot, nil)
                captureLook = looks.0
                editedLook = looks.1
            } else {
                guard !Task.isCancelled else { return }
                captureLook = asShot
                let data = await PhotoImage.exifData(for: photo)
                let (info, localName) = await Task.detached(priority: .userInitiated) {
                    let info = data.map(ParsedExifInfo.parse) ?? .empty
                    let name = file.assetID == nil ? file.filename(localExtension: info.fileFormat) : nil
                    return (info, name)
                }.value
                guard !Task.isCancelled else { return }
                byteCount = data.map { Int64($0.count) }
                exif = info
                if let localName { filename = localName }
            }
        }
    }

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(photo.timestamp, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let filename {
                Text(verbatim: filename)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func resolution(_ info: ParsedExifInfo) -> String? {
        guard let width = info.pixelWidth, let height = info.pixelHeight else { return nil }
        let megapixels = (Double(width) * Double(height) / 1e6).formatted(.number.precision(.fractionLength(0...1)))
        return "\(megapixels) MP  ·  \(width) × \(height)"
    }

    @ViewBuilder private func cameraDetails(_ info: ParsedExifInfo) -> some View {
        let unknown = String(localized: "Unknown")
        let camera = info.deviceInfo.map { device in
            let model = device.model == unknown ? "" : device.model
            let make = device.make == unknown || model.localizedCaseInsensitiveContains(device.make) ? "" : device.make
            return [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        } ?? ""
        let lens = info.lensModel ?? ""
        let dimensions = resolution(info)
        let fileSize = byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let settings = [info.iso, info.focalLength, info.exposureBias, info.aperture, info.shutterSpeed]
            .compactMap { $0 }.filter { $0 != unknown }
        let hasFlash = info.flashMode != unknown
        // With sparse EXIF, use the next available fact alongside the file format.
        let heading = [camera, lens].first { !$0.isEmpty }
        let headerText = heading ?? dimensions ?? ""
        let bodyDimensions = heading == nil ? nil : dimensions
        let showsLens = !camera.isEmpty && !lens.isEmpty
        let showsFileDetails = bodyDimensions != nil || fileSize != nil
        let hasHeader = !headerText.isEmpty || info.fileFormat != nil
        let hasBody = showsLens || showsFileDetails || !settings.isEmpty || hasFlash
        if hasHeader || hasBody {
            VStack(alignment: .leading, spacing: 0) {
                if hasHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: headerText).font(.body)
                        Spacer(minLength: 0)
                        if let format = info.fileFormat {
                            Text(verbatim: format == "JPG" ? "JPEG" : format)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color(uiColor: .systemFill), in: .rect(cornerRadius: 5))
                                .fixedSize()
                        }
                    }
                    .padding(16)
                }
                if hasHeader && hasBody { Divider() }
                if hasBody {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsLens { Text(verbatim: lens).font(.subheadline) }
                        if showsFileDetails {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let bodyDimensions { Text(verbatim: bodyDimensions) }
                                Spacer(minLength: 0)
                                if let fileSize { Text(verbatim: fileSize).multilineTextAlignment(.trailing) }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        if (showsLens || showsFileDetails) && !settings.isEmpty { Divider() }
                        if !settings.isEmpty { exposureRow(settings) }
                        if hasFlash { Text(verbatim: info.flashMode).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.10)) }
        }
    }

    private func exposureRow(_ values: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 8) }
                    Text(verbatim: values[index]).fixedSize()
                }
            }
            Text(verbatim: values.joined(separator: "  ·  "))
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}
