import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var capturePipeline = CapturePipeline.shared
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary
    /// 逐阶段处理对照图（默认关）。与 FilmProcessor 共享同一 key：开 = 每次拍摄额外保留
    /// 原片与 LUT/光学/颗粒各阶段输出，用于定位细节在哪一步丢失。
    @AppStorage("processingStageDiagnostics") private var processingStageDiagnostics = false
    @State private var exportingDiagnostics = false
    @State private var diagnosticExportFailed = false
    @State private var recoveryToDiscard: CaptureRecoveryIssue?
    @State private var recoveryExport: RecoveryOriginalExport?
    @State private var isManagingRecovery = false
    @State private var showsDiagnostics = false

    private let supportLinks = AppSupportLinks(info: Bundle.main.infoDictionary ?? [:])

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appHeader
                    if capturePipeline.pendingCount + capturePipeline.retainedCount > 0 { pendingPhotosSection }
                    if !capturePipeline.recoveryIssues.isEmpty { recoveryPhotosSection }
                    toolsSection
                    feedbackSection
                    Text("© 2026 Leavestylecode")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
                .padding()
                .pageContentWidth()
            }
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .softScrollEdges()
        }
        .preferredColorScheme(.dark)
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

    private var appHeader: some View {
        HStack(spacing: 16) {
            AppBrandMark()
                .frame(width: 40, height: 40)
                .frame(width: 64, height: 64)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: AppBrand.displayName)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Version \(appVersion)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.15, green: 0.10, blue: 0.11), Color(white: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 24)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)))
    }

    // MARK: - 评分 / 反馈
    @ViewBuilder
    private var feedbackSection: some View {
        if supportLinks.reviewURL != nil || supportLinks.feedbackURL != nil {
            sectionCard {
                if let url = supportLinks.reviewURL {
                    Button { openURL(url) } label: {
                        SettingRow(icon: "star.fill", iconColor: .yellow,
                                   title: "Rate on the App Store", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }

                if supportLinks.reviewURL != nil && supportLinks.feedbackURL != nil {
                    Divider().overlay(Color.white.opacity(0.08))
                }

                if let url = supportLinks.feedbackURL {
                    Button { openURL(url) } label: {
                        SettingRow(icon: "envelope.fill", iconColor: .blue,
                                   title: "Send Feedback", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// 分区卡片：白 6% 圆角实色背景（非玻璃），内部纵向堆叠行。
    private func sectionCard<Content: View>(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: spacing) { content() }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 20))
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
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)
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
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
