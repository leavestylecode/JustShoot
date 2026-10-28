富士官方 LUT → Apple RAW 显影输出 → sRGB

目标
运行时接口：RAW/DNG → 统一显影 → 本转换版 LUT → sRGB 成片。
输入色域与传递函数适配已封装在 LUT 内，无独立 F-Log2 阶段或中间图像。
F-Log2 仅作为生成输入查找表的离线数学依据，没有从处理链中丢弃必要的映射关系。
这是本项目派生的适配文件；不是富士直接发布的 Apple RAW 版本。

文件
10 个 Fuji*_AppleRAW_LinearRec2020_to_sRGB.clf 对应 PROVIA、Velvia、ASTIA、
CLASSIC CHROME、REALA ACE、PRO Neg. Std、CLASSIC Neg.、ETERNA、ETERNA BB、ACROS。
manifest.json 包含原包/原表/转换版哈希、输入输出契约和逐款数值验证。
这份官方包仍没有 C200 和 Pro 400H；PROVIA 是官方数码胶片模拟名称。

固定输入契约
Apple RAW / ProRAW 需先用 CIRAWFilter 解码、去马赛克（如适用）、白平衡和相机色彩校正。
按 DNG 自带中性点确定白平衡；不能统一强制 6500 K。
统一到场景线性 Rec.2020 / D65 浮点 RGB；18% 灰在显式曝光归一后为 RGB 0.18。
关闭默认影调外观：baselineExposure=0、shadowBias=0、boostAmount=0、
localToneMapAmount=0、isGamutMappingEnabled=false，exposure=0。
这里将曝光归一交给显式步骤；不能假设所有设备/镜头的 DNG 尺度天然一致。
保留负值及大于 1 的高光到 LUT 输入；不可先裁切或量化成 8 位。
当前选择的线性 Rec.2020 原色与官方 F-Gamut 相同，无需额外色域矩阵。
不能把 Bayer 传感器马赛克数据、带默认外观的 ProRAW 成片、sRGB 照片直接当作此输入。

转换文件结构
CLF 3.0 自包含：
1. halfDomain 1D 输入查找表：65536 个半浮点位模式对应的预计算结果。
2. 富士作者原生 65³ 色表：所有源节点原样保留，使用三线性插值，不重采样。
3. halfDomain 1D 输出查找表：参考观看环境 Gamma 2.2 转 sRGB 编码。
没有 Log、外部文件引用或运行时所需的 F-Log2 公式节点；曲线值已全部烘焙。
1D halfDomain 使输入不受普通 0–1 cube 范围限制，并保留暗部采样精度。
超出官方输入有效范围的值按原表域边界裁切；没有额外声称可恢复传感器过曝。
CLF 规范：https://docs.acescentral.com/clf/specification/

输出定义与假设
富士原表声明 BT.709 原色，白皮书第 13 页建议 Gamma 2.2 / D65 显示环境。
据此将原表结果按 power 2.2 解码，再按标准 sRGB 分段曲线编码。
这是明确记录的参考观看假设；原表头未单独声明完整输出 EOTF。
最终 HEIF/JPEG 必须写入 sRGB 色彩标记；色表输出不能被当作线性 RGB 再重复编码。

当前接入状态
这些文件是转换验证成果，尚未替换 JustShoot/Resources 中现用的 sRGB 输入 LUT。
项目还没有 RAW 采集/统一显影，新渲染器也还没有读取此复合 LUT 的能力。
现有 CubeLUT/FilmImagePipeline 只支持单张 unit-domain cube 和相同输入输出色彩空间；
不能把这些 CLF 改扩展名为 .cube 或直接导入当前流程。
实际接入可把三个查表阶段作为一个 GPU 渲染步骤，输入曝光归一放在查表之前。
需真机 DNG 验证白平衡、曝光尺度、高光、元数据和成片色彩；目前没有这类样本。

验证与复现
每款 22542 组 Float32 输入：随机颜色、多档曝光、密集灰阶、负值和 HDR 高光。
NumPy 独立计算原表链路，与 OpenColorIO 读取序列化 CLF 后的结果逐点比较。
10 款最坏绝对 RGB 误差小于 0.0000013；原始官方节点没有重采样。
误差衡量转换精度，不证明 iPhone 与富士相机完全一致，也不证明视觉上优于旧 LUT。
python -m pip install -r scripts/fujifilm-raw-lut-requirements.txt
python scripts/bake_fujifilm_raw_luts.py --modes PROVIA Velvia ASTIA CLASSIC-CHROME REALA-ACE PRO-Neg.Std CLASSIC-Neg. ETERNA ETERNA-BB ACROS
生成器固定官方原包 SHA-256，输出 manifest.json 记录版本、参数和文件哈希。
本次没有修改 App 拍摄/渲染代码，因此未运行新的模拟器构建或真机性能测试。
