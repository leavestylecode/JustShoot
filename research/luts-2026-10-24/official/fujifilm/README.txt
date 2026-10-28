FUJIFILM 官方 LUT 原包 — 2026-10-24 获取

来源与版本
官网：https://www.fujifilm-x.com/global/support/download/lut/
相机：GFX ETERNA 55；包版本 Ver.1.10；官网更新日期 2026-04-16。
官方下载：https://dl.fujifilm-x.com/support/lut/gfx-eterna-55-3d-lut-v110.zip
ZIP SHA-256：febfc7050999620651ca0cf162bf8b499970ef270b4da632765b61b958cf7940
包内单个 PROVIA 表仍标 Version:1.00；不能把包版本写成单表版本。

文件
gfx-eterna-55-3d-lut-v110.zip：官网原始 ZIP，未修改。
extracted/gfx-eterna-55-3d-lut-v110/：原样解压，保留 33Grid / 65Grid 和官方 PDF。
downloads.json：各下载文件的官方 URL、大小、SHA-256。
inventory.json：全部 62 个包内文件的哈希与各 LUT 表头、维度、行数、数值范围。
FUJIFILM_IDT_F-Log2C_Ver.1.10.ctl.zip：官方 F-Log2 C 到 ACES 的 IDT 原包，另已解压。
F-Log2C_DataSheet_E_Ver.1.0.pdf：官方编码及色域数据。
GFX_ETERNA_WhitePaper_260206_v101.pdf：官方色彩流程和胶片模拟说明。
仅排除 ZIP 中的 __MACOSX 元数据；实际文件内容均与 ZIP 字节一致。

实际内容
56 个 .cube，33³ 与 65³ 各 28 个；65³ 是作者原生提供的表，并非本项目放大插值。
F-Log2 / F-Log2 C 各含以下 10 种模拟，另有 WDR-709 和 Log-709 基础转换：
PROVIA、Velvia、ASTIA、CLASSIC CHROME、REALA ACE、PRO Neg. Std、CLASSIC Neg.、
ETERNA、ETERNA BLEACH BYPASS、ACROS。
F-Log 目录含 ETERNA、ETERNA BLEACH BYPASS、WDR-709、FLog-709。
这份官方包没有 C200 或 Pro 400H；PRO Neg. Std 也不能改名当作 Pro 400H。

PROVIA 原始 65³ 表
extracted/gfx-eterna-55-3d-lut-v110/65Grid/F-Log2/FLog2_to_PROVIA_65grid_V.1.00.cube
输入 F-Log2 / F-Gamut；输出 PROVIA / ITU-R BT.709。
SHA-256：322d1fc83072ebd4ba73287f32b88bf7fc71582ea03da459fa976a3eb6cdc68f
extracted/gfx-eterna-55-3d-lut-v110/65Grid/F-Log2C/FLog2C_to_PROVIA_65grid_V.1.00.cube
输入 F-Log2 C / F-Gamut C；输出 PROVIA / ITU-R BT.709。
SHA-256：a1fb0cb782aee11c7028003f74bc13a38e670fd604afc75081cfb3afe21a5a95

接入项目的边界
当前 FilmImagePipeline.swift 的 CIColorCubeWithColorSpace 使用编码 sRGB。
官方 Log 输入表不能直接覆盖现有 sRGB 表；必须显式处理传递函数、色域与输出编码。
官方白皮书第 13 页建议查看环境 Rec.709 / D65 / Gamma 2.2。
将已处理 sRGB 照片解码成线性并编码为 F-Log2，只能建立带假设的适配流程，
无法还原 iPhone 先前的曝光、局部影调和色彩处理，也不能宣称与富士机内成片一致。
PROVIA 是官方数码胶片模拟名称，不能仅凭名称视为 Provia 100F 实体胶片测量模型。
官方介绍：https://www.fujifilm-x.com/global/products/film-simulation/provia/
本次只获取、解压和核验官方原文件；App 中现有三款 Fuji 资源未被本次操作覆盖。

核验
ZIP CRC 全部通过；56 表均行数匹配、数值有限、输出在 [0,1]；原表头和内容未修改。
这些检查证明文件完整性和格式有效，不证明适配当前输入后的视觉优劣。

后续派生转换
根据用户明确的 RAW → LUT → sRGB 目标，已另生成 10 款自包含转换版：
../../derived/apple-raw-fujifilm/
输入固定为 RAW 显影后的场景线性 Rec.2020 / D65 RGB；输出为编码 sRGB。
传递函数已离线烘焙进查找表，运行时不需要独立 F-Log2 转换阶段。
派生文件以 CLF 保存并通过数值对照；原始官方文件未改动，App RAW 流程尚待接入。
