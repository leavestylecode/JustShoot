# 17 款 LUT 肤色与暗部优化 · skin-shadow-v1

本轮根据此前离线评估，给 17 款内置风格加入有限度的肤色颜色修正和暗部层次保留。修正已接入预览与新拍摄成片共用的 LUT 准备流程。原始 LUT 资源保留；自定义上传的颜色表不自动套用这些内置风格参数。

视觉上，C200、400H、Portra 和 Vision3 的暖肤色更收敛；Velvia、Classic Chrome、ASTIA、PROVIA、REALA ACE、Classic Neg.、ACROS 的暗部可见层次有所增加。Portra、400H、Phoenix 的暗部原本已经托起，本轮基本保留。它们仍然是不同的风格，没有强行拉到同一个中性结果。

这是 **SDR 样片的离线优化和渲染回归**。用户目前无法摆拍，本轮没有新增 iPhone RAW/预览配对，也没有测量真机帧率或证明真实胶片的绝对色彩准确度。

## 对比图

所有对比均为 **左：优化前 App 成片；右：优化后 App 成片**。两侧使用同一张输入、曝光、白平衡、颗粒种子和该款光学参数。不是原图与 LUT 效果的比较。两侧均由实际 `FilmImagePipeline.stages.final` 导出，包含光学和颗粒；不借助生成式图像处理。

- [17 款肤色放大对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/refined-lut-scenes-2026-10-25/skin-before-after-all-17.jpg)
- [17 款夜景对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/refined-lut-scenes-2026-10-25/night-before-after-all-17.jpg)
- [17 款日光对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/refined-lut-scenes-2026-10-25/daylight-before-after-all-17.jpg)
- [Velvia 三场景单款对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/refined-lut-scenes-2026-10-25/fujiRawVelvia-before-after.jpg)
- [Portra 400 三场景单款对比](/Users/leavestyle/.codex/visualizations/2026/10/24/01a16dbb-b5d2-78e1-9195-24f14f709b3c/refined-lut-scenes-2026-10-25/kodakPortra400-before-after.jpg)

其余逐款图也保存在同目录，命名为 `<FilmPreset.rawValue>-before-after.jpg`。`before/`、`after/` 各有 51 张原尺寸 PNG，`inputs/` 保留三张输入，`report.json` 记录输入、原始 LUT 和导出的哈希。源照片与导出均未加入 Git 或应用资源。

## 修正范围

`FilmLookRefinement` 在后台准备 LUT 时，按输入 RGB 的颜色和亮度范围平滑计算权重，再烘焙回原维度的颜色表。不会增加每帧图像读回、磁盘访问或 GPU pass。参数集中在 `JustShoot/Resources/FilmLookRefinements.json`，每款单独配置；以后修改参数应同步提升修订号和缓存后缀。

- 肤色附近：适度将输出色度方向拉回输入方向，只收敛部分偏移，保留剩余暖调或冷调；对明显高于输入的色度做有限压缩，并少量补足被压低的明度。
- 暗部：只在 LUT 将低亮度输入压得过低时保留一部分输入层次，平滑退出中间调。不改变输入纯黑对应的输出，也不把所有黑位统一抬灰。原 LUT 已带有的有色黑位继续保留。
- 日光风格：纯黑、白点、测试中的蓝天/绿色和较亮灰阶探针与原表相同。橙色、暖木色等可能进入与肤色相同的颜色区间，仍会有变化；这不是人脸或语义肤色识别。
- ACROS 不应用肤色色相、饱和度或面部明度修正，只增加受压暗部的分离，保持单色。

预览、RAW 显影后的成片、处理图像和 Live Photo 继续使用同一张准备后的 sRGB LUT。新的缓存键包含 `#skin-shadow-v1`，曲线和白平衡随后按原顺序合成。缓存淘汰后可重建，仍使用既有 64 MB 字节预算和取消机制。旧任务读取自己冻结的 LUT 字节；历史无修订后缀资源键仍返回原表。无需数据模型迁移。

## 逐款观察

表中“浅肤色偏角”是合成探针 `[0.78, 0.59, 0.48]` 相对输入的 Lab 色相角差，越接近零代表偏离输入越少，不代表更接近真实胶片。近黑比例取夜景的 **LUT-only** 输出，定义为 RGB 三个通道均不高于 `1/255`；不含颗粒或光学，避免混淆颜色表与后处理。完整成片的指标另见 `metrics.json`。

| 风格 | 浅肤色偏角，前 → 后 | 夜景近黑比例，前 → 后 | 改善与保留 |
| --- | ---: | ---: | --- |
| PROVIA | 6.46° → 3.82° | 22.91% → 0.15% | 暖色更克制、暗建筑有更多层次；保留日光清晰反差 |
| Velvia | 9.74° → 6.59° | 55.58% → 0.10% | 暗部改善最明显的一组；仍浓艳、反差高，欠曝人像仍偏重 |
| ASTIA | 11.85° → 6.65° | 28.92% → 0.10% | 肤色偏黄有所收敛，阴影分离增加；保留柔和色彩 |
| Classic Chrome | 5.80° → 3.83° | 47.59% → 0.10% | 黑暗区域不再大面积完全合并；保留低饱和纪实感 |
| REALA ACE | 7.75° → 4.53° | 33.33% → 0.16% | 肤色暖偏减轻，暗部更可读；保留建筑与色彩的清晰度 |
| PRO Neg. Std | 6.52° → 3.97° | 15.35% → 0.25% | 小幅肤色修正和最暗处层次补足；保留较克制的人像基调 |
| Classic Neg. | 4.39° → 3.06° | 34.66% → 0.16% | 原肤色已较接近输入，因此修正较轻；保留明暖暗沉的分离 |
| ETERNA | 10.14° → 6.23° | 5.29% → 1.16% | 肤色偏移收敛，夜景主要补最底部；柔和低反差不变 |
| ETERNA Bleach Bypass | 8.31° → 6.42° | 19.37% → 0.25% | 暗部轮廓有所保留；仍低饱和、高反差，面部不强行增色 |
| ACROS | 黑白，不评分 | 37.60% → 0.25% | 只改暗部层次；中亮肤色和单色特征保持 |
| C200 | 13.55° → 7.51° | 0% → 0% | 暖肤色和部分过艳橙色收敛；青蓝阴影、复古黑位保持 |
| Pro 400H | 11.72° → 6.77° | 0% → 0% | 肤色暖偏收敛；清透和偏冷的阴影仍在，夜景变化小 |
| Portra 400 | 10.90° → 6.10° | 0% → 0% | 橙黄肤色适度回收；保留温暖、明亮和柔和黑位 |
| Vision3 500T / 5219 | 14.86° → 8.20° | 0% → 0% | 暖肤色改善较明显；夜景仅小幅保留层次，电影反差仍在 |
| Vision3 50D / 5203 | 15.75° → 8.66° | 0% → 0% | 暖偏减轻，最暗处稍有补足；保留日光色彩与影调 |
| Vision3 250D / 5207 | 15.58° → 8.55° | 0% → 0% | 与 50D 类似的有限修正；不夸大二者原本有限的差异 |
| Phoenix 200 | 4.05° → 2.91° | 0% → 0% | 中亮肤色只轻调；保留冷影、雾感和抬黑，夜景几乎不变 |

近黑像素变少不等于恢复了 RAW 信息，也不等于消除了所有压暗。Velvia、Chrome、ACROS 的夜景整体仍暗，只是输入中已有的轮廓少被 LUT 压成一块。Portra 等原本已无近黑像素的款式，其黑位也没有因此被当作错误消除。

深色合成探针仍有残余压暗和偏移；个别中间探针的 Lab 偏角也不保证每个都改善。16 款彩色风格在两个中亮肤色探针上的 Y′CbCr 方向偏移均减少，且保留至少 30% 的原偏移；这只是有限的回归约束，不是覆盖所有人物与光线的肤色准确性认证。原表细小灰阶起伏未恶化：十款 Fuji 灰阶累计最大回落仍为零，其余原有回落不超过约 0.00134。

## 验证

- iPhone 17 模拟器，iOS 26.4.1，Debug：**430 通过、0 失败、3 跳过，无新增警告**。跳过项仍为模拟器 Photos 授权、物理相机选测、未提供的外部 ProRAW 样本。
- 新增 7 个回归测试：102 个独立 Python 双精度参考探针、边界/代表色保护、肤色偏移约束、暗部分离、ACROS 单色、缓存淘汰与曲线重建、自定义 LUT 字节保留。
- 17 款 × 三张合成压力图与三张真实 SDR 图，共 102 次整图 Metal/CI 调色阶段检查，另以每图 257 个 CPU 三线性插值探针交叉核对。实际最大误差与日志见 `validation.json`。这隔离了渲染器差异，不能据此宣称相机预览 ISP 和 Apple RAW 显影完全一致。
- 应用已重新构建并在模拟器打开，Film Library 载入正常。17 份原始运行时 LUT 的 SHA-256 与本轮之前评估一致。原有本地化条目保持原样。图片导出不入 Git。

没有测量新修正的真机准备时延或帧率，不声称设备性能提高。新增工作发生于后台 LUT 准备，预览继续执行原有查表渲染。完整结果、配置哈希、源图哈希、各款指标和检查记录分别见 `metrics.json` 与 `validation.json`。

## 样本边界与下一步

实际人像仍只有 NASA Eileen Collins 一位浅肤色人物，另外四个不同明度 RGB 探针不是实测肤色反射率。日光图是已带 EKTACHROME 64 Pro/扫描影调的 Kodak Image 19，夜景是已显影的台北街景 JPEG。不能用这批 SDR 图证明 RAW 极暗部或高光能够恢复，也不能证明 Fuji 派生 LUT 与富士机身处理逐像素相同。

后续条件允许时，应补不同肤色、日光/室内/混合照明和夜景的中性参照与锁定机位配对，检查 Apple 视频预览与 ProRAW 显影的输入差异，再判断是否需要输入层校准。

来源和处理方式沿用此前评估：

- [NASA / scikit-image astronaut](https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut)
- [Kodak Image 19 / Alan Fink](https://r0k.us/graphics/kodak/kodim19.html)
- [2011-03-11 night in Taipei / ╬ಠ益ಠ) / CC0](https://commons.wikimedia.org/wiki/File:2011-03-11_night_in_Taipei.jpg)

## 复现

先使用 `scripts/refine_film_looks.py --output <临时目录> --swift-reference JustShootTests/FilmLookRefinementReference.swift` 生成独立参考。Python 环境依赖版本记录在 `metrics.json`。

用 XcodeBuildMCP `test_sim`，默认项目 `JustShoot.xcodeproj`、scheme `JustShoot`、Debug、iPhone 17 / iOS 26.4.1，设置：

```text
JUSTSHOOT_SCENE_FIXTURES=<对比图目录>/inputs
JUSTSHOOT_SCENE_EXPORT=<优化后 PNG 目录>
JUSTSHOOT_SCENE_BEFORE_EXPORT=<优化前 PNG 目录>
```

再运行：

```sh
python scripts/compare_film_refinement.py \
  --before <优化前 PNG 目录> --after <优化后 PNG 目录> \
  --inputs <对比图目录>/inputs --output <新的对比图目录>
```

脚本不联网，不修改源 LUT，不另行拟合每张照片的曝光或白平衡。
