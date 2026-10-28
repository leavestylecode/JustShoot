# Fujifilm Library 封面重构 — 2026-10-25

已替换 Library 全部 72 张 Fujifilm 收藏卡封面：67 张本轮独立生成，5 张使用此前已确认的同款、同规格封面。保留 72 个收藏条目及各年代包装差异。

## 设计依据

逐张使用 [Film Packaging Archive](https://github.com/dekuNukem/Film-Packaging) 对应编号的真实包装扫描，并结合项目已确认的拍摄封面样式重绘。它们是适配 App 的生成式封面插画，不是官方提供的数字封面。原始扫描、来源地址和归档树 SHA 见 [packaging-references.json](packaging-references.json)。

- 保留各系列和年代的字体特征、条纹、色块、型号、ISO 和规格；没有把同名胶片不同包装全部合并。
- 蓝金色用于 Provia / Velvia，紫红色用于 C200 / 部分 Superia，黑金色用于 Reala，浅色彩虹用于 Natura，黑灰与红色斜线用于 Neopan；以实物包装对应版本为依据。
- 通过品牌区、纸面印刷质感、文字层级和边距形成联系，避免所有卡都被绿色主体占据。
- 不含 JustShoot、RAW、sRGB、拍摄链路说明、虚构口号或外部投影；保留方形边界，圆角由 App 绘制。
- 逐张检查 12 组生成预览和 3 页完整总览。针对 64T 批量装的文字层级、Superia 200 缺少醒目型号的问题做了单独回修。

5 张既有封面的精确复用：00022_000 Pro 400H 120、00044_000 Velvia 50 35mm、00055_000 Provia 100F 35mm、00202_000 C200 35mm 36exp、00524_000 Acros 100 II 35mm。其余版本独立制作。

## 预览

![代表款新版封面](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/representative-after.jpg)

- [代表款前后对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/representative-before-after.jpg)
- 全部 72 张：[第 1 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/after-page-1.jpg)、[第 2 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/after-page-2.jpg)、[第 3 页](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/after-page-3.jpg)
- 模拟器：[顶部](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/library-top.jpg)、[中段](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/library-middle.jpg)、[底部](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/library-bottom.jpg)、[64T 详情](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/library-detail-64t.jpg)、[蓝色筛选](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/fujifilm-library-refresh-2026-10-25/library-blue-filter.jpg)。

## 接入及验证

最终资源已覆盖 `JustShoot/Resources/cards/` 中对应的 72 个数字编号 HEIC，逐张完整路径、SHA256、生成源文件及复用关系见 [assets.json](assets.json)。全部为 1024 × 1024、内嵌 sRGB ICC；由生成 PNG 仅做色彩转换、缩放和 HEIC 编码，没有程序化重画或拼接封面。

`cards.json` 仅更新这 72 张卡的主色分类，沿用项目既有 `dominant_color` 算法。56 个主色标签改变；新版分布为白 19、绿 14、蓝 13、紫 13、黑 5、红 4、灰 4。原先绿 68、白 3、黑 1。全部 550 个目录条目的 ID、顺序、图像绑定和其他元数据保持一致。

与本轮开始时逐文件哈希相比，App 内仅 72 个目标图片和 `cards.json` 改变；其余 478 张收藏封面、9 张拍摄封面、LUT 和 Swift 文件均一致。资源总量从 2,505,062 字节增至 10,083,827 字节，增加约 7.23 MiB。保留现有按显示尺寸降采样及有界缓存流程；未测量或声称真机性能提升。

验证使用 XcodeBuildMCP，项目 `JustShoot.xcodeproj`、scheme `JustShoot`、Debug、iPhone 17 模拟器（iOS 26.4.1）：

- Build & Run 成功，无新增构建警告。
- 18 项测试通过：FilmCardCatalogIndexTests 4、FilmCardImageCacheTests 6、FilmPresetCoverPreparationTests 6、FilmPresetCatalogTests 2。
- 实际检查 Library 顶部、中段、底部、64T 120 详情和筛选：Fujifilm 72 张；Fujifilm + 蓝色 13 张，数量与元数据一致。
- 所有 72 张资源已完成解码、尺寸、ICC、唯一条目映射和变更范围检查。

详见 [asset-validation.json](asset-validation.json) 和 [runtime-validation.json](runtime-validation.json)。本次是封面和目录颜色标签调整，没有改变 RAW / LUT 拍摄流程。

## 生成方式与复现记录

使用内置 `image_gen`，每个不同资产独立调用。没有使用 CLI 或外部 API。完整提示词与各输入角色、最终资源路径在 [jobs.json](jobs.json)；两次定向回修提示词在 [refinements.json](refinements.json)。初稿和最终选用结果分别保留记录，连接失败的两张已重试成功。

`prepare_assets.py` 负责已选资源的编码与审阅排版；`apply_assets.py` 安装资源并审计边界。后者刻意要求目录仍与本轮基线一致，已经应用后不要直接重复运行。原封面备份、原包装参考和最终 PNG / HEIC 审阅稿保存在本报告链接指向的可视化目录。
