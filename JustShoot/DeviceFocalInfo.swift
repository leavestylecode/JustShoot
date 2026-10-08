import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - 等效焦距档位
//
// 焦距档位**不是固定枚举**，而是根据设备实际物理镜头动态生成（见 DeviceFocalInfo.buildOptions）：
// 单 / 双 / 三镜头设备各自得到匹配的档位。每个档位是 35mm 等效焦距（整数）+ 是否落在某颗镜头原生焦距。
//
// 焦距模型（与 iPhone 原相机一致）：**每颗 constituent 用自己 Apple 标称的 nominalFocalLengthIn35mmFilm
// 锚定**——在 constituent c 的活跃区间里 等效焦距 = c.nativeMm × (zoom / c.lowerBound)。
// 例：主摄(24mm) 在 1x(zoom=lowerBound) = 24mm，2x = 48mm；长焦(100mm) 同理。正向(virtualZoomFactor)
// 与反向(equivalentMm)共用这一个模型，保证 picker 标签 / EXIF / 实际视野三者一致。
struct FocalLengthOption: Identifiable, Hashable {
    /// 35mm 等效焦距（整数 mm，如 13 / 24 / 35 / 100）
    let value: Int
    /// 是否落在某颗物理镜头的原生焦距上（无数字裁切、画质最佳）。UI 可据此给原生档加标记。
    let isNative: Bool

    init(_ value: Int, isNative: Bool = false) {
        self.value = value
        self.isNative = isNative
    }

    var id: Int { value }
    var rawValue: Int { value }      // 兼容：EXIF FocalLenIn35mmFilm / 安全快门 / 日志
    var mm: Float { Float(value) }   // 兼容：焦距换算（Float）
    var label: String { "\(value)" }

    // 相等性只看 value——同一焦距无论 isNative 与否都视为同一档（contains / firstIndex / 去重用）。
    static func == (l: FocalLengthOption, r: FocalLengthOption) -> Bool { l.value == r.value }
    func hash(into h: inout Hasher) { h.combine(value) }
}

// MARK: - 设备焦段信息（基于虚拟设备 constituent + switchOver 阈值）

/// 单颗 constituent 物理镜头的元数据 + 在虚拟设备 zoom 坐标里的归属区间。
struct ConstituentInfo {
    /// 物理镜头实例（KVO 比对：activePrimaryConstituentDevice === device 即代表已锁到此镜头）
    let device: AVCaptureDevice
    /// 35mm 等效焦距（Apple 标称 nominalFocalLengthIn35mmFilm，如 W=24mm、T=100mm）
    let nativeMm: Float
    /// 此镜头在虚拟设备 zoom 坐标里被系统选用的范围（下界 = 上一个 switchOver 或 1.0）。
    let virtualZoomRange: ClosedRange<CGFloat>

    /// 硬件分类（按 35mm 等效标称）：超广 < 20mm；主摄 20–50mm；长焦 > 50mm。
    var isUltraWide: Bool { nativeMm < DeviceFocalInfo.ultraWideNativeMmCeiling }
    var isTele: Bool { nativeMm > DeviceFocalInfo.teleNativeMmFloor }
}

struct DeviceFocalInfo {
    /// 硬件镜头分类阈值（35mm 等效标称）：超广角 < 20mm（主摄 24–28mm 均在其上）；
    /// 长焦 > 50mm（主摄最高 28mm，长焦最低 77mm，50 为安全分界）。
    static let ultraWideNativeMmCeiling: Float = 20
    static let teleNativeMmFloor: Float = 50

    /// 可用焦段选项（按设备实际镜头生成，升序）
    let options: [FocalLengthOption]
    /// 按 nativeMm 升序的 constituent 列表（UW < W < T）。仅含至少一颗。
    let constituents: [ConstituentInfo]
    /// 最广 constituent 的原生 35mm 等效（虚拟设备 zoom=1.0 对应它）。
    /// 仅作 equivalentMm 在「无活跃 constituent」时的兜底锚点；正常焦距换算按每镜头各自锚定。
    let primaryNativeMm: Float

    /// 默认值（session 未配置前的临时占位）
    static let placeholder = DeviceFocalInfo(
        options: [FocalLengthOption(24), FocalLengthOption(35)],
        constituents: [],
        primaryNativeMm: 24
    )

    /// 超广角 / 长焦 constituent（按标称焦距分类；硬件没有则为 nil）。
    var ultraWideConstituent: ConstituentInfo? { constituents.first(where: \.isUltraWide) }
    var teleConstituent: ConstituentInfo? { constituents.last(where: \.isTele) }

    /// 入页默认焦段：最接近 35mm（经典标准视角）的可用档；无则首档。
    var defaultOption: FocalLengthOption {
        options.min(by: { abs($0.value - 35) < abs($1.value - 35) }) ?? FocalLengthOption(35)
    }

    /// 该档位应锁定到哪颗 constituent。策略：原生 ≤ 目标 mm 的最长一颗（让它自身数字裁切，
    /// 质量优于让更广的镜头裁更多）。例：100mm 选 T(100)，35mm 选 W(24)。
    func constituent(for option: FocalLengthOption) -> ConstituentInfo? {
        guard !constituents.isEmpty else { return nil }
        return constituents.last(where: { $0.nativeMm <= option.mm + 0.5 }) ?? constituents.first
    }

    /// 档位 → 虚拟设备 videoZoomFactor（正向）。
    /// 模型：在承载镜头 c 的活跃区间里 等效焦距 = c.nativeMm × (zoom / c.lowerBound)，
    /// 反推 zoom = mm × c.lowerBound / c.nativeMm。每颗镜头用自己 Apple 标称焦距做锚，
    /// 与 iPhone 原相机一致（主摄 1x=24mm、2x=48mm；长焦 100mm），各原生焦段精确命中标称值。
    /// 例（17 Pro：UW=13[1-2], W=24[2-8], T=100[8-189]）：
    ///   13→1.00(UW)  24→2.00(W)  35→2.92(W)  50→4.17(W)  100→8.00(T)  200→16.00(T)
    func virtualZoomFactor(for option: FocalLengthOption) -> CGFloat {
        guard let c = constituent(for: option), c.nativeMm > 0 else { return 1.0 }
        return CGFloat(option.mm) * c.virtualZoomRange.lowerBound / CGFloat(c.nativeMm)
    }

    /// 本次 zoom 变更是否跨越 constituent 边界（任一 switchover 阈值严格落在起止 zoom 之间）。
    /// 同镜头短跳与跨镜头切换的体验策略不同：前者用高速短 ramp（迟滞感是主诉），
    /// 后者维持速率阶梯（系统需要时间从容做 constituent crossfade，过快反而触发
    /// 更重的管线重配），且 settle 等待窗口要覆盖实测的跨镜头停帧时长。
    func crossesConstituentBoundary(fromZoom: CGFloat, toZoom: CGFloat) -> Bool {
        constituents.dropFirst().contains {
            let threshold = $0.virtualZoomRange.lowerBound
            return min(fromZoom, toZoom) < threshold && max(fromZoom, toZoom) > threshold
        }
    }

    /// zoom → 等效焦距（反向，与 virtualZoomFactor 共用同一模型）。
    /// 按当前活跃 constituent 的原生焦距 + 数字裁切倍率反推：equiv = c.nativeMm × (zoom / c.lowerBound)。
    /// 比「primaryNativeMm × zoom」准——后者把最广镜头的（已取整）标称外推到长焦端会累积误差
    /// （如 200mm 档会被读成 208mm）。activeConstituent 为 nil（极早期 / 物理设备）时退回兜底。
    func equivalentMm(forZoom zoom: CGFloat, activeConstituent: AVCaptureDevice?) -> Float {
        if let active = activeConstituent,
           let c = constituents.first(where: { $0.device === active }), c.virtualZoomRange.lowerBound > 0 {
            return c.nativeMm * Float(zoom / c.virtualZoomRange.lowerBound)
        }
        return primaryNativeMm * Float(zoom)
    }

    /// 该档位是否纯数字裁切（承载镜头上裁切 > 1.05x）。UI 据此把数码裁切档显示得淡一些。
    func isDigitalCrop(_ option: FocalLengthOption) -> Bool {
        guard let c = constituent(for: option), c.nativeMm > 0 else { return false }
        return option.mm / c.nativeMm > 1.05
    }

    /// 在 session 配置完成、虚拟设备已运行后调用。读 constituentDevices +
    /// virtualDeviceSwitchOverVideoZoomFactors 推导每颗 constituent 的 virtualZoomRange，
    /// 并据实际镜头生成焦段档位。
    static func from(virtualDevice device: AVCaptureDevice) -> DeviceFocalInfo {
        // 1) 收集物理 constituent（单镜头设备把自己当唯一 constituent），按等效焦距升序
        var raws: [(device: AVCaptureDevice, nativeMm: Float)] = []
        if device.constituentDevices.isEmpty {
            raws.append((device, device.nominalFocalLengthIn35mmFilm > 0 ? device.nominalFocalLengthIn35mmFilm : 26.0))
        } else {
            for c in device.constituentDevices {
                let mm = c.nominalFocalLengthIn35mmFilm > 0 ? c.nominalFocalLengthIn35mmFilm : 26.0
                raws.append((c, mm))
            }
        }
        raws.sort { $0.nativeMm < $1.nativeMm }

        // virtualDeviceSwitchOverVideoZoomFactors 与 constituentDevices 顺序一致：
        // factors[i] = 从 constituent[i] 切到 constituent[i+1] 的虚拟 zoom 阈值；长度 = 镜头数 - 1。
        let switchOvers: [CGFloat] = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let maxZoom = device.activeFormat.videoMaxZoomFactor

        // 2) 每颗 constituent 的虚拟 zoom 区间（越界保护：数组长度异常时两端退回 maxZoom）
        var constituents: [ConstituentInfo] = []
        for (idx, raw) in raws.enumerated() {
            let lower: CGFloat = idx == 0 ? 1.0 : (idx - 1 < switchOvers.count ? switchOvers[idx - 1] : maxZoom)
            let upper: CGFloat = idx < switchOvers.count ? switchOvers[idx] : maxZoom
            constituents.append(ConstituentInfo(device: raw.device, nativeMm: raw.nativeMm, virtualZoomRange: lower...upper))
        }
        let primaryMm = constituents.first?.nativeMm ?? 26.0

        // 3) 据实际镜头生成档位
        let options = buildOptions(constituents: constituents, maxZoom: maxZoom)

        let constituentLog = constituents.map { c in
            "\(Int(c.nativeMm))mm[\(String(format: "%.2f", c.virtualZoomRange.lowerBound))-\(String(format: "%.2f", c.virtualZoomRange.upperBound))]"
        }.joined(separator: ",")
        Log.session.info("focal_info virtual=\(device.localizedName, privacy: .public) primaryMm=\(primaryMm) constituents=[\(constituentLog, privacy: .public)] switchOvers=\(switchOvers.map { String(format: "%.2f", $0) }) maxZoom=\(String(format: "%.2f", maxZoom)) options=\(options.map { $0.value })")

        return DeviceFocalInfo(options: options, constituents: constituents, primaryNativeMm: primaryMm)
    }

    /// 档位集合的纯函数核心（可单测）。产品语义（2026-10-08 用户拍板）：
    /// - 标准档 [主摄标称, 35, 50] 恒在（任何后置设备都有主摄）；
    /// - 硬件存在超广角镜头才显示超广档（用其标称值，现代机型 13mm）；
    /// - 硬件存在长焦镜头才显示 100 与 200；
    /// - 主摄标称非 24（如旧机型 26mm）时标准首档用实际标称，保证原生档标记与 zoom 锚定准确。
    static func optionValues(mainMm: Int, ultraWideMm: Int?, hasTele: Bool) -> [Int] {
        var values: [Int] = []
        if let ultraWideMm { values.append(ultraWideMm) }
        values.append(mainMm)
        values.append(contentsOf: [35, 50])
        if hasTele { values.append(contentsOf: [100, 200]) }
        return Array(Set(values)).sorted()
    }

    /// 根据实际物理镜头生成焦段档位：`optionValues` 的集合 + isNative 标记（档位恰为某颗
    /// 镜头的标称原生焦距）+ 可达性护栏（档位换算的 videoZoomFactor 超出 maxZoom 的丢弃，
    /// 如无变焦余量设备上的 200mm）。三摄 → [13,24,35,50,100,200]；双(UW+W) → [13,24,35,50]；
    /// 双(W+T) → [24,35,50,100,200]；单摄 → [24(或标称),35,50]。
    private static func buildOptions(constituents: [ConstituentInfo], maxZoom: CGFloat) -> [FocalLengthOption] {
        guard let main = constituents.first(where: { !$0.isUltraWide }) ?? constituents.first else {
            return [FocalLengthOption(24, isNative: true)]
        }
        let values = optionValues(
            mainMm: Int(main.nativeMm.rounded()),
            ultraWideMm: constituents.first(where: \.isUltraWide).map { Int($0.nativeMm.rounded()) },
            hasTele: constituents.contains(where: \.isTele)
        )
        return values.compactMap { mm -> FocalLengthOption? in
            guard let host = constituents.last(where: { $0.nativeMm <= Float(mm) + 0.5 }) ?? constituents.first,
                  host.nativeMm > 0 else { return nil }
            let zoom = CGFloat(Float(mm)) * host.virtualZoomRange.lowerBound / CGFloat(host.nativeMm)
            guard zoom <= maxZoom + 0.5 else { return nil }
            let isNative = constituents.contains { Int($0.nativeMm.rounded()) == mm }
            return FocalLengthOption(mm, isNative: isNative)
        }
    }
}
