# 富士拍摄封面优化 · 2026-10-25

用户确认本轮先优化截图中的 8 款富士拍摄预设。保留已认可的 ASTIA、Classic Chrome、Classic Neg. 三张封面，重新设计 PROVIA、Velvia、ACROS、C200、Pro 400H。独立 Library 页的 72 张富士包装收藏卡不在本轮范围。

## 调研与设计

| 款式 | 可复核的包装依据 | 本轮适配 |
| --- | --- | --- |
| PROVIA | [富士官方 PROVIA 100F 产品页及包装照片](https://www.fujifilm.com/us/en/business/professional-photography/film/provia-100f)、[官方模拟模式图示](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000008291&wd=Film+Simulation) 和项目原图 `00055_000.heic`。 | 放大蓝色识别区，保留金色字、黑色 Professional 带与绿色品牌头部。 |
| Velvia | 同一官方模拟模式图示采用白色名称标签和蓝色色块；项目原图 `00044_000.heic` 保留红色 Fuji 方标、蓝条与 50 标记。 | 白色标签为主体，突出蓝色块和红方标，绿色缩为品牌头部。未使用其他 Velvia 版本的紫红配色。 |
| ACROS | [富士官方 ACROS 100 II 产品页及包装照片](https://www.fujifilm.com/us/en/business/professional-photography/film/neopan-100-acros-ii)、官方 ACROS 模式图示及项目原图 `00524_000.heic`。 | 放大黑白与银灰分区，保留 NEOPAN、ACROS、绿色头部及黑色折带形状。 |
| C200 | 项目原包装正面 `00202_000.heic`；[富士 C200 官方资料](https://asset.fujifilm.com/www/us/files/2019-09/cce1e1943550fc3e76c22411066f0100/films_c200_datasheet_01.pdf) 可复核产品名称与 ISO / 工艺。 | 放大原有紫红梯形标签和白色斜体 C200，保留红橙黄斜线，绿色缩为品牌识别。 |
| Pro 400H | [富士官方 PRO 400H 产品页](https://www.fujifilm.com.hk/products/professional_films/color_negativefilms/pro_400h/) 与项目原包装正面 `00022_000.heic`。 | 放大原有冷紫色、黑色名称带、浅金字和紫色燕尾标记；与 C200 的暖紫红、斜体标签区别开。 |

这些是依据包装和官方模式视觉制作的 App 适配稿。为改善小尺寸辨识度，重排色块占比和字级，不把新图宣称为未经改动的历史包装或官方提供的封面。

## 统一方式与接入

统一为 1024×1024 的满版平面包装正面，主名称清晰、主色块明确，细微纸张纹理与此前认可的三张封面一致。不在图片内绘制圆角、透视盒体、外框或投影；不添加 JustShoot、RAW → sRGB 或宣传文案。三个已认可封面和 Portra 400 保持原文件。

通过内置 `image_gen`，逐款使用原图作为编辑对象；官方图示作为身份与配色参考；已认可的 ASTIA 作为成套风格参考。完整提示词、输入角色见 `prompts.json`。原始 PNG 留存在生成目录，项目中接入 sRGB HEIC。

新增专属拍摄封面，切换 `FilmPreset.libraryCardImage` / `FujifilmSimulation.libraryCardImage` 引用；首页、相机图标、相机选择器沿用现有的预热和有界缓存。原有编号文件继续供真实包装收藏库使用，不修改 `cards.json`，不改 LUT、拍摄处理或导入逻辑。

最终资源与校验见 `assets.json`，测试和模拟器检查见 `validation.json`。优化前所有已有封面、目录与 LUT 的 SHA-256 记录于 `baseline-hashes.json`，用于验证本轮的修改范围。
