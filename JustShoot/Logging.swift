import Foundation
import os

// MARK: - 统一日志系统
//
// 用法：
//   Log.capture.info("shutter_tap preset=\(name)")
//   let t = Log.perf("lut_apply", logger: Log.lut); ...; t.end("size=\(bytes)")
//
// 过滤（Xcode Console / Terminal）:
//   log stream --predicate 'subsystem == "com.leavestylecode.JustShoot"'
//   log stream --predicate 'subsystem == "com.leavestylecode.JustShoot" && category == "camera.capture"'
//
// 事件命名约定：snake_case，参数用 key=value，时间单位 ms。
enum Log {
    static let subsystem = "com.leavestylecode.JustShoot"

    static let session     = Logger(subsystem: subsystem, category: "camera.session")
    static let capture     = Logger(subsystem: subsystem, category: "camera.capture")
    static let orientation = Logger(subsystem: subsystem, category: "camera.orient")
    static let gps         = Logger(subsystem: subsystem, category: "camera.gps")
    static let lut         = Logger(subsystem: subsystem, category: "photo.lut")
    static let save        = Logger(subsystem: subsystem, category: "photo.save")
    static let gallery     = Logger(subsystem: subsystem, category: "gallery")
    static let ui          = Logger(subsystem: subsystem, category: "ui")

    /// 测量代码段耗时
    struct PerfTimer {
        let label: String
        let logger: Logger
        let start: CFAbsoluteTime

        func end(_ extra: String = "") {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let suffix = extra.isEmpty ? "" : " \(extra)"
            logger.info("⏱ \(label) took=\(String(format: "%.1f", ms))ms\(suffix)")
        }
    }

    static func perf(_ label: String, logger: Logger) -> PerfTimer {
        PerfTimer(label: label, logger: logger, start: CFAbsoluteTimeGetCurrent())
    }

    /// 当前高精度时间（秒），用于跨回调的时差测量
    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    static func ms(since t0: CFAbsoluteTime) -> String {
        String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
    }
}
