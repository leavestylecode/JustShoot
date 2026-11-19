# 宝藏库的胶片资料与样片

## 介绍与场景

每款详情页的书本按钮可打开两份资料：厂商对原胶片或相机模拟的说明，以及摄影者的使用记录。中英文介绍为编辑整理。题材标签综合这两类资料选取，具体的冷暖倾向和明暗表现还与 App 的三组同图渲染核对。实体胶片的感光度、曝光宽容度和冲洗特性不作为数字 LUT 的效果描述。[逐款来源](../../JustShoot/Features/FilmLibrary/FilmGuideSources.swift)

- 富士的六款数码模拟参考 X 系列使用指南、Imaging Resource 的实拍对照，以及 Measuring Light 的台湾街拍记录。PROVIA 相机模拟和 Provia 100F 反转片各用对应资料。[富士指南](https://www.fujifilm-x.com/en-gb/learning-centre/get-to-grips-with-film-simulation-modes/) · [实拍对照](https://www.imaging-resource.com/news/fujifilm-film-simulations-definitive-guide/) · [街拍记录](https://measuringlight.com/2024/02/26/trips-23-taiwan-with-fuji-x-pro3-pro-photographers/)
- 富士、柯达实体片逐款查阅技术资料。The Darkroom 的冲扫观察与投稿实拍补充肤色、常见用光和拍摄题材。Kodachrome 64 的技术资料采用存档的柯达 E-88，并参考 Casual Photophile 的原片回顾。[富士资料目录](https://www.fujifilm.com/sg/en/consumer/support/films/negative-and-reversal) · [柯达资料目录](https://kodakprofessional.com/photographers/resources) · [The Darkroom](https://thedarkroom.com/film-index/) · [Kodachrome 回顾](https://casualphotophile.com/2017/10/04/kodachrome-retrospective-film-profile/)
- 黑白款着重描述灰阶。HP5 Plus 的室内和纪实用途参考厂商建议与现场拍摄，Tri-X 的街拍参考 35mmc 摄影者用片回顾，T-Max 100 的细节和影调参考技术资料及冲扫观察。[Ilford HP5 Plus](https://www.ilfordphoto.com/hp5-plus-35mm) · [HP5 室内实拍](https://www.35mmc.com/27/01/2026/ilford-hp5-plus-at-a-historical-engine-factory/) · [Tri-X 实拍回顾](https://www.35mmc.com/07/02/2020/kodak-tri-x-review/) · [T-Max 100 实拍](https://thedarkroom.com/film/tmax/)

## 样片原图

三张照片均由 Carol M. Highsmith 拍摄，来自美国国会图书馆版画与摄影部的 Carol M. Highsmith Archive。馆方将这批照片列为公有领域。选用日常环境中的实拍，以自然光下的肤色、材质和阴影对比模拟效果。[馆藏说明](https://www.loc.gov/pictures/collection/highsm/) · [权利说明](https://www.loc.gov/rr/print/res/482_high.html)

| 场景 | 馆藏原图 | 观察重点 |
| --- | --- | --- |
| 环境人像 | [Gee’s Bend, Alabama，LC-DIG-highsm-07201](https://www.loc.gov/resource/highsm.07201/) | 门廊中的肤色、紫色上衣和彩色织物 |
| 风光 | [Ranch near Shawnee in Park County, Colorado，LC-DIG-highsm-34974](https://www.loc.gov/item/2017685457/) | 秋草的暖黄、远山的蓝色与云的高光 |
| 街景 | [Old car and gas station, Route 66, Truxton, Arizona，LC-DIG-highsm-04162](https://www.loc.gov/item/2010630157/) | 浅色车身、白墙、檐下的阴影 |

原图取自馆方各条目的 1024 像素 JPEG，按内嵌 ICC 转至 sRGB，统一为 1023 × 682。每款共用这三个输入，按题材调整首图。应用内的 57 张效果图使用实际预设和 `FilmImagePipeline` 的调色阶段离线生成。原图和效果图的构图、曝光一致，便于逐张切换比较。[导出与像素对照测试](../../JustShootTests/FilmSampleGalleryTests.swift)
