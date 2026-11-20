# Ginkgo 银杏：产品简报

> 来源：2026-11-20 在 SwipeSay 仓库里的一次产品讨论。这份文档记录当时定下的结论，是本项目的起点。

## 一句话

**一个在 iPad 上用 Apple Pencil 和书对话的阅读器。** 划线、圈选或在页边手写提问，AI 的回答像老师写在书边的批注一样留在页面上。

## 为什么要做

- iOS / iPadOS 不允许第三方 App 做全局划词，也不能往 Apple Books、Kindle、微信读书写批注。要在阅读时翻译、提问并把结果留在书里，只能自己做阅读器。
- 现有产品各缺一块：GoodNotes / Notability 偏笔记本；LiquidText、MarginNote 偏工具，界面重；Apple Books 舒适但几乎不支持 Pencil，也没有 AI。
- 要占的位置：**Pencil 体验 + AI 页边批注 + 安静的阅读界面**。

## 关于名字

银杏叶是东亚读书人夹在书页间的书签，可以防蠹虫。两片叶瓣也像一本摊开的书。

名字核查（2026-11-20）：Gloss、Scholia、Marginalia、Virgil 在 App Store 上都已经被阅读类 App 用了。其中「Gloss: Annotated Reader」的卖点是"划线后在页边生成解释"，**是直接竞品，需要持续关注**。

## 定下的决策

1. **只做阅读器，不做书城。** 读的是用户自己的文件。买来带 DRM 的书不在范围内。
2. **第一版只支持 PDF。** 主要场景是 PDF、Markdown、Word。EPUB 先不做，技术难度高，需求也没有验证过。
3. **Word / Markdown 放第二版**，先转成固定版式的 PDF 再读，批注挂在 PDF 上。以后如果需要随字号重排，再做流式渲染。到那时 Markdown 和 EPUB 共用一套技术。
4. **批注的位置抽象成接口。** 第一版只实现"PDF 页码 + 坐标 / 文字范围"，以后加"文字锚点"时不用推翻重来。
5. **批注设计是核心卖点。** App 内的显示完全自己设计，不用丑陋的便签图标。导出时退化成标准 PDF 批注（高亮、ink、文字），保证换别的阅读器也不丢内容。
6. **AI 回答放在页边，不做聊天窗口。**
7. **复用 SwipeSay 的 AI 能力**（SwipeSayKit：各家模型接入、提示词、翻译、缓存、用量、生词本）。

## Apple Pencil 交互（草案）

| 手势 | 动作 |
|---|---|
| 划线 | 高亮（手绘笔触，吸附到文字） |
| 圈选一段 | 弹出浮层：翻译 / 解释 / 提问 |
| 在页边空白处手写 | 识别手写问题，带上旁边段落去问 AI，回答作为页边卡片 |
| 悬停（新款 iPad Pro） | 预览翻译，笔不碰屏 |
| 捏笔杆（Pencil Pro） | 在笔尖处弹出工具盘 |
| 双击笔杆 | 在书写和高亮之间切换 |
| 套索选中多条批注 | 让 AI 整理成总结 |

## 批注风格：三个候选方向（要做原型比较）

- **A. 页边旁注**：横屏时书页稍微缩小，旁边留出页边栏。卡片和对应的那行文字水平对齐，用一根细线连回原文（Tufte 风格）。
- **B. 收起是一道线，展开是一张卡**：平时只在页边显示一个颜色记号，点一下或笔悬停时展开。高亮颜色和卡片颜色一致，靠颜色关联。
- **C. 手写和回答在一起**：保留用户在页边写的手写笔迹，AI 的回答排在笔迹下方，字体安静，像有人在你的书上回了一句话。

另有两种模式：**阅读模式**下批注几乎隐形，**回顾模式**下全部展开，变成一份带上下文的笔记。

## MVP 范围

1. PDF 书库：从"文件" App、iCloud Drive 导入
2. 阅读页：界面元素可以全部隐藏，支持手写和高亮
3. Pencil 手势：划线高亮、圈选弹出翻译 / 解释 / 提问、页边手写提问
4. AI 回答以页边卡片显示，可以保存为批注
5. 批注流侧栏，导出 Markdown 和带批注的 PDF

第二版：Word / Markdown 导入、整本书问答（RAG）、多书知识库。

## 技术方向

- **PDF**：PDFKit + PencilKit（`PDFPageOverlayViewProvider` 叠加层）。笔迹存成标准 ink 批注。
- **自定义批注层**：PDF 页面上叠一层 SwiftUI / UIKit 视图，用 PDFKit 做页面坐标和视图坐标的换算。难点在缩放、滚动时的对齐，批注之间的避让排版，以及性能。
- **数据**：SwiftData + CloudKit，文件放 iCloud Drive。
- **设计语言**：iOS 26 Liquid Glass，排版参考 Apple Books，书写手感对标 GoodNotes。

## 复用 SwipeSayKit

- 起步阶段：两个仓库放在同一个父目录下，阅读器用本地路径引用 `../SwipeSay/Packages/SwipeSayKit`。
- 稳定以后：把 SwipeSayKit 拆成独立仓库，两个 App 都按版本号引用它（SwiftPM 不能引用另一个仓库里某个子目录的包）。
- 要改的地方：`SharedStorage` 里写死了 `group.com.kenjia.swipesay` 这个 App Group 和对应的钥匙串访问组，要改成由调用方配置。两个 App 都在同一个团队（UBS9FUBNFR）下，以后也可以共享一个 App Group，让 API key 和生词本互通。

## 发布

大概率上 App Store（iPad 优先）。这和 SwipeSay Mac 版的站外分发（Developer ID + Sparkle）是两条路。

## 原型

- 批注风格对比原型：`docs/prototypes/annotation-styles.html`（在线版：https://claude.ai/artifact/9ZTug9ZHzCGXSeBY9iaSno，私有）

## 用户反馈与下一步（2026-11-20）

- **图标第一版不好看**，需要重做。可以考虑用 Apple 的 Icon Composer 做分层的 Liquid Glass 图标，先多出几个方向让用户挑。
- **网页原型看起来奇怪，体会不到在 iPad 上的状态和交互。** 下一版原型建议直接用 SwiftUI 写，跑在 iPad 模拟器里：用真实的 PDFKit 页面、真实的横竖屏和尺寸，三种批注风格做成可以切换的开关。手势先用手指或鼠标模拟，Pencil 的手感最后要在真机上验证。
- 三种批注风格（A 页边旁注 / B 一线一卡 / C 手写回应）还没有选定。
