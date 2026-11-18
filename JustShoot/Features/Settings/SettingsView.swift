import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary
    @AppStorage(FilmSource.simulationGrainPreferenceKey) private var simulationGrain = false
    /// 逐阶段处理对照图（默认关）。与 FilmProcessor 共享同一 key：开 = 每次拍摄额外保留
    /// 原片与 LUT/光学/颗粒各阶段输出，用于定位细节在哪一步丢失。
    @AppStorage("processingStageDiagnostics") private var processingStageDiagnostics = false
    @State private var exportingDiagnostics = false
    @State private var diagnosticExportFailed = false
    @State private var recoveryToDiscard: CaptureRecoveryIssue?
    @State private var recoveryExport: RecoveryOriginalExport?
    @State private var isManagingRecovery = false
    @State private var showsDiagnostics = false
    @State private var showsReview = false
    @State private var showsShare = false
    @State private var preparingShare = false
    @State private var shareIcon: UIImage?

    private static let supportLinks = AppSupportLinks(info: Bundle.main.infoDictionary ?? [:])

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 16) {
                            SettingsProfileCard()
                            if capturePipeline.pendingCount + capturePipeline.retainedCount > 0 { pendingPhotosSection }
                            if !capturePipeline.recoveryIssues.isEmpty { recoveryPhotosSection }
                            capturePreferencesSection
                            toolsSection
                            appLinksSection
                        }

                        Spacer(minLength: 24)
                        settingsFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(minHeight: geometry.size.height)
                    .pageContentWidth()
                }
                .scrollIndicators(.hidden)
            }
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .softScrollEdges()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsReview) {
            AnimatedReviewSheet(reviewURL: Self.supportLinks.reviewURL)
        }
        .sheet(isPresented: $showsShare) {
            AppStoreShareSheet(url: Self.supportLinks.shareURL, title: AppBrand.displayName,
                               subject: AppBrand.displayName, icon: shareIcon)
        }
        .task(id: preparingShare) {
            guard preparingShare else { return }
            if shareIcon == nil {
                let icon = await BlockingImageWork.shared.run {
                    (UIImage(named: "Appicon60x60") ?? UIImage(named: "OOOLogo"))?.preparingForDisplay()
                }
                guard !Task.isCancelled else { return }
                shareIcon = icon
            }
            guard !Task.isCancelled else { return }
            showsShare = true
            preparingShare = false
        }
        .alert("Log export failed", isPresented: $diagnosticExportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try exporting the diagnostic log again.")
        }
        .sheet(item: $recoveryExport) { export in
            RecoveryOriginalShareSheet(url: export.url)
        }
        .confirmationDialog("Permanently delete recovery files?", isPresented: Binding(
            get: { recoveryToDiscard != nil },
            set: { if !$0 { recoveryToDiscard = nil } }
        ), titleVisibility: .visible) {
            if let issue = recoveryToDiscard {
                Button("Delete Recovery Files", role: .destructive) {
                    manageRecovery { await capturePipeline.discardRecoveryFiles(issue) }
                }
            }
        } message: {
            Text("This permanently deletes the original and video files kept for this recovery item. Photos already in your library are kept.")
        }
    }

    private var capturePreferencesSection: some View {
        sectionCard {
            Toggle("Grain for FUJIFILM simulations", isOn: $simulationGrain)
        }
    }

    private var diagnosticsSection: some View {
        sectionCard {
            Button {
                exportingDiagnostics = true
                Task {
                    defer { exportingDiagnostics = false }
                    DiagnosticWatchdog.shared.flushCameras(reason: "export")
                    Diagnostics.emit("log_export_requested", fields: Diagnostics.resourceFields())
                    do {
                        let url = try await DiagnosticLogStore.shared.export()
                        SharePresenter.presentDiagnosticLog(url)
                    } catch {
                        Diagnostics.emit("log_export_failed", fields: Diagnostics.errorFields(error))
                        diagnosticExportFailed = true
                    }
                }
            } label: {
                HStack {
                    SettingRow(icon: "doc.text", iconColor: .orange, title: "Export Diagnostic Log")
                    if exportingDiagnostics { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(exportingDiagnostics)

            Divider().overlay(Color.white.opacity(0.08))

            // 逐阶段对照图：原片 + LUT 后 + 光学后 + 成片，同一拍摄的四张图放进同一个
            // 查看器对比，即可直接定位"细节在哪一步消失"（对照本 app 的画质排查）。
            Toggle(isOn: $processingStageDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Processing Stages")
                        .foregroundStyle(.white)
                    Text("Save the original plus each processing stage (LUT, optics, grain) for every shot. Find them in Files → On My iPhone → \(AppBrand.displayName) → ProcessingDiagnostics. Only the last 6 shots are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.green)

            Text("After reproducing a problem, export the recent diagnostic log. It contains no photos or precise location.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pendingPhotosSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Photos waiting to save", systemImage: "photo.badge.arrow.down")
                    .font(.headline)
                Text("\(capturePipeline.pendingCount + capturePipeline.retainedCount) photos are waiting to save.")
                Text("Your original photos and Live Photo videos are kept on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry Saving") {
                        Task { await capturePipeline.retryPending() }
                    }
                    .disabled(capturePipeline.pendingCount > 0)
                    Spacer()
                    Button("Open Settings", action: openAppSettings)
                }
            }
            .padding()
        }
    }

    private var recoveryPhotosSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Photos needing attention", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("\(capturePipeline.recoveryIssues.count) photos need recovery attention.")
                Text("These files are kept on this device. You can retry recovery or export the original before deleting them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry Recovery") { manageRecovery { await capturePipeline.retryPending() } }
                    .disabled(isManagingRecovery || capturePipeline.pendingCount > 0)
                ForEach(capturePipeline.recoveryIssues) { issue in
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = issue.date {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                                .font(.subheadline)
                        }
                        Text(issue.reason.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Export Original") {
                                manageRecovery {
                                    if let url = await capturePipeline.exportRecoveryOriginal(issue) {
                                        recoveryExport = RecoveryOriginalExport(url: url)
                                    }
                                }
                            }
                            .disabled(!issue.hasOriginal || isManagingRecovery)
                            Spacer()
                            Button("Delete Recovery Files", role: .destructive) { recoveryToDiscard = issue }
                                .disabled(isManagingRecovery)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func manageRecovery(_ action: @escaping @MainActor () async -> Void) {
        guard !isManagingRecovery else { return }
        isManagingRecovery = true
        Task { @MainActor in
            defer { isManagingRecovery = false }
            await action()
        }
    }

    private var toolsSection: some View {
        sectionCard(spacing: 4) {
            NavigationLink {
                FilmCurveLibraryView()
            } label: {
                SettingRow(
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    iconColor: .mint,
                    title: "Film Curves",
                    value: "\(curveLibrary.visibleCurveCount)/\(curveLibrary.totalCurveCount)",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(Color.white.opacity(0.08))

            DisclosureGroup(isExpanded: $showsDiagnostics) {
                diagnosticsSection
                    .padding(.top, 8)
            } label: {
                SettingRow(icon: "waveform.path.ecg", iconColor: .orange, title: "Diagnostics")
            }
            .tint(.secondary)
        }
    }

    private var appLinksSection: some View {
        sectionCard(spacing: 4) {
            NavigationLink {
                AboutAuthorView()
            } label: {
                SettingRow(icon: "person.circle.fill", iconColor: .teal,
                           title: "About the Author", showsChevron: true)
            }
            .buttonStyle(.plain)

            Button {
                showsReview = true
            } label: {
                SettingRow(icon: "star.circle.fill", iconColor: Color(red: 0.95, green: 0.76, blue: 0.35),
                           title: "Rate on the App Store", showsChevron: true)
            }
            .buttonStyle(.plain)

            Button {
                preparingShare = true
            } label: {
                SettingRow(icon: "heart.circle.fill", iconColor: .red,
                           title: "Share App", showsChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(preparingShare)

            if let url = Self.supportLinks.feedbackURL {
                Button { openURL(url) } label: {
                    SettingRow(icon: "envelope", iconColor: .blue,
                               title: "Send Feedback", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsFooter: some View {
        VStack(spacing: 4) {
            Text("Version \(Self.appVersion)")
                .font(.caption.monospacedDigit())
            Text(verbatim: "Copyright © 2026 Leavestylecode")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    private func sectionCard<Content: View>(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: spacing) { content() }
            .padding(16)
            .frame(maxWidth: .infinity)
            .settingsGlassCard(cornerRadius: 24)
    }
}

// MARK: - 设置行（可复用脚手架）
//
// 左侧 SF Symbol 图标 + 标题，右侧可选 value 文本 + chevron。点击行为由外层 Button 包裹。
private struct SettingRow: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    var value: String? = nil
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func settingsGlassCard(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(Color.white.opacity(0.08), in: .rect(cornerRadius: cornerRadius))
        }
    }
}
