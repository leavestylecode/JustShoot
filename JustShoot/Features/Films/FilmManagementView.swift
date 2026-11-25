import SwiftUI

struct FilmManagementView: View {
    @ObservedObject var settings: FilmPageSettings
    let sources: [FilmSource]
    let onDelete: (UUID) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var pendingDelete: FilmSource?

    var body: some View {
        let orderedSources = settings.preferences.ordered(sources).filter(settings.preferences.isVisible)

        NavigationStack {
            List {
                Section("Text Display") {
                    Toggle("Show Titles", isOn: $settings.preferences.showsTitle)
                        .tint(.green)
                        .accessibilityIdentifier("films.showTitles")
                    Toggle("Show Subtitles", isOn: $settings.preferences.showsSubtitle)
                        .tint(.green)
                        .accessibilityIdentifier("films.showSubtitles")
                }
                Section {
                    ForEach(orderedSources) { source in
                        filmRow(source)
                    }
                    .onMove { offsets, destination in
                        settings.move(from: offsets, to: destination, in: orderedSources)
                    }
                } header: {
                    HStack {
                        Text("Film Order")
                        Spacer()
                        Button("Reset") { settings.resetOrder() }
                            .font(.subheadline)
                            .textCase(nil)
                            .frame(minWidth: 44, minHeight: 44)
                            .buttonStyle(.borderless)
                            .disabled(settings.preferences.orderedFilmIDs.isEmpty)
                            .accessibilityLabel("Reset Film Order")
                            .accessibilityIdentifier("films.resetOrder")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .pageContentWidth()
            .appPageBackground()
            .navigationTitle("Manage Films")
            .navigationBarTitleDisplayMode(.inline)
            .softScrollEdges()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done").toolbarControlSurface(text: true)
                    }
                }
            }
            .modifier(FilmDeletionConfirmation(pending: $pendingDelete, onDelete: onDelete))
        }
    }

    private func filmRow(_ source: FilmSource) -> some View {
        HStack(spacing: 12) {
            cover(source)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(verbatim: source.filmPageTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch source {
            case .preset(let preset):
                Button {
                    settings.setVisible(preset, false)
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(source.filmPageTitle) from Films")
                .accessibilityHint("You can add this film again from the Film Vault")
                .accessibilityIdentifier("films.visibility.\(source.id)")
            case .custom:
                Button(role: .destructive) { pendingDelete = source } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(source.filmPageTitle)")
                .accessibilityIdentifier("films.delete.\(source.id)")
            }
        }
        .foregroundStyle(settings.preferences.isVisible(source) ? .primary : .secondary)
    }

    private func cover(_ source: FilmSource) -> some View {
        ZStack {
            Color.primary.opacity(0.08)
            if case .preset(let preset) = source, let filename = preset.libraryCardImage {
                VaultImage(filename: filename, maxPixel: Int(40 * displayScale), placeholderSystemImage: "film")
            } else {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
            }
        }
    }
}

/// Both the grid and management list use the same confirmation and failure recovery.
struct FilmDeletionConfirmation: ViewModifier {
    @Binding var pending: FilmSource?
    let onDelete: (UUID) throws -> Void
    @State private var deletionError: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete Film?", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ), titleVisibility: .visible, presenting: pending) { source in
                Button("Delete", role: .destructive) {
                    guard case .custom(let id, _, _, _) = source else { return }
                    do { try onDelete(id) }
                    catch { deletionError = error.localizedDescription }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { source in
                Text("“\(source.filmPageTitle)” will be deleted. Existing photos are kept.")
            }
            .alert("Could not delete filter", isPresented: Binding(
                get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) { deletionError = nil }
            } message: {
                Text(deletionError ?? "")
            }
    }
}
