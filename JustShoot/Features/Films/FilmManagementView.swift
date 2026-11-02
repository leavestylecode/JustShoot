import SwiftUI

struct FilmManagementView: View {
    @ObservedObject var settings: FilmPageSettings
    let sources: [FilmSource]
    let presetCovers: [FilmPreset: UIImage]
    let onDelete: (UUID) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: FilmSource?

    var body: some View {
        let orderedSources = settings.preferences.ordered(sources)

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
                        settings.move(from: offsets, to: destination, in: sources)
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
                            .disabled(orderedSources == sources)
                            .accessibilityLabel("Reset Film Order")
                            .accessibilityIdentifier("films.resetOrder")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .pageContentWidth()
            .background(Color.black)
            .navigationTitle("Manage Films")
            .navigationBarTitleDisplayMode(.inline)
            .softScrollEdges()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .modifier(FilmDeletionConfirmation(pending: $pendingDelete, onDelete: onDelete))
        }
        .preferredColorScheme(.dark)
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
                let visible = !settings.preferences.hiddenPresetIDs.contains(preset.rawValue)
                Button {
                    settings.setVisible(preset, !visible)
                } label: {
                    Image(systemName: visible ? "eye" : "eye.slash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: source.filmPageTitle))
                .accessibilityValue(settings.preferences.isVisible(source) ? Text("Shown") : Text("Hidden"))
                .accessibilityHint("Show or hide this film")
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
            Color.white.opacity(0.08)
            if case .preset(let preset) = source, let image = presetCovers[preset] {
                Image(uiImage: image).resizable().scaledToFill()
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
