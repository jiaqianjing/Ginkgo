# Ginkgo 架构设计

> 2026-11-21 起草。产品层面的决定见 `product-brief.md`，这里只讲怎么实现。每个阶段做完后回来更新这份文档。

## 总览

```
Ginkgo/
├── App/                      正式 App（xcodegen 生成工程）
│   ├── project.yml
│   ├── Ginkgo/               SwiftUI 界面、PDFKit / PencilKit 接入、SwiftData 持久化
│   └── GinkgoTests/
├── Packages/GinkgoKit/       与界面无关的逻辑，`swift test` 在 Mac 上直接跑
│   ├── GinkgoCore/           锚点、批注模型、页边排版、笔画分类
│   └── GinkgoAI/             模型接入、提示词、API key 存储
└── Prototype/                原生原型，只作参考，不再演进
```

分层原则：**能脱离 UIKit 测试的都放进 GinkgoKit**。App 里只留"把模型画到屏幕上"和"把手势翻译成命令"的代码。

## 模块

### GinkgoCore

- **锚点（Anchor）**：批注挂在哪里。用一个可编码的枚举装各种格式的锚点，现在只有 PDF 一种：

  ```swift
  enum Anchor: Codable, Hashable {
      case pdf(PDFAnchor)        // 第一版
      // case text(TextAnchor)   // 以后的 EPUB / Markdown 重排
  }
  struct PDFAnchor: Codable, Hashable {
      var pageIndex: Int
      var rects: [CGRect]        // 页面坐标（PDF 点），每行一个
      var range: NSRange?        // 页面文字里的范围，没有文字层时为空
      var quote: String          // 原文，用于展示、提示词和重新定位
  }
  ```

  另有一个 `AnchorResolver` 协议，由各格式的阅读器实现：把锚点换算成屏幕上的矩形。PDF 的实现在 App 里（依赖 PDFKit）。以后加流式格式时，只需要新增一种锚点和一个 resolver，批注、AI、导出的代码都不用动。

- **批注（Annotation）值类型**：`kind`（高亮 / 手写 / 提问）、`anchor`、`color`、`ink`（PencilKit 笔迹数据，可空）、`question`（打字或手写识别出来的问题）、`reply`（AI 回答及其状态）。持久化模型在 App 里，Core 只放值类型和逻辑，方便测试。

- **页边排版（MarginLayout）**：输入每条批注的锚点高度和卡片高度，输出卡片位置；后面的卡片往下推，互不重叠。横屏 A 用它排页边栏；竖屏 B 用它排展开的卡片。原型里的 `stack()` 搬过来并补测试。

- **笔画吸附（StrokeSnapping）**（2026-11-22 起，#3）：工具是用户明确选的，不再靠猜。荧光笔的笔画吸附到它涂过的文字行，划线（直线、波浪线）吸附到上方那一行，圈选取它圈住的范围。标记的样式存在 `MarkStyle`（highlight / underline / squiggly）。
- **笔画分类（StrokeClassifier）**：现在只用于钢笔，判断是不是写在页边的提问。原来的规则如下：
  - 横着划过文字：高亮，吸附到所在行。
  - 圈住一段：选中这段，弹出翻译 / 解释 / 提问。
  - 写在页边空白处：手写提问，挂到旁边那一行。
  - 其他：普通手写笔迹。

  纯几何计算，输入点序列和文字行的矩形，所以可以单测。

### GinkgoAI

- **`AIProvider` 协议**：`func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>`，回答按流式返回，卡片里一个字一个字出来。
- **三家实现**：OpenAI（Responses API）、Anthropic（Messages API）、Gemini（generateContent）。只用 `URLSession`，不引入第三方 SDK。
- **`PromptBuilder`**：四种任务（翻译、解释、提问、手写提问）。上下文包括选中的原文、前后段落、书名，以及目标语言（默认跟随系统语言）。要求回答简短，像页边批注，不像聊天。
- **`ModelCatalog`**：每家三个精选模型（快速 / 均衡 / 最强），快速档是推荐和默认值，用户没选过就跟着推荐走。填了 key 后拉取服务商的模型列表，去掉非对话模型、过期模型和带日期的快照，放进「更多模型」。`AnswerLatency` 给测试连接计时（首字、完成）。
- **追问与学语言**（2026-11-23 起，#10、#11）：`Study.swift`。`FollowUp` 是一轮追问；`PromptBuilder.followUp` 把原文、最初的批注、重点表达、语法分析和之前几轮打包成单轮请求。外语翻译时按选中长度分流（`PassageShape.isLookup`）：一个词或短语出词卡（`WordCard`，JSON），一句话先流式出译文，再取重点表达（`KeyItems`，含是否值得做语法分析），语法分析（`SentenceAnalysis`）由读者点了才请求。JSON 回答用 `AIClient.collect` 收齐后由 `StudyJSON` 解析，容忍代码块和前后多余的话。`LearnerLevel`（入门 / 中级 / 高级，默认中级）决定挑哪些表达、讲多深。
- **`KeyStore`**：API key 存在钥匙串里，只在本机，不进 iCloud。
- **缓存**：以（任务、原文哈希、模型）为键，同一段翻译不重复花钱。

### App

- **书库（Library）**：
  - 封面网格，封面取 PDF 首页的缩略图。
  - 可以从"文件" App 导入（多选）或拖进来。PDF 复制进 App 自己的容器，以后同步时改成放进 iCloud Drive。
  - 按最近阅读排序。
- **阅读器（Reader）**：
  - `PDFView` 包装成 SwiftUI 视图，记住每本书读到哪一页。
  - 点一下屏幕，切换工具栏的显示和隐藏。
  - **页内叠加层**：用 `PDFPageOverlayViewProvider` 给每页挂一个 PencilKit 画布，笔迹滚动和缩放时自动跟随页面。画布尺寸就是页面的点数（与缩放无关），所以笔迹直接按页面坐标存储。没有书写模式（#3）：选了工具时画布只接 Pencil（`drawingPolicy = .pencilOnly`），PDFKit 自己的手势只接手指（`ReaderPDFView.reserveTouches`），所以手指照常滚动和选字。PDFKit 内部的页面视图是文本输入响应者（为了选字），菜单关闭后焦点落回它时 iPadOS 会弹出键盘；`ReaderPDFView` 监听键盘出现，遇到这种情况把焦点收回自己。手指也能用工具（#7）时，画布接受任何输入，PDFKit 的滚动改为双指、选字手势暂停，捏合照常。这个选项在设置的「手势」里，三选一（`FingerInput`）：跟随系统（默认，读 `UIPencilInteraction.prefersPencilOnlyDrawing`）、手指也能用工具、只用 Apple Pencil；关掉设置页或 App 回到前台时重新读取（`ReaderModel.refreshFingerInput`），所以系统设置改了也能跟上。工具栏不放这个开关。荧光笔（吸附模式）和划线不经过 PencilKit：画布让开，阅读器上的拖动手势（`PDFKitView.Coordinator.marking`）从落笔点到当前点取文字选区，两端扩到整词，实时画出预览（`ReaderModel.markPreview`，和最终标记共用 `MarkPainter`），抬笔即保存（#6）。圈选、钢笔和自由涂抹的荧光笔仍用 PencilKit，各用不同的墨水类型，抬笔后按墨水类型解释笔画（`PageInk.interpret`）。双击笔杆和捏合走 `UIPencilInteraction`，跟随系统设置。高亮记号画在页面上方的 SwiftUI 层里（和页边卡片共用一套坐标换算）。
  - **页边层**（2026-11-22 起，#2）：书页默认占满宽度；每条批注在页面右边缘一个贴签（`NoteTab`），点开是浮起的卡片（`FoldedNotesLayer`，长回答截断并给出「展开全文」；下方放不下时放到原文上方）。侧边栏（`SidenoteColumn` 加连线）只在宽窗口出现，条件是回顾模式或有一条展开的批注（`ReaderModel.expanded`）；窄窗口里展开的批注用右侧浮起的面板（`ExpandedNotePanel`）。都在页面上方的 SwiftUI 层里，用 PDFKit 做坐标换算。
  - 宽窗口的判断依据是可用宽度，不是设备方向，这样分屏和台前调度下也成立（`ReaderLayout.isWide`）。
  - 阅读模式下批注几乎隐形；回顾模式下全部展开。
- **撤销与重做**（2026-11-22 起，#4）：所有改动都登记到窗口的 `UndoManager`（`Reader/Undo.swift`），所以系统的三指手势和 ⌘Z 都能用；`ReaderPDFView` 做第一响应者，让它们找得到这个撤销管理器。删除时存一份 `AnnotationSnapshot`，撤销时按原来的 id 和 AI 回答恢复。页面画布（`PageCanvas`）不往窗口登记 PencilKit 自己的撤销，而是由 `PageInk` 在每次解释笔画之后登记一步，所以"一笔荧光笔变成高亮"撤销时是一步。
- **草稿纸**（2026-11-22 起，#9）：`Reader/Scratch.swift`。每本书一张，存在 `Book.scratchData`（PKDrawing），写一笔存一笔。工具栏和 Pencil 捏合扇形里都有入口。宽窗口里放在书页右侧（`ReaderLayout.scratchBeside`，这时不显示侧边栏），窄窗口里浮在书页上、从工具栏下方开始；左边缘可拖宽。画布用工具栏当前的笔和颜色，没选工具时就是钢笔，手指设置同样适用；纸面向下无限延伸。草稿纸有自己的 `UndoManager`（`ReaderModel.scratchUndo`），打开时工具栏、⌘Z 和三指手势撤销的都是草稿，书里的改动照旧登记到书的撤销管理器；草稿纸收起时它的撤销历史随画布一起清掉。打开时关掉 iOS 26 的内容区返回手势，否则从左往右的一笔会退出阅读器。
- **嵌套标记**（2026-11-24 起，#14）：`Reader/Nesting.swift`。两条标记的关系由原文范围算出来（`PDFAnchor.sameText / encloses / overlaps`，在 GinkgoCore），不存储；`ReaderModel.passages` 每次 reload 解码一次。重叠处点击取原文最短的那条（`annotation(at:)`）。外层荧光笔在里层荧光笔两侧断开，各段照常是圆头，中间留细缝（`MarkPainter.segments`），每段只显示一种颜色；荧光笔里的划线被选中时不再铺底色。同一段原文同一种样式只有一条标记（再画就换色）；没有批注的同色同样式标记重叠时合并成一条，带批注的永远不合并。对已有批注的原文再点翻译、解释或提问，结果作为追问接到原卡片；在已有荧光笔的句子里再查词，新标记默认是划线。词卡顶部链接到所在句子的卡片，句子卡片列出「句中查过」的词；查词时把所在句子的译文一起交给模型（`PromptBuilder.wordCard(sentence:)`）。
- **追问在侧栏里进行**（2026-11-25 起，#15）：`Reader/Conversation.swift`。点「追问」或「展开全文」打开这条批注的问答区（`ReaderModel.openConversation`，状态仍是 `expanded`）：宽窗口占据右侧整栏（比边注栏宽一些），窄窗口浮在右侧。顶部是原文，接着是第一次回答（`NoteCard(showsThread: false)`），下面按顺序列出全部追问，问题是右侧气泡，回答是正文；底部是输入框，从「追问」打开时直接聚焦。只围绕这段原文，不做通用聊天。问答区开着时点别的批注贴签就切换到那条批注，点页面空白处或在问答区上向右滑收起。手指从书页右边缘 24pt 以内向左滑也能唤出侧栏（`PDFKitView.Coordinator.edgeSwiped`，只认手指；用普通拖动手势自己判断起点，系统的屏幕边缘手势在模拟器和贴边处都不可靠）：展开正在看的批注，没有就展开屏幕上最靠上的一条，屏幕上没有批注则不响应（`ReaderModel.revealSideColumn`）。问答区和草稿纸开着时，用 `BackSwipeBlocker` 关掉 iOS 26 在内容区任意位置右滑返回的手势，免得向右滑退出这本书。侧栏开关会改变书页宽度：`ReaderPDFView.layoutSubviews` 在宽度动画开始时记住最上面一行，之后直接设置滚动位置，所以正文不跳。阅读器只忽略容器的安全区，键盘出现时内容上移，输入框不会被挡住。
- **批注卡片**（#10、#11）：阅读模式一次只浮起一张卡片，打开新的就收起旧的（`ReaderModel.peeked` 的 didSet）；回顾模式的侧栏不受影响。卡片左上角的颜色点是颜色菜单；卡片处于焦点时，标题行右侧直接显示色盘和红色的删除（卡片和划线一起删，可撤销）；右上角的 ⋯ 和长按卡片是同一份操作菜单（复制、追问、换颜色、重新回答、删除）。删除分两种：`ReaderModel.removeNote` 去掉批注、保留划线，`delete` 连划线一起删，都能撤销。橡皮擦掉经过的普通划线（挂在画布自己的 `drawingGestureRecognizer` 上跟踪轨迹，单独加的手势收不到触摸），不擦带批注的标记，只在页面底部提示去卡片里删（`ReaderModel.show(notice:)`）；橡皮是像素橡皮（`PKEraserTool(.bitmap)`），只擦碰到的部分，悬停预览是 PencilKit 自带的圆圈；擦断的笔画碎片按原样保存，不当作新笔画解读（`PageInk.erased`）。拿着钢笔、圈选这类画布工具时，Pencil 在标记上单独点一下不会留下墨点，而是和手指点一样打开卡片或操作条（`PageInk.markTapped`、`ReaderModel.tapMark`）。回答完成后底部有「追问」，问答接在原回答下面，存在 `AnnotationRecord.threadData`；浮起的卡片只显示最新一轮，完整视图把更早的折叠成「前 N 轮」。外语翻译的词卡、重点表达和语法分析存在 `studyData`（`StudyNote`）。是否算外语由 `AISettings.isLearning` 用 NaturalLanguage 判断。请求统一走 `Reader/NoteAI.swift` 的 `perform`：每条批注同时只有一个请求，`ReaderModel.busy` 告诉卡片正在等什么。追问可以撤销，导出时一并带上。
- **持久化**：
  - SwiftData：`Book`、`AnnotationRecord`、`Reply`。
  - 现在就按 CloudKit 的约束设计：所有属性可空或有默认值，不用唯一约束，关系都可选。等开通 iCloud 时直接打开同步，不用迁移数据。
- **设置**：
  - 选择 AI 服务商、填 key、选模型。
  - 目标语言。
  - 默认高亮颜色。

### 视觉设计

界面采用系统控件和 iOS 26 Liquid Glass。视觉参数集中在 `App/Ginkgo/Design/Theme.swift`，覆盖纸面配色、系统字体、间距、圆角、阴影和五色高亮。玻璃仅用于浮动操作；批注使用纸色卡片。当前方案由 Codex 在 `codex/visual-design` 上实现，等待按产品简报审核；说明与截图见 [`design/`](design/README.md)。图标保留已定稿的 `App/Ginkgo/AppIcon.icon`。

## 阶段

每个阶段一个分支、一个 PR。（2026-11-21：第一到第五阶段在分支 `claude/app-foundation` 上一起完成，按阶段分别提交；验收清单见 `App/README.md`。）

1. **地基**：
   - 工程和图标。
   - GinkgoKit 骨架。
   - SwiftData 模型。
   - 书库：导入、网格、打开。
   - 阅读器：翻页、记住位置、隐藏工具栏。
2. **批注核心**：
   - 锚点和 resolver。
   - 选中文字后高亮，记号画在页内叠加层上。
   - 持久化，重开书后批注还在。
3. **AI**：
   - 设置页和钥匙串。
   - 三家服务商的流式接入。
   - 翻译、解释、提问三个入口。
   - 横屏 A、竖屏 B 两种页边呈现。
   - 阅读模式和回顾模式。
4. **Pencil**：
   - PencilKit 笔迹。
   - 笔画分类：划线高亮、圈选弹菜单、页边手写提问，手写用 Vision 识别。
   - 真机验证手感。
5. **回顾与导出**：
   - 批注流侧栏。
   - 导出 Markdown。
   - 导出带标准批注的 PDF：高亮、ink、附带 AI 回答的文字批注。
6. **打磨与上架**：
   - iCloud 同步。
   - 性能，尤其是几百页 PDF 和几百条批注的情况。
   - 视觉稿接入。
   - App Store 准备。

## 发版

- **版本号**：`App/project.yml` 的 `MARKETING_VERSION`（对外版本，现为 1.0）和 `CURRENT_PROJECT_VERSION`（构建号）。Info.plist 从这两项读取；每次上传 TestFlight 前把构建号加一，再跑 `xcodegen`。
- **加密声明**：`ITSAppUsesNonExemptEncryption = NO`，App 只用 HTTPS 连 AI 服务商，免出口申报。
- **隐私清单**：`App/Ginkgo/PrivacyInfo.xcprivacy`。不追踪；声明了 UserDefaults（理由 CA92.1，只读写 App 自己的设置）；「其他用户内容」不关联身份、只用于 App 功能，对应发给 AI 服务商的原文和问题。App Store Connect 里的 App 隐私信息要和它一致。
- **发给 AI 前征得同意**（App 审核指南 5.1.2(i)）：每家服务商第一次发送前弹窗说明会发什么、发给谁（`ConsentText`），同意后记在 `ai.consent.<服务商>`。请求在 `NoteAI.perform` 里被拦下，放进 `ReaderModel.held`，同意后一起发出；取消则这些卡片显示「没有发送」，可以重试；删掉批注时一并丢弃。没填 key 时照旧报缺 key，不弹窗。设置页可以随时关掉，并链到服务商的隐私政策。设置页的「测试连接」只发一句固定的示例句子，不需要同意。
- **隐私政策**：草稿在 `docs/privacy-policy.md`，上架前要放到公开网址并补联系方式。

## 测试

- GinkgoKit：用 `swift test` 测锚点编码、页边排版、笔画分类、提示词拼装。AI 请求的编码和流式解析用 `URLProtocol` 打桩测试，不真的联网。
- App：关键流程用模拟器手动截图验证；Pencil 相关必须真机验证。
