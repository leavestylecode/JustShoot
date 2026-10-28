# Kodak Library 封面优化 — 2026-10-25

范围为 Library 全部 147 张 Kodak 收藏卡：145 张独立重绘，2 张同款、同规格 Portra 400 使用此前已确认的拍摄封面。保留不同年代、规格和包装版本的独立收藏条目。

## 包装与样式依据

每张使用 [Film Packaging Archive](https://github.com/dekuNukem/Film-Packaging) 对应编号的真实包装扫描，结合 App 已确认的 Portra 400、Velvia、Provia 封面规范。当前系列也参考 [Kodak Professional 胶片目录](https://www.kodakprofessional.com/photographers/film)。这些是适配 App 的生成式包装插画；不是官方提供的数字封面。147 张原始扫描的 URL、文件路径、SHA256 与归档版本记录在 [packaging-references.json](packaging-references.json)。

- 以原包装对应版本为准：Portra 紫色、UltraMax 蓝色、Ektar 酒红、Tri-X 绿色、TMAX 的灰黑或紫色元素，以及复古 Eastman 的奶油纸与牛皮纸；真实使用黄色的版本仍保留 Kodak 黄。
- 保留年代字体、色块、条纹和型号特征，通过平面印刷质感、边距、品牌区及文字层级形成整体联系。
- 胶片型号优先，规格、张数与工艺置于小号页脚。避免重复品牌、立体字、金属浮雕和无依据的装饰图标。
- 方形满版，圆角由 App 呈现；不含 JustShoot、RAW、sRGB 或拍摄链路文字。

两张精确复用：00200_000（2014 Portra 400，35mm 36exp）和 00244_000（2024 同款包装，35mm 36exp）。2026 蓝紫色新版 00245_000、120 规格 00246_000 以及其他 Portra 版本分别制作。

## 审阅与预览

逐张检查 7 页完整总览，并对 147 张进行 OCR 辅助检查。26 个自动提示经过人工视觉复核；旋转字、轮廓字体和相似字符存在 OCR 误读，未据此自动修改型号。22 张做局部回修，主要涉及重复 Kodak 标识、过大的规格或包装数量，以及不符合平面印刷的字形效果。原始评审与修改理由见 [review-notes.json](review-notes.json)，实际回修提示词和选用文件见 [refinements.json](refinements.json)。

![Kodak 代表款](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/representative-after.jpg)

- [代表款前后对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/representative-before-after.jpg)
- [Kodak / Fujifilm 混排](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/kodak-fuji-harmony.jpg)
- [110px 小尺寸检查](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/representative-110px.jpg)
- 全部 147 张：[第 1 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-1.jpg)、[第 2 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-2.jpg)、[第 3 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-3.jpg)、[第 4 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-4.jpg)、[第 5 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-5.jpg)、[第 6 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-6.jpg)、[第 7 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/after-page-7.jpg)。

## 生成记录

使用内置 `image_gen`，每个不同资产独立调用，没有使用 CLI 或外部 API。完整主提示词、输入角色与资源映射见 [jobs.json](jobs.json)；试稿见 [draft-first-pass.json](draft-first-pass.json)。各资产最终生成源、安装路径、尺寸、色彩空间、字节数和 SHA256 见 [assets.json](assets.json)。

`prepare_assets.py` 仅做 sRGB 转换、缩放、HEIC 编码和审阅排版；没有以程序重画、拼接或修改封面内容。`apply_assets.py` 安装已选文件并审核变更范围，允许安全恢复已安装的资源，但严格核对目录元数据与起始基线，仅接受本轮 Kodak 颜色标签变更和单独记录的并行变更。

## 接入与验证

完成日期：2026-10-26。147 张封面已写入 `JustShoot/Resources/cards/`，全部为 1024 × 1024 HEIC，带 sRGB ICC；145 张独立生成、2 张精确复用已确认封面。53 个颜色筛选标签已按实际封面主色同步。目录仍为 550 条，Kodak 147 条；ID、顺序、图像绑定和其他元数据保持原值。详情见 [asset-validation.json](asset-validation.json)。

封面合计 19,644,157 字节，相比原资源 4,796,544 字节增加约 14.16 MiB。保留原有按需缩略图与缓存流程；本轮不声称真机性能提升。相对本轮起始基线，应用内改动为 147 个 Kodak 数字编号封面和 `cards.json`。独立发生的 `Localizable.xcstrings` 变化已原样保留并单独记录在 [concurrent-changes.json](concurrent-changes.json)；其余应用文件与起始基线一致。

使用 XcodeBuildMCP，显式设置 `JustShoot.xcodeproj` / `JustShoot` / Debug / iPhone 17（iOS 26.4.1，`06CBF94A-F235-4319-A5F9-3548DDC86AD2`）完成：

- 构建、安装和启动成功，无新增警告。
- 18 项聚焦测试全部通过：CatalogIndex 4、ImageCache 6、PresetCoverPreparation 6、PresetCatalog 2；0 失败、0 跳过。
- 模拟器检查列表顶部、底部、Ektachrome E100 详情和颜色筛选：Kodak 共 147 条；Kodak + Blue 共 5 条，与目录一致；检查后恢复完整 Kodak 列表。
- 逐张离线审阅全部 147 张封面，复核 22 张局部回修，并核验所有安装文件与最终选稿的 SHA256、尺寸和 ICC。

运行日志、结果包与检查记录见 [runtime-validation.json](runtime-validation.json)。本轮未用 iPhone Happy 进行真机性能或 RAW 拍摄验证。

[列表顶部](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/library-top.jpg) · [列表底部](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/library-bottom.jpg) · [颜色筛选](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/library-blue-filter.jpg) · [E100 详情](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/kodak-library-refresh-2026-10-25/library-detail-e100.jpg)
