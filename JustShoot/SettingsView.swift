import SwiftUI
import AVFoundation

// MARK: - 设置页
//
// 结构沿用 DeepMusic 的设置页：ScrollView + 分区卡片（sectionCard）+ 自定义 SettingRow，
// 而不是原生 List/Form——这样后续加真实开关时风格统一、可控。
//
// 当前只放「关于 / 版本号」与「评分 / 反馈」，全是静态信息或外链，不需要持久化，所以
// **暂不引入 AppSettings / UserDefaults 单例**——等有真实偏好开关（例如 GPS 位置标记）时再补，
// 避免空脚手架 dead code。
//
// 卡片背景用低调实色（白 6% 圆角），而非 .glassEffect——与首页去玻璃后的风格保持一致。
struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    /// 照片输出画质档。与 CameraView 共享同一 @AppStorage key，拍照时读取生效（无需重启 app）。
    @AppStorage("photoOutputQuality") private var photoQuality: PhotoQuality = .default
    /// Live Photo 是否录音。与 CameraView 共享同一 @AppStorage key，下次入相机即生效。默认开。
    @AppStorage("livePhotoSoundEnabled") private var livePhotoSoundEnabled = true
    /// 麦克风权限是否被拒——开了声音却没授权时提示用户去系统设置开启。入页 + 开关变化时刷新。
    @State private var microphoneDenied = false

    // TODO: 上架后填入真实 App Store 数字 ID（apps.apple.com/app/id<这里>）。
    private let appStoreId = "0000000000"
    // TODO: 填入你的反馈邮箱。
    private let feedbackEmail = "feedback@example.com"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appHeader
                    photoQualitySection
                    livePhotoSection
                    feedbackSection
                    Spacer(minLength: 16)
                    versionFooter
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { refreshMicrophoneStatus() }
            .onChange(of: livePhotoSoundEnabled) { _, _ in refreshMicrophoneStatus() }
        }
        .preferredColorScheme(.dark)
    }

    /// 读系统麦克风授权态。开了声音却被拒时，下方提示行显示「去设置开启」。
    private func refreshMicrophoneStatus() {
        microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    // MARK: - 关于（App 标识 + 版本）
    private var appHeader: some View {
        sectionCard {
            HStack(spacing: 14) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.10), in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("JustShoot")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - 照片画质（用户可配置）
    //
    // iOS 原生「单选列表」写法（与 设置→相机→格式 一致）：每行 = 档位名(标题) + 右侧体积(灰) +
    // 选中打绿勾，不自绘任何图形。体积是纯数字+MB（跨语言通用）；需翻译的只有标题 + 4 个最短档位名。
    // 默认 .standard。改动即时写入 @AppStorage，下一张拍照就生效。
    private var photoQualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Photo Quality", systemImage: "photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            sectionCard {
                ForEach(PhotoQuality.allCases) { quality in
                    Button {
                        photoQuality = quality
                    } label: {
                        HStack(spacing: 10) {
                            Text(quality.displayName)
                                .foregroundStyle(.white)
                            Spacer()
                            Text(quality.approximateSize)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            // 始终占位（未选中时透明），让右侧体积文字在各行对齐、不跳动。
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .opacity(photoQuality == quality ? 1 : 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(quality.displayName), \(quality.approximateSize)")
                        .accessibilityAddTraits(photoQuality == quality ? [.isButton, .isSelected] : .isButton)
                    }
                    .buttonStyle(.plain)

                    if quality != PhotoQuality.allCases.last {
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
        }
    }

    // MARK: - Live Photo 声音（用户可配置，默认开）
    //
    // 开启时拍 Live Photo 会录入环境声（麦克风全程挂在相机会话上，配合混音音频会话——拍摄时
    // 不打断你正在播放的音乐）。需要麦克风权限；被拒时下方提示去系统设置开启。
    private var livePhotoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live Photo", systemImage: "livephoto")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            sectionCard {
                Toggle(isOn: $livePhotoSoundEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound")
                            .foregroundStyle(.white)
                        Text("Record sound with your Live Photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                // 开了声音但麦克风被拒：提示并提供「去设置开启」入口（否则 Live Photo 会静音）。
                if livePhotoSoundEnabled && microphoneDenied {
                    Divider().overlay(Color.white.opacity(0.08))
                    Button(action: openAppSettings) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Microphone access is off. Turn it on in Settings to record sound.")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 评分 / 反馈
    private var feedbackSection: some View {
        sectionCard {
            Button(action: rateApp) {
                SettingRow(icon: "star.fill", iconColor: .yellow,
                           title: "Rate on the App Store", showsChevron: true)
            }
            .buttonStyle(.plain)

            Divider().overlay(Color.white.opacity(0.08))

            Button(action: sendFeedback) {
                SettingRow(icon: "envelope.fill", iconColor: .blue,
                           title: "Send Feedback", showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 版本 / 版权 footer
    private var versionFooter: some View {
        VStack(spacing: 4) {
            Text("JustShoot \(appVersion)")
            Text("© 2026 Leavestylecode")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func rateApp() {
        guard let url = URL(string: "https://apps.apple.com/app/id\(appStoreId)?action=write-review") else { return }
        openURL(url)
    }

    private func sendFeedback() {
        let subject = "JustShoot Feedback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:\(feedbackEmail)?subject=\(subject)") else { return }
        openURL(url)
    }

    /// 分区卡片：白 6% 圆角实色背景（非玻璃），内部纵向堆叠行。
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
