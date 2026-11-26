import SwiftData
import SwiftUI

struct PhotoLookCard: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @State private var catalogName: String?
    @State private var graph: CurvePreviewData?
    let look: PhotoFilmLook
    var showsNoLUT = false
    private static let previewSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lookRow("Film LUT", name: filmName, intensity: look.filmID == nil ? nil : look.intensity) {
                filmCover
            }
            Divider()
            lookRow("Tone Curve", name: look.curve?.label ?? String(localized: "Not recorded")) {
                if let graph {
                    CurveGraphView(data: graph, accent: .primary, showsGrid: true)
                        .padding(4)
                } else if look.curve == nil {
                    Image(systemName: "minus").foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.10)) }
        .task(id: look.curve) {
            graph = nil
            guard let curve = look.curve else { return }
            let data = await Task.detached(priority: .userInitiated) { curve.resolved.previewData }.value
            if !Task.isCancelled { graph = data }
        }
        .task(id: look.customID) {
            catalogName = nil
            // Older edits stored only a custom LUT UUID. New edits freeze its display name.
            guard look.filmName == nil, let id = look.customID else { return }
            let container = modelContext.container
            let name = await Task.detached(priority: .utility) {
                var query = FetchDescriptor<CustomLUT>(predicate: #Predicate { $0.id == id })
                query.fetchLimit = 1
                return try? ModelContext(container).fetch(query).first?.displayName
            }.value
            if !Task.isCancelled { catalogName = name }
        }
    }

    private func lookRow(_ title: LocalizedStringKey, name: String, intensity: Double? = nil,
                         @ViewBuilder preview: () -> some View) -> some View {
        HStack(spacing: 12) {
            Color.primary.opacity(0.06)
                .frame(width: Self.previewSize, height: Self.previewSize)
                .overlay { preview() }
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: name).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let intensity {
                Text(intensity, format: .percent)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var filmName: String {
        if let name = look.preset?.displayName ?? look.filmName ?? catalogName { return name }
        if look.customID != nil { return String(localized: "Custom LUT") }
        return showsNoLUT ? String(localized: "No LUT") : String(localized: "Not recorded")
    }

    @ViewBuilder private var filmCover: some View {
        if let filename = look.preset?.libraryCardImage {
            VaultImage(filename: filename, maxPixel: Int(Self.previewSize * displayScale), placeholderSystemImage: "film")
                .id(filename)
        } else if look.customID != nil {
            CustomLUTCover()
        } else {
            Image(systemName: "camera.filters")
                .foregroundStyle(.secondary)
        }
    }
}
