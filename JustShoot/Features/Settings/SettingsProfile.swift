import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct SettingsProfileCard: View {
    private struct EditSession: Identifiable {
        let id = UUID()
        let profile: SettingsProfile
        let accountID: String?
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = SettingsProfileStore.shared
    @State private var editSession: EditSession?

    var body: some View {
        let profile = store.profile
        let name = profile.nickname.isEmpty ? String(localized: "profile_set_nickname_prompt") : profile.nickname
        let description = profile.motto.isEmpty ? String(localized: "profile_set_motto_prompt") : profile.motto

        Button {
            editSession = EditSession(profile: store.profile, accountID: store.accountID)
        } label: {
            HStack(spacing: 14) {
                ProfileAvatar(data: profile.avatar, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                SettingsChevron.forward
            }
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(16)
        .settingsGlassCard(cornerRadius: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(name), \(description)"))
        .accessibilityHint("Edit Profile")
        .sheet(item: $editSession) { session in
            ProfileEditor(nickname: session.profile.nickname, motto: session.profile.motto, avatar: session.profile.avatar) {
                store.save($0, editedFrom: session.profile, accountID: session.accountID)
            }
        }
        .onChange(of: store.accountID) { _, current in
            if let openedAccount = editSession?.accountID, openedAccount != current { editSession = nil }
        }
        .task(id: scenePhase, priority: .utility) {
            guard scenePhase == .active else { return }
            repeat {
                store.refresh()
            } while (try? await Task.sleep(for: .seconds(30))) != nil
        }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var nickname: String
    @State var motto: String
    @State var avatar: Data
    @State private var showsAvatarActions = false
    @State private var showsPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var queuedCrop: ProfilePhotoPreview?
    @State private var cropRequest: ProfilePhotoPreview?
    @State private var confirmedSource: ProfilePhotoPreview?
    @State private var adjustsSavedPhoto = false
    @State private var showsPhotoError = false
    @FocusState private var nicknameFocused: Bool
    @FocusState private var mottoFocused: Bool
    let save: (SettingsProfile) -> Void

    private var isLoadingAvatar: Bool { pickedPhoto != nil || adjustsSavedPhoto }

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                fieldSection("Nickname", text: $nickname, limit: 15, focused: $nicknameFocused)
                fieldSection("profile_field_motto", text: $motto, limit: 100, focused: $mottoFocused)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .appPageBackground()
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .legacySoftToolbarEdges()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .toolbarControlSurface()
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save(SettingsProfile(nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                                             motto: motto.trimmingCharacters(in: .whitespacesAndNewlines),
                                             avatar: avatar))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .toolbarControlSurface()
                    }
                    .accessibilityLabel("Done")
                    .disabled(isLoadingAvatar)
                }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $pickedPhoto,
                          matching: .images, preferredItemEncoding: .current)
            .onChange(of: showsPhotoPicker) { _, _ in presentQueuedCropIfReady() }
            .confirmationDialog("", isPresented: $showsAvatarActions, titleVisibility: .hidden) {
                Button("profile_adjust_photo") {
                    if let confirmedSource { cropRequest = confirmedSource }
                    else { adjustsSavedPhoto = true }
                }
                Button("Choose Profile Photo") { showsPhotoPicker = true }
                Button("Remove Profile Photo", role: .destructive) {
                    avatar = Data()
                    confirmedSource = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                Button("Cancel", role: .cancel) {}
            }
            .fullScreenCover(item: $cropRequest) { request in
                AvatarCropView(image: request.image) {
                    cropRequest = nil
                } onConfirm: { croppedData in
                    avatar = croppedData
                    confirmedSource = request
                    cropRequest = nil
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if nicknameFocused || mottoFocused {
                    keyboardToolbar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .settingsGlassCard(cornerRadius: 24)
                        .padding(.horizontal)
                        .padding(.bottom)
                        .frame(maxWidth: .infinity)
                        .legacySoftBarBackground(.bottom)
                } else {
                    Text("Your profile syncs automatically when iCloud is available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .alert("Couldn’t Load Profile Photo", isPresented: $showsPhotoError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try choosing a different photo.")
            }
        }
        .task(id: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            let preview = try? await item.loadTransferable(type: ProfilePhotoPreview.self)
            guard !Task.isCancelled, pickedPhoto == item else { return }
            pickedPhoto = nil
            if let preview {
                queuedCrop = preview
                presentQueuedCropIfReady()
            } else {
                showsPhotoError = true
            }
        }
        .task(id: adjustsSavedPhoto) {
            guard adjustsSavedPhoto else { return }
            let data = avatar
            let image = await BlockingImageWork.shared.run { UIImage(data: data)?.preparingForDisplay() }
            guard !Task.isCancelled else { return }
            adjustsSavedPhoto = false
            if let image { cropRequest = ProfilePhotoPreview(image: image) }
            else { showsPhotoError = true }
        }
    }

    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    nicknameFocused = false
                    mottoFocused = false
                    if avatar.isEmpty { showsPhotoPicker = true }
                    else { showsAvatarActions = true }
                } label: {
                    ProfileAvatar(data: avatar, size: 100, editing: true)
                        .overlay {
                            if isLoadingAvatar { ProgressView().accessibilityLabel("Loading Profile Photo") }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(avatar.isEmpty ? Text("Choose Profile Photo") : Text("Change Profile Photo"))
                .disabled(isLoadingAvatar)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    private func fieldSection(
        _ key: String.LocalizationValue,
        text: Binding<String>,
        limit: Int,
        focused: FocusState<Bool>.Binding
    ) -> some View {
        let title = String(localized: key)
        return Section {
            TextField(title, text: text, prompt: Text(verbatim: title).foregroundStyle(.secondary))
                .focused(focused)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundStyle(.primary)
                .tint(.primary)
                .padding(4)
                .onChange(of: text.wrappedValue) { _, value in
                    if value.count > limit { text.wrappedValue = String(value.prefix(limit)) }
                }
        } header: {
            if !text.wrappedValue.isEmpty {
                Text(verbatim: "\(title) (\(text.wrappedValue.count)/\(limit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var keyboardToolbar: some View {
        HStack(spacing: 12) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                nicknameFocused = false
                mottoFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("common_hide_keyboard")

            Spacer()

            clearFieldButton("Nickname", text: $nickname)
            clearFieldButton("profile_field_motto", text: $motto)
        }
    }

    @ViewBuilder
    private func clearFieldButton(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        if !text.wrappedValue.isEmpty {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(reduceMotion ? nil : .default) { text.wrappedValue = "" }
            } label: {
                Label(title, systemImage: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .frame(height: 32)
                    .padding(.horizontal, 12)
                    .background(.red.opacity(0.1), in: .rect(cornerRadius: 8))
            }
            .transition(.opacity)
        }
    }

    private func presentQueuedCropIfReady() {
        guard !showsPhotoPicker, cropRequest == nil, let queuedCrop else { return }
        self.queuedCrop = nil
        cropRequest = queuedCrop
    }
}

private struct ProfileAvatar: View {
    let data: Data
    let size: CGFloat
    var editing = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay { if editing { Circle().strokeBorder(.secondary) } }
            } else {
                Circle()
                    .fill(.secondary.opacity(editing ? 0.18 : 0.12))
                    .overlay {
                        Image(systemName: editing ? "person.crop.circle.badge.plus" : "person.fill")
                            .font(editing ? .system(size: 40) : .title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
        .task(id: data) {
            if data.isEmpty {
                image = nil
                return
            }
            let decoded = await BlockingImageWork.shared.run { UIImage(data: data)?.preparingForDisplay() }
            if !Task.isCancelled { image = decoded }
        }
    }
}

private struct ProfilePhotoPreview: Transferable, Identifiable {
    let id = UUID()
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let url = file.file
            let image = await BlockingImageWork.shared.run { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = ImageLoader.downsample(source, maxPixel: 2048) else { return nil }
                return UIImage(cgImage: thumbnail)
            }
            try Task.checkCancellation()
            guard let image else { throw CocoaError(.fileReadCorruptFile) }
            return Self(image: image)
        }
    }
}
