# 阶段提交验证 · 2026-10-28

本阶段涵盖统一的 Apple RAW／处理照片／Live Photo 胶片映射、自定义 LUT 色彩空间归一化、肤色与暗部细化、所选 LUT 移除，以及全部胶片封面重制和压缩。

XcodeBuildMCP 使用 `JustShoot.xcodeproj`、scheme `JustShoot`、Debug、iPhone 17 模拟器（iOS 26.4）。构建成功。完整测试发现 434 项，431 项通过、0 失败、3 跳过。跳过项分别需要 Photos 往返环境、物理相机、外部 Apple ProRAW 样本；不能将模拟器结果当作这些项目的真机验证。

559 张正式封面的 SHA-256 和文件大小逐一匹配最终安装清单，合计 54,348,069 字节；550 条 Library 图片绑定唯一且完整，另有 9 张拍摄用封面。除压缩封面外，所有应用文件仍与封面压缩阶段基准一致。临时诊断和尝试过的加载器修改均已移除。`git diff --check` 通过。最终安装包内 559 张封面再次逐一匹配清单；模拟器 Library 混合品牌网格目视检查正常，见 `bundle-resource-check.json`。

## 未通过的性能检查

完整测试报告 1 条内部 QoS 等待警告，涉及 HEIF 解码。独立运行 6 项封面缓存测试时未报告该警告；已提交基线的完整测试为 395 通过、0 失败、1 跳过，无该警告。未将新警告当作通过。

实际诊断确认封面解码发生在后台 `BlockingImageWork` 有界 OperationQueue，而非主线程。系统共享缓存栈定位到 `CGImageSourceCreateThumbnailAtIndex` → ImageIO HEIF reader → CMPhoto 缩放／解码内部同步等待。符号化仅保留系统共享缓存地址，未将不同进程的应用 ASLR 地址当作可靠符号。详细证据见 `performance-validation.json`。

该 SDK 内部提示仍待物理设备复核。本阶段保留既有后台解码和缓存机制，不禁用检查器、不修改已确认封面画质，也不宣称获得真机速度或内存改善。这是保留已验证功能与已知限制的本地阶段提交，不是发布验收。

`final-tests.json`、`build-validation.json` 保存实际工具结果；`validation.json` 汇总提交范围和资源检查。原始下载、实拍样本、生成图片和缓存留在本机，不纳入提交。
