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
}

struct DeviceFocalInfo {
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

    /// 根据实际物理镜头生成焦段档位。原则：
    /// 1) 每颗物理镜头的原生焦距必出现（isNative，无裁切、画质最佳、精确命中 Apple 标称）；
    /// 2) 补入经典中间焦段 [35, 50] 与「最长镜头 2×」长焦延伸，仅当它：
    ///    - 落在设备可达等效焦距范围内（zoom ≤ maxZoom），
    ///    - 相对承载它的镜头数字裁切 ≤ maxCrop（避免画质崩塌），
    ///    - 不与已有档位过近（±6% 视为重复，原生优先）。
    /// 单镜头 → 如 [26, 35, 50]；双镜头(UW+W) → [13,24,35,50]；双(W+T) → [24,35,50,77,154]；
    /// 三镜头(17 Pro) → [13,24,35,50,100,200]。各自匹配且焦距准确。
    private static func buildOptions(constituents: [ConstituentInfo], maxZoom: CGFloat) -> [FocalLengthOption] {
        guard let widest = constituents.first, let longest = constituents.last else {
            return [FocalLengthOption(26, isNative: true)]
        }
        let maxCrop: Float = 2.1   // 单颗镜头上可接受的最大数字裁切倍率（50mm 在主摄上 2.08x 仍可接受）
        // 设备可达的最长等效焦距：最长镜头从其下界算起、裁切不超过 maxCrop、且 zoom 不超过 maxZoom
        let teleReachZoom = min(maxZoom, longest.virtualZoomRange.lowerBound * CGFloat(maxCrop))
        let maxEquiv = longest.nativeMm * Float(teleReachZoom / longest.virtualZoomRange.lowerBound)
        let minEquiv = widest.nativeMm

        // 候选：各镜头原生（isNative）+ 经典中间焦段 + 最长镜头 2× 长焦延伸
        var candidates: [(mm: Int, isNative: Bool)] = constituents.map { (Int($0.nativeMm.rounded()), true) }
        for m in [35, 50] { candidates.append((m, false)) }
        candidates.append((Int((longest.nativeMm * 2).rounded()), false))

        // 同一 mm 时原生排前，便于去重时原生覆盖近似的非原生
        candidates.sort { ($0.mm, $0.isNative ? 0 : 1) < ($1.mm, $1.isNative ? 0 : 1) }

        var result: [FocalLengthOption] = []
        for cand in candidates {
            let mmF = Float(cand.mm)
            // 在设备可达等效范围内
            guard mmF >= minEquiv - 0.5, mmF <= maxEquiv + 0.5 else { continue }
            // 承载镜头 + 数字裁切检查（原生焦段裁切=1，必过）
            guard let host = constituents.last(where: { $0.nativeMm <= mmF + 0.5 }) ?? constituents.first else { continue }
            guard mmF / host.nativeMm <= maxCrop + 0.01 else { continue }
            // 去重：与已选档 ±6% 视为重复；若新档是原生而旧的不是，用原生替换
            if let dup = result.firstIndex(where: { abs(Float($0.value) - mmF) / mmF < 0.06 }) {
                if cand.isNative && !result[dup].isNative {
                    result[dup] = FocalLengthOption(cand.mm, isNative: true)
                }
                continue
            }
            result.append(FocalLengthOption(cand.mm, isNative: cand.isNative))
        }
        return result.sorted { $0.value < $1.value }
    }
}
