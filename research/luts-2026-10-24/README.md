# JustShoot LUT 分析与 Portra 400 候选

> 历史记录：本文描述替换前状态。八款 LUT 现已全部替换；当前结论、选型与验证见 [REPLACEMENT.txt](REPLACEMENT.txt) 和 [VERIFICATION.txt](VERIFICATION.txt)。

日期：2026-10-24。范围：8 个内置 `.cube`、对应二进制资源、加载和渲染代码，以及公开的胶片模拟来源。未更换 App 内置 LUT，未修改 Swift 渲染代码。

**结论：当前资源可以作为创意滤镜使用，但仓库中的证据不足以把它们认定为经过标定的胶片模拟。已经生成来源、参数和许可可追溯的 Portra 400 候选；没有实拍参考，不能称其中任何一份为“最准确”或“最好”。**

## 当前资源的证据

| 检查项 | 结果 | 含义 |
| --- | --- | --- |
| 格式和行数 | 全部 25³，各 15,625 个 RGB 节点，数值有限且在 0–1 内 | 格式完整，未发现文件截断；25³ 本身不代表质量差 |
| 节点精度 | 所有通道均落在 1/255 网格上，最大偏离约 4.91×10⁻⁷ | 有明显 8 位量化痕迹；可能来自图像式 LUT 导出，但具体源图和流程未知 |
| 来源说明 | 全部文件头仅写 IWLTBAP LUT Generator；没有原作者、胶片测量、扫描器、输入输出色彩空间或许可记录 | 导出工具不是胶片精度认证，也不能据此认定 LUT 作者就是 IWLTBAP |
| Portra 400 标题 | 非 UTF-8 字节按 GB18030 解码得到 `TITLE "偏黄"` | 名称与文件名不同，提示元数据不足；不能单凭标题判断颜色准确性 |
| 灰阶单调性 | C200 有 1 处、Vision 5203 有 2 处加权 RGB 灰阶倒退 | 5203 最严重一步约 −0.05659，输入更亮反而输出更暗，应优先排查 |
| 二进制资源 | `python3 scripts/compile_luts.py --check`：8/8 一致 | 当前问题不是 `.cube` 与 `.jslut` 版本不同 |

这里的“加权 RGB”是编码 sRGB 数值按 0.2126 / 0.7152 / 0.0722 加权，**不是线性光亮度**。灰阶倒退是诊断信号，不是胶片准确率评分。8 位节点经过三线性插值仍然可以产生连续输出，不能直接等同于成片只有 8 位或必然出现色带；把网格插值放大也不能恢复已经丢失的源精度。

当前 Portra 原始 LUT 将纯黑映射到 `(0, 0.019608, 0.031373)`，纯白映射到 `(0.901961, 0.917647, 0.929412)`，灰轴存在明显色偏。色偏和压白可以是创作选择，是否符合 Portra 必须有约定的冲扫参考。

完整节点统计和 SHA-256 见 [audit.json](audit.json)。

![原始 LUT 数值对比](lut-analysis.png)

图只展示原始文件，不包含 App 的色温响应、影调校正、光学模块和颗粒。曲线更平滑不等于更像胶片。

## 实际成片还经过哪些处理

当前代码里的顺序大致为：

`相机处理后的 HEIF/JPEG → 色温/白平衡相关处理 → LUT → 用户曲线 → 高光肩部、halation/bloom → grain → 编码`

其中，内置 LUT 在加载时还会先经历：

1. `FilmProcessor.applyingShadowToe`：所有内置 LUT 的暗部逐通道抬升，阈值 0.16、强度 0.22。
2. `FilmLUTCalibration`：Portra 400 和 Pro 400H 再叠加手工亮度曲线，低维表提升到至少 33³。

因此，直接下载“更专业”的 LUT 然后覆盖原文件，会继续叠加旧的修正，无法独立评估新模型。后续接入应给候选独立标识和处理配方，先比较原始 LUT，再逐个启用其它模块。历史待处理拍摄任务保存的配方和 LUT 快照也要保持可回放。

`FilmImagePipeline` 用 sRGB 色彩空间解释 LUT。色域、传递函数和场景/显示参照需要分别匹配：Rec.709 Gamma 2.4、Apple Log、LogC、线性 RGB LUT 都不能仅凭 `.cube` 扩展名直接套入。相机当前拍摄的是处理后的 HEIF/JPEG；逆 sRGB 曲线不能撤销苹果已经做过的局部影调、锐化或高光处理。

## 已获取并生成的候选

使用 [Spectral Film LUT](https://github.com/JanLohse/spectral_film_lut)，固定提交 `bcbcfc6861f49cc706dc5d00ea048e4853060aab`（提交日期 2026-10-15）。它从厂家数据表数字化数据构建光谱、负片和相纸模型；作者明确承认公开数据精度、层间作用等方面的局限。这比来源不明的命名 LUT 更可追溯，仍不是实拍标定的替代品。

输入为编码 sRGB，模型内部解码；输出采用 Rec.709/sRGB 共用的原色和 **sRGB 传递函数**。负片模型为 2010 版 Portra 400，曝光补偿 0，色温参数 6500 K，color masking 1，保留真实相纸曲线，无额外阴影、饱和度或颗粒调整。参数是研究起点，没有针对 iPhone 相机完成标定。

| 文件 | 用途 | RGBA Float32 表内存 | 与原模型的 ΔE00：中位数 / P95 / 最大 |
| --- | --- | --- | --- |
| [Portra Endura 33³](candidates/Portra400_PortraEndura_sRGB_33.cube) | 负片 + Portra Endura 相纸，优先进行视觉比较 | 0.55 MiB | 0.065 / 0.373 / 3.155 |
| [Portra Endura 65³](candidates/Portra400_PortraEndura_sRGB_65.cube) | 同配方高精度参考 | 4.19 MiB | 0.019 / 0.125 / 1.017 |
| [Endura Premier 33³](candidates/Portra400_EnduraPremier_sRGB_33.cube) | 同负片、另一相纸解释 | 0.55 MiB | 0.075 / 0.477 / 3.156 |

误差使用独立于导出器的三线性插值，对比 2,048 个固定随机 RGB 和 1,025 个灰阶输入上的**未烘焙数学模型**，并非与真实胶片比较。65³ 的精度改善可测，但表内存约为 33³ 的 7.64 倍；没有测量设备性能，不据此宣称真机更快或更慢。纸张选择带来的影调差异远大于这些中位插值误差。

三份候选的维度、数据量、范围、有限性、RGB 节点顺序和序列化均已检查，灰轴无上述亮度倒退。来源 MIT 许可全文随文件保存在 [SpectralFilmLUT-LICENSE.txt](candidates/SpectralFilmLUT-LICENSE.txt)；每份 LUT 带来源和生成说明。完整配方、版本、哈希和误差见 [manifest.json](candidates/manifest.json)。这些检查尚未覆盖 App 内导入、预览、静态照片或 Live Photo，也没有真机胶片对照。

## 如何选到适合这个项目的版本

Portra 是负片，成片还取决于曝光、冲洗、扫描或相纸、白平衡和操作员的解释。先选明确目标，例如“Portra 400 正常 C-41 + 指定扫描流程”或“Portra 400 + Portra Endura 光学印相”；不能把所有网上 Portra 照片当成同一个标准。

建议的验证步骤：

1. 用同一批 iPhone 原片比较当前版本和两种相纸候选；先关闭其它风格处理，固定曝光与白平衡。场景包含多种肤色、绿叶、天空、红色、灰阶、逆光和室内混合光。
2. 若追求真实还原，用真实 Portra 400 与 iPhone 同场拍摄，保留正常曝光及 ±1/±2 EV，记录光源、冲洗、扫描设备和校色操作。不能用不同场景的网图做精度验证。
3. 在约定白点和曝光对齐规则后，观察肤色、灰阶、高光层次与色相连续性。只有有受控参考时才把色差作为准确度证据，避免用“像素越接近越好”抹掉胶片本身特征。
4. 选择目标后再处理相机输入适配和其它模块；把固定颜色变换离线烘焙进 LUT，复用现有后台准备与缓存，不在实时预览运行 Python 或完整光谱模型。颗粒、halation、bloom 仍需要空间处理，不能装进普通 3D LUT。
5. 真机检查预览、静态图和 Live Photo 的颜色一致性、内存与帧耗时。33³ 可先作为运行候选，65³ 作为质量参照；最终取舍依据设备测量。

## 其它值得比较的来源

- [Dehancer 的采样方法](https://www.dehancer.com/learn/articles/how-we-build-film-profiles)：厂商描述了真实介质采样及多曝光档建立 profile 的流程，可以作为商业对照。[功能页](https://www.dehancer.com/features)列出 Portra 400 和 LUT 导出；这不能证明它在本 App 输入上一定最好。导出也不代表获得 App 内再分发权，普通购买前应取得覆盖嵌入用途的明确授权依据，现有公开页面不足以确认。
- [spektrafilm，原 agx-emulsion](https://github.com/andreavolpato/spektrafilm)：可解释的负片、相纸、扫描光谱模型，适合进一步研究。代码和 profile/LUT 的许可分别处理；[profile 与 LUT 许可文件](https://github.com/andreavolpato/spektrafilm/blob/main/SPEKTRAFILM_LICENSE.txt)标示 CC BY-SA 4.0 并要求保留署名及衍生说明。README 还有与许可前言表述不一致的描述，正式分发前应核对固定版本的适用条款。本次没有将它混入 MIT 候选。
- [Kodak Portra 400 官方技术资料](https://imaging.kodakalaris.com/sites/default/files/files/resources/e4050_portra_400.pdf)：用于核对感光与特性曲线，不等于一份可直接还原任意数字相机输入的官方 LUT。

## 复现

在独立 Python 3.12 环境安装 `environment-lock.txt`（本次完整环境）或 `requirements.txt`（核心包版本）。没有安装上游 GUI 包；这里固定的核心环境与上游完整应用依赖清单不同，已验证本次核心生成路径。

```bash
git clone https://github.com/JanLohse/spectral_film_lut.git /tmp/spectral-film-lut
git -C /tmp/spectral-film-lut checkout bcbcfc6861f49cc706dc5d00ea048e4853060aab
python bake_candidates.py --source /tmp/spectral-film-lut
python audit_luts.py
```

脚本默认把结果写到自身所在目录；不改动 App 的 `Resources`。`audit_luts.py` 对身份 LUT 的 512 个随机点进行插值校验，生成脚本用原模型验证导出顺序及离散化误差。本次没有改动 App，未运行 Xcode 构建或声称真机验证。
