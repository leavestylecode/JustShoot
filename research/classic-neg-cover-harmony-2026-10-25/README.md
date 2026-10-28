# Classic Neg. 封面组合微调 · 2026-10-25

用户确认上一轮整体评估后，按建议只微调 Classic Neg. 的绿色亮度与片名大小，让它在九款默认拍摄封面中更协调。

## 设计依据

继续沿用此前调研的 [Fujifilm 官方 Film Simulation 示例图](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000008291&wd=Film+Simulation) 的绿、黄、蓝身份色与字形。Classic Neg. 属于模拟模式，本次延续官方模式图的视觉身份。此前参考与生成过程见 `../film-covers-2026-10-25/README.md`；整组协调方案见 `../fujifilm-cover-harmony-2026-10-25/README.md`。

使用内置 `image_gen` 编辑现有封面，以最新九宫格作为视觉权重参照。绿色从明亮荧光绿调整为更沉稳的叶绿；CLASSIC / Neg. 片名略微收小，增加两侧留白。保留富士标识、黄色窄体字、右对齐的 Neg.、蓝色斜角及页脚。没有新增文案、徽章或立体装饰。

完整提示词及两个本地输入见 `prompt.json`；原始生成 PNG 路径见 `generated-source.json`，原图保留于 `.codex/generated_images/`。Pillow 仅用于 sRGB 编码、缩放及对比排版，没有用于创意改色或重绘。

## 接入与验证

覆盖 `JustShoot/Resources/cards/cover_fuji_classic_neg.heic`，沿用 `FujifilmSimulation.classicNeg.libraryCardImage` 现有默认绑定。最终格式为 1024×1024、带 sRGB ICC 的 HEIC（质量 60），大小和 SHA-256 见 `asset.json`。

在 JustShoot.xcodeproj / JustShoot / Debug / iPhone 17（iOS 26.4.1 模拟器）构建、安装和运行成功，无警告。封面准备与目录回归 8 项测试全部通过，覆盖首页和选择器的实际图片解码、专属绑定及取消处理。已检查前后图、110px 缩略图、220px 九宫格及 App 实际首页，结果路径见 `validation.json`。

587 个基线文件中只有目标封面改变；另外八张默认封面、550 张原始收藏图、cards.json、LUT 表及两处映射源文件均保持原样。本轮没有修改拍摄链路，也没有进行相机实拍或物理设备性能测量。
