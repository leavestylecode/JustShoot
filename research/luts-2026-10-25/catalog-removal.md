# 内置 LUT 精简 · 2026-10-25

按用户要求，从新拍摄的可选预设中移除以下 8 款：ETERNA、ETERNA Bleach Bypass、PRO Neg. Std、REALA ACE、Kodak Vision3 500T / 5219、50D / 5203、250D / 5207、Harman Phoenix 200。

剩余 9 款：PROVIA、Velvia、ASTIA、Classic Chrome、Classic Neg.、ACROS、Fuji C200、Fuji Pro 400H、Kodak Portra 400。保留款的源 LUT 哈希、肤色/暗部修正参数、颗粒和光学参数不变。

## 清理范围

- 删除 `FilmPreset` 与 `FujifilmSimulation` 对应枚举项，首页、相机切换和封面预热统一随 `allCases` 更新。
- 删除 16 个内置 `.cube` / `.jslut` / `.jsraw` 文件，共 54,129,241 字节；同步清理来源清单、验证清单和修正参数。
- 社区导出、Fuji 转换/编译与离线检查脚本默认仅覆盖保留款，避免再次生成已移除资源。对照总览的标题、行数和文件名随预设数变化。
- 测试中的光学、取消和高光保护夹具改用保留的风格或直接构造参数；独立双精度参考更新为 9 款 × 6 探针。

## 上架前清理

用户确认产品尚未上架，本次精简无需兼容已有照片或已导入的自定义 LUT。删除已移除胶片的历史名称映射和专用兼容测试，任务恢复夹具使用仍在目录中的 PROVIA。运行时代码不再引用这 8 个已删除的预设标识。

自定义 LUT 导入与新拍摄的可靠保存/恢复仍属于产品功能，继续保留；本次不执行数据清空或迁移。胶片包装收藏库是独立资料，不随可拍摄 LUT 的精简而删除。

移除前的 LUT 文件与 SHA-256 清单另存于工作区外，便于恢复：

`/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/removed-luts-2026-10-25/`

此前 17 款离线评估和对比图保留为历史记录。当前目录及本轮验证记录见 `catalog-removal-validation.json`。

## 验证

- iPhone 17 / iOS 26.4.1 模拟器：432 项通过、0 失败、3 项条件跳过；构建及测试无新增警告。
- 实际启动后检查 Films 页：9 款内置预设，已移除的 8 款不在列表，自定义导入入口与已有测试滤镜均保留。
- 54 组同输入预览/成片查表回归通过；本轮未进行新的真机配对拍摄。

上述 432 项为第一次移除后的完整回归记录。上架前兼容清理的追加验证见 `catalog-removal-validation.json` 的 `preReleaseCleanup`。

追加验证：目录和 RAW 管线测试 15 项通过、0 失败，1 项因未提供可选外部 ProRAW 样本跳过；构建/启动通过，未新增警告。重新检查 Films 页，9 款内置预设与导入入口正常。
