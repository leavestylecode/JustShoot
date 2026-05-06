import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - 等效焦距档位
enum FocalLengthOption: Int, CaseIterable, Identifiable {
    case mm13 = 13
    case mm24 = 24
    case mm35 = 35
    case mm50 = 50
    case mm100 = 100
    case mm200 = 200

    var id: Int { rawValue }
    var mm: Float { Float(rawValue) }
    var label: String { "\(rawValue)" }
}

// MARK: - 设备焦段信息（基于虚拟设备 constituent + switchOver 阈值）

/// 单个 constituent 物理镜头的元数据 + 在虚拟设备 zoom 坐标里的归属区间。
struct ConstituentInfo {
    /// 物理镜头实例（用于 KVO 比对：activePrimaryConstituentDevice === device 即代表已锁到此镜头）
    let device: AVCaptureDevice
    /// 35mm 等效焦距（如 17 Pro 的 W = 24mm，T = 100mm 或 200mm）
    let nativeMm: Float
    /// 此镜头在虚拟设备 zoom 坐标里被系统选用的范围（开区间右端为下一个 constituent 的 switchOver）。
    /// 例：[1.0, 2.0) = UW；[2.0, 5.0) = W；[5.0, +∞) = T。`.locked` 后系统会
    /// 把 minAvailableVideoZoomFactor 钉到本区间下界。
    let virtualZoomRange: ClosedRange<CGFloat>
}

struct DeviceFocalInfo {
    /// 可用焦段选项
    let options: [FocalLengthOption]
    /// 按 nativeMm 升序的 constituent 列表（UW < W < T）。仅含至少一颗。
    let constituents: [ConstituentInfo]
    /// 主 constituent（数组首位）的原生 35mm 等效焦距 — 虚拟设备 zoom=1.0 对应此 FOV。
    /// 任意 zoom Z 的等效焦距 ≈ primaryNativeMm × Z（线性，与系统选哪颗 constituent 无关）。
    let primaryNativeMm: Float

    /// 默认值（session 未配置前的临时占位）
    static let placeholder = DeviceFocalInfo(options: [.mm24, .mm35], constituents: [], primaryNativeMm: 24)

    /// 该档位应锁定到哪颗 constituent。策略：找原生 ≤ 目标 mm 的最长一颗（让 constituent 自身做
    /// 数字裁切，质量优于让更广的 constituent 裁更多）。例：100mm 选 T(100)，35mm 选 W(24)。
    func constituent(for option: FocalLengthOption) -> ConstituentInfo? {
        guard !constituents.isEmpty else { return nil }
        let candidate = constituents.last(where: { $0.nativeMm <= option.mm + 0.5 })
        return candidate ?? constituents.first
    }

    /// 该档位对应的虚拟设备 videoZoomFactor。
    /// **关键**：虚拟设备 zoom ↔ 等效焦距是**分段线性**关系（每个 constituent 一段），不是单一斜率。
    /// 在 constituent c 的活跃区间里：FOV = c.nativeMm × (zoom / c.virtualZoomRange.lowerBound)。
    /// 反推：要让 FOV = option.mm，需 zoom = option.mm × c.lowerBound / c.nativeMm。
    /// 例（17 Pro：UW=13mm[1-2], W=24mm[2-8], T=100mm[8-189]）：
    ///   13mm→1.0(UW)  24mm→2.0(W)  35mm→2.92(W)  50mm→4.17(W)  100mm→8.0(T)  200mm→16.0(T)
    func virtualZoomFactor(for option: FocalLengthOption) -> CGFloat {
        guard let c = constituent(for: option), c.nativeMm > 0 else { return 1.0 }
        return CGFloat(option.mm) * c.virtualZoomRange.lowerBound / CGFloat(c.nativeMm)
    }

    /// 该档位是否纯数字裁切（即 constituent 上的等效裁切倍率 > 1.05x）
    func isDigitalCrop(_ option: FocalLengthOption) -> Bool {
        guard let c = constituent(for: option), c.nativeMm > 0 else { return false }
        return option.mm / c.nativeMm > 1.05
    }

    /// 在 session 配置完成、虚拟设备已运行后调用。读 constituentDevices +
    /// virtualDeviceSwitchOverVideoZoomFactors 推导每颗 constituent 的 virtualZoomRange。
    static func from(virtualDevice device: AVCaptureDevice) -> DeviceFocalInfo {
        // 物理设备（无 constituent）：把自己当作唯一 constituent，virtualZoomRange = [1, maxZoom]
        var raws: [(device: AVCaptureDevice, nativeMm: Float)] = []
        if device.constituentDevices.isEmpty {
            raws.append((device, device.nominalFocalLengthIn35mmFilm > 0 ? device.nominalFocalLengthIn35mmFilm : 26.0))
        } else {
            for c in device.constituentDevices {
                let mm = c.nominalFocalLengthIn35mmFilm > 0 ? c.nominalFocalLengthIn35mmFilm : 26.0
                raws.append((c, mm))
            }
        }
        // virtualDeviceSwitchOverVideoZoomFactors 与 constituentDevices 顺序一致：
        // factors[i] = 从 constituent[i] 切到 constituent[i+1] 的虚拟 zoom 阈值。
        // 数组长度 = constituentDevices.count - 1（物理设备时为空）。
        let switchOvers: [CGFloat] = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let maxZoom = device.activeFormat.videoMaxZoomFactor

        var constituents: [ConstituentInfo] = []
        for (idx, raw) in raws.enumerated() {
            let lower: CGFloat = idx == 0 ? 1.0 : switchOvers[idx - 1]
            let upper: CGFloat = idx < switchOvers.count ? switchOvers[idx] : maxZoom
            constituents.append(ConstituentInfo(
                device: raw.device,
                nativeMm: raw.nativeMm,
                virtualZoomRange: lower...upper
            ))
        }

        let primaryMm = constituents.first?.nativeMm ?? 26.0

        // 按 35mm 等效 nativeMm 分类已存在的物理 constituent。每档焦距只在其依赖的物理镜头存在时露出。
        // 阈值取宽松值兜住型号差异：UW 12.5–18mm，W 18–35mm，短长焦 ≥50mm（覆盖 52/56/65mm 老款），
        // 长长焦 ≥100mm（17 Pro/16 Pro Max/15 Pro Max）。
        let hasUW = constituents.contains { $0.nativeMm <= 18 }                               // 13mm 类
        let hasWide = constituents.contains { $0.nativeMm > 18 && $0.nativeMm <= 35 }         // 24/26/28mm 类
        let hasTeleShort = constituents.contains { $0.nativeMm >= 50 }                        // 任意 T (52/56/65/77/100/120)
        let hasTeleLong = constituents.contains { $0.nativeMm >= 100 }                        // 100mm+ T（200mm 数码 2x 内）

        // 每档对应的物理依赖：
        //   13mm  → UW 物理存在
        //   24mm  → W 物理存在
        //   35mm  → W（W 内部 1.46x 数码裁切）
        //   50mm  → W（W 内部 2.08x 数码裁切）
        //   100mm → 任意 T 物理存在（最差 56mm 上 1.78x 数码裁切，可接受）
        //   200mm → ≥100mm T 物理存在（避免在 56mm/77mm 上做 2.5x+ 数码裁切的画质崩塌）
        let allOptions: [FocalLengthOption] = [.mm13, .mm24, .mm35, .mm50, .mm100, .mm200]
        var options = allOptions.filter { opt in
            switch opt {
            case .mm13: return hasUW
            case .mm24, .mm35, .mm50: return hasWide
            case .mm100: return hasTeleShort
            case .mm200: return hasTeleLong
            }
        }
        // 兜底：极端情况（仅 UW 或仅 T 的非 iPhone 物理设备）下保 24mm 不空——UW 上 1.85x 数码裁切
        // 仍能产出 24mm 视野；让 picker 至少有一档可选，避免 UI 空状态崩溃。
        if options.isEmpty {
            options = [.mm24]
        }

        let constituentLog = constituents.map { c in
            "\(Int(c.nativeMm))mm[\(String(format: "%.2f", c.virtualZoomRange.lowerBound))-\(String(format: "%.2f", c.virtualZoomRange.upperBound))]"
        }.joined(separator: ",")
        Log.session.info("focal_info virtual=\(device.localizedName, privacy: .public) primaryMm=\(primaryMm) constituents=[\(constituentLog, privacy: .public)] switchOvers=\(switchOvers.map { String(format: "%.2f", $0) }) maxZoom=\(String(format: "%.2f", maxZoom)) options=\(options.map { $0.rawValue })")

        return DeviceFocalInfo(options: options, constituents: constituents, primaryNativeMm: primaryMm)
    }
}
