# 封面资源压缩 · 2026-10-27

已将 559 张正式封面从 **92,332,039 字节（92.33 MB）**压缩为 **54,348,069 字节（54.35 MB）**，减少 **37,983,970 字节（37.98 MB，41.14%）**。MB 按十进制计算；这是封面文件的体积，不是 App Store 下载包的实测大小。

| 范围 | 数量 | 压缩前 | 压缩后 | 减少 |
| --- | ---: | ---: | ---: | ---: |
| Library | 550 | 91.16 MB | 53.83 MB | 40.95% |
| 拍摄用封面 | 9 | 1.18 MB | 0.52 MB | 55.78% |
| 合计 | 559 | 92.33 MB | 54.35 MB | 41.14% |

## 处理方式与画质

每张封面直接从已确认的 PNG 母版重新编码，避免把旧 HEIC 再压缩一遍。所有正式资源仍为 1024×1024、RGB、sRGB ICC 的 HEIC；文件名、胶片绑定和包装设计保持一致。原来的 559 张 HEIC 已完整备份，552 个唯一 PNG 母版的 SHA-256 也已锁定校验。

使用 pillow-heif / libheif 的 HEVC 编码，4:2:0 色度采样，slower preset，并限制编码并发。逐张从质量参数 45、50、55、58 中选择满足检查条件的较小文件。最终分布为：25 张使用 45、369 张使用 50、164 张使用 55、1 张使用 58。质量参数不是画质百分比。编码接口参见 [pillow-heif 保存文档](https://pillow-heif.readthedocs.io/en/stable/saving-images.html)。

所有 559 张均完整解码验证，并比较压缩前后的整体、底部细字区域和文字边缘。指标使用明确实现的 7×7 均匀窗口亮度 SSIM，以及文字高梯度边缘处 RGB 平均误差；这不是感知质量的绝对保证。384 像素整体 SSIM 最低 0.992002，1024 像素底部区域 SSIM 最低 0.960243，边缘平均误差最大 3.9938 / 255。

实际查看了 5 页、59 组前后对比，覆盖指标异常值、不同纸张与照片纹理、代表性细字，以及全部 9 张拍摄封面。另用 Vision OCR 检查同一批 59 组：压缩前识别 271 行，压缩后 272 行；8 组文字识别差异均放大人工复核，属于艺术字体、重音、空格或相似字符识别变化，未发现可读性下降。OCR 数量本身不代表清晰度。

这是有损压缩。正常封面显示尺寸下，抽查的文字和包装效果保持良好；放大后，极细的纸张颗粒略有平滑。没有重画、替换字体或修改颜色设计。

## 对比与记录

- [整体前后对比](/Users/leavestyle/.codex/visualizations/2026/10/27/justshoot-cover-compression/comparisons/compression-before-after.png)
- [底部细字对比](/Users/leavestyle/.codex/visualizations/2026/10/27/justshoot-cover-compression/comparisons/small-print-before-after.png)
- `inventory.json`：压缩前文件、哈希与母版来源。
- `staged-assets.json`：逐张编码参数、尝试记录、指标与新文件哈希。
- `quality-review.json`、`text-review.json`：实际视觉检查和 OCR 差异处理。
- `installed-assets.json`、`asset-validation.json`：正式安装文件与修改范围校验。
- `runtime-validation.json`、`bundle-resource-check.json`：构建、测试、显示与打包资源验证，完成后写入。

原图备份、候选编码与对比图存放在 `/Users/leavestyle/.codex/visualizations/2026/10/27/justshoot-cover-compression/`，不打入 App。母版路径保留在清单中。本次应用目录修改范围仅为这 559 张封面的文件内容；目录数据、绑定、LUT、Swift 代码和其他应用资源均以开始本任务时的哈希为基准校验。

## 复核工具

`optimize.py` 提供备份、试编码与可恢复的逐张压缩；`review_and_apply.py` 生成对比图，并在确认视觉记录、母版和原图哈希、完整解码、资源尺寸与指标后原子替换资源。`verify_text.swift` 为离线 Vision OCR 辅助检查，不参与 App 运行。

## 运行验证（已完成）

使用 XcodeBuildMCP，项目 `JustShoot.xcodeproj`、scheme `JustShoot`、Debug、iPhone 17 / iOS 26.4 模拟器：构建并启动成功，18 项封面准备、图像缓存、胶片目录和筛选索引测试全部通过，0 失败、0 跳过；构建与测试未报告警告。实际检查 Library 混合网格、Ilford HP5 Plus 详情，以及 Films 页面全部 9 张内置拍摄封面，显示与绑定正常。

打包后的 559 张 HEIC 与安装清单 SHA-256 全部匹配，合计 54,348,069 字节。最终范围检查确认应用目录中仅有这 559 张封面的内容相对本任务基准发生改变，其他应用文件和全部母版保持原哈希；`git diff --check` 通过。本次未进行物理设备性能测量，不据此推断加载速度或内存改善。
