# Portra 400 拍摄封面优化 · 2026-10-25

将 Kodak Portra 400 的拍摄封面按真实包装及现有九宫格重新适配。用户已确认优化方向并要求实施；本轮新增一张专属封面并更新默认绑定。

## 包装调研

- [Kodak Professional 官方产品资料](https://www.kodakprofessional.com/photographers/film/color/kodak-professional-portra-400-film/516)：确认 Portra 400、ISO 400、135 / 36 张等产品信息。
- [Photolab Berkeley 实物包装](https://photolab-berkeley.com/products/kodak-portra-400-professional-film-135-36)：紫色片名区、白色无衬线 PORTRA 400、黄色 Kodak Professional 品牌条，紫色区域有弧形蓝紫印刷带。
- [SHOWA 35mm 包装照片](https://showa-store.com/zh/products/kodak-portra-400-135)：交叉核对上述配色和品牌位置。参考照片保存于 `references/`，用于生成时辨识包装。

现有拍摄封面取自收藏图 `00200_000.heic`。它的立体红飘带未出现在本次参考的包装正面，因此新设计去掉该装饰。原始收藏图及 cards.json 保持原貌。

## 设计与制作

使用内置 `image_gen` 编辑，原封面为编辑目标，真实包装为身份参照，上一轮整组图作为搭配参照。完整提示词与输入路径见 `prompt.json`，原始输出路径见 `generated-source.json`。

- 保留紫黄配色、白色片名、Kodak 红标及黄色品牌条，品牌位置参考实物包装。
- 片名保持单行并适度增加字重；技术参数显著缩小，形成明确主次。
- 紫色偏蓝，保留实物包装的弧形印刷带；纸纹收细，去掉红飘带及立体装饰。
- 延续 App 的方形、满版、平面印刷封面；圆角由 App 绘制。图中不添加 JustShoot、RAW / sRGB 或额外宣传文案。

1024×1024 sRGB HEIC 已保存为 `JustShoot/Resources/cards/cover_kodak_portra_400.heic`，`FilmPreset.kodakPortra400.libraryCardImage` 改为这个专属资源。继续复用现有有界异步解码和缩略图准备流程。

## 验证

在 JustShoot.xcodeproj / JustShoot / Debug / iPhone 17（iOS 26.4.1 模拟器）构建、安装和运行成功，无警告。封面准备与目录回归共 8 项测试通过，包含首页和选择器实际显示图片解码。已检查单张前后对比、110px 九宫格和 App 首页绑定关系。

资源尺寸、色彩空间、哈希与大小见 `asset.json`；构建日志、测试结果与截图路径见 `validation.json`。保留原始生成 PNG，不修改 LUT、其余封面、收藏图、用户照片或导入数据。本轮没有进行相机实拍或物理设备性能测量。
