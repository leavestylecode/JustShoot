# 缺失胶片封面补全 · 2026-10-25

本轮只补全 ASTIA、Classic Chrome、Classic Neg.。已有 PROVIA、Velvia、ACROS、C200、Pro 400H、Portra 400 六张封面保留，文件 SHA-256 记录于 `assets.json`。没有新增或修改 LUT，也没有把模拟模式重新命名为其他胶片。

## 调研依据

| 款式 | 可核查依据 | 封面处理 |
| --- | --- | --- |
| ASTIA | [富士 ASTIA 100F 官方技术资料](https://www.fujifilm.com.hk/products/professional_films/pdf/astia_100f_datasheet.pdf) 第 4–5 页明确包装识别色为 Violet Blue；[100F 真实包装照片](https://auctions.yahoo.co.jp/jp/auction/o1094334240) 可见绿、金、黑、紫蓝分区。 | 使用 100F 代包装的分区、ASTIA 主字、Professional 黑条，重排成正方形；保留实体胶片的 100F、日光、ISO 100、E-6 标识。 |
| Classic Chrome | [富士官方模拟模式说明及图示](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000008291&wd=Film+Simulation) 的对应插图是黄橙底、红色竖条和黑色蝴蝶结形标签，文字为 FUJI / CLASSIC CHROME。 | 沿用这套官方图示，扩展成与 App 相同的平面方卡。使用 FILM SIMULATION 小字，不编造胶片 ISO、张数或冲洗工艺。 |
| Classic Neg. | 同一[官方说明](https://digitalcamera-support-en.fujifilm.com/digitalcameraengpcdetail?aid=000008291&wd=Film+Simulation) 明确其基于 SUPERIA；官方图示采用绿底、黄字、左下蓝色色块。 | 保留官方模式图示的颜色和构图，标题仍为 CLASSIC Neg.，不借用 SUPERIA 名称或直接套用收藏库包装。 |

[官方模拟模式总览](https://www.fujifilm-x.com/global/products/film-simulation/) 可复核三款模式名称与图示。ASTIA 100 旧包装仅用于辅助辨认家族配色；最终图按 100F 代设计。两款 Classic 的封面是依据官方模拟模式插图制作的适配稿，不声称存在同名实体胶片包装，也不是官方发布的成品封面文件。

## 与项目封面的统一方式

先检查项目实际的 PROVIA、Velvia、ACROS、Pro 400H、Portra、SUPERIA 卡图。延续 1024×1024、满版包装正面、大字号片名、有限色块、轻微纸张纹理和右下角小字；图中不增加圆角、透视盒体或投影，圆角由 App 渲染。

三张图通过内置 `image_gen` 生成，完整提示词和输入参考角色保存在 `prompts.json`。原始生成 PNG 的路径及最终资源 SHA-256 保存在 `assets.json`。源图转换为嵌入 sRGB 配置的 HEIC，不更改构图、文字或配色。

## 接入

- `JustShoot/Resources/cards/cover_fuji_astia_100f.heic`
- `JustShoot/Resources/cards/cover_fuji_classic_chrome.heic`
- `JustShoot/Resources/cards/cover_fuji_classic_neg.heic`

`FujifilmSimulation.libraryCardImage` 绑定这三张专属封面。首页、相机当前胶片图标和选择器继续使用现有的异步缩略图预热及有界解码缓存，不增加 UI 更新中的磁盘读取，也不向独立的真实胶片包装收藏目录 `cards.json` 填入生成图。

生成预览和调研参考留在本任务的 `film-covers-2026-10-25` 可视化目录。模拟器检查及测试记录见 `validation.json`。
