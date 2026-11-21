# Ginkgo 视觉设计需求（交给 Codex）

> 2026-11-21 起草。分工：交互、架构和功能由 Claude 负责，已经实现；**界面的视觉，也就是配色、字体、间距、质感、动效细节，交给 Codex**。Codex 完成后由 Claude 对照本文和 `docs/product-brief.md` 审核，再合并。

## 1. 先读这些

- `docs/product-brief.md`：产品是什么、给谁用、要占的位置。
- `docs/architecture.md`：代码结构。
- `App/README.md`：怎么运行、每个功能怎么用（也就是验收清单）。

## 2. 产品气质

一句话：**一个在 iPad 上用 Apple Pencil 和书对话的阅读器。** 用户读自己的 PDF，划线、圈选、在页边手写提问；AI 的回答像老师写在书边的批注，安静地留在页面上。

- **安静、克制、像一本好书**，参考 Apple Books 的舒适感，书写手感对标 GoodNotes。不是效率工具，不是聊天应用，也不是儿童应用。
- **书页是主角。** 界面元素要退后，能藏就藏；批注是"书边的铅笔字"，不是"弹窗"。
- **AI 不张扬。** 不要星星、魔法棒、渐变光效这类"AI 魔法"符号；回答就是一段好排版的文字。
- 遵循 iOS 26 的 Liquid Glass 语言，但玻璃只用在浮在内容之上的控件上（工具栏、浮条、面板），不要满屏玻璃。

**图标已定稿**（`App/Ginkgo/AppIcon.icon`）：柠檬黄底、奶油色纸页、蓝紫色玻璃页签。界面配色可以从这里取：奶油色纸感作底，蓝紫色作强调色，柠檬黄慎用（适合点缀，不适合大面积）。最终配色由你定。

## 3. 范围：要设计的界面

每一项都写明了代码位置。截图方法见第 6 节。

| # | 界面 | 位置 | 现状与要点 |
|---|---|---|---|
| 1 | 书库 | `App/Ginkgo/Library/LibraryView.swift`（`LibraryView`、`BookCover`） | 封面网格加书名和阅读进度，系统默认样式。要做出"书架"的感觉：封面比例、阴影、标题字体、进度的表达、空书库状态、拖入 PDF 时的高亮框。 |
| 2 | 阅读页外框 | `App/Ginkgo/Reader/ReaderView.swift`（`ReaderContent`、`PageIndicator`、`MarginBackground`） | 顶部工具栏：返回、「阅读 / 回顾」切换、笔、批注列表、设置。底部是页码。页面之外的桌面底色、横屏页边栏的底色和分隔线都在这里。 |
| 3 | 高亮记号 | `AnnotationViews.swift` → `MarksLayer` | 每行一块圆角色块（multiply 混合），选中或展开时下面加一道下划线。可以改成更像荧光笔或铅笔的笔触，但必须保持可读，并能和五种颜色配合。 |
| 4 | 批注卡片 | `AnnotationViews.swift` → `NoteCard`、`ThinkingDots` | 最重要的一项。卡片依次显示：类型标签（翻译 / 解释 / 提问）、问题或手写笔迹、AI 回答（逐字流出）。另有三个状态：等待中、出错（重试 / 打开设置）、被选中。要像"书边批注"，不像聊天气泡。 |
| 5 | 横屏页边栏（A） | `SidenoteColumn`、`ConnectorLayer`、`MarginTick` | 卡片在右侧栏和原文对齐，用细曲线连回原文；阅读模式下只剩一道小色条。 |
| 6 | 竖屏折叠（B） | `FoldedNotesLayer` | 页面右边缘的色条，点开后卡片浮在原文下方，比 A 的卡片更"浮起"。 |
| 7 | 选区浮条 | `SelectionMenu`、`AnnotationMenu`、`ActionCapsule` | 依次是五个颜色圆点、翻译、解释、提问、复制或删除。现在是一条玻璃胶囊。 |
| 8 | 提问面板 | `AskSheet` | 引用原文，下面一个输入框。 |
| 9 | 书写模式提示条 | `ReaderView.swift` → `PenBanner` | 说明三种手势，并选择划线颜色、完成。 |
| 10 | 批注列表 | `NotesPanel.swift`（`NotesPanel`、`NoteRow`） | 从右侧滑出的面板：筛选、列表、导出菜单。 |
| 11 | 设置 | `App/Ginkgo/AI/SettingsView.swift` | 服务商、key、模型、测试连接、回答语言。可以保持系统表单风格，只做细节。 |
| 12 | 高亮色板 | `ReaderModel.swift` 末尾 `extension HighlightColor`（`fill` / `ink` / `name`） | 五种颜色：黄、绿、蓝、粉、紫。`fill` 用在高亮上，`ink` 用在文字、色条和连线上。可以重新调色，要求在白纸和深色模式下都和谐，彼此一眼能分清，并照顾色弱用户。 |

## 4. 硬性要求

- **集中定义设计参数。** 新建 `App/Ginkgo/Design/`（例如 `Theme.swift`），把颜色、字体、圆角、间距、阴影集中定义在这里，各界面引用，不要在视图里散落魔法数。
- **浅色、深色都要做。** 深色模式下 PDF 页面本身仍是白纸（不反色），但页面外的底色、卡片、面板要适配。
- **支持动态字体和无障碍。** 卡片和列表的文字随系统字号缩放；对比度满足 WCAG AA；纯图标按钮保留 `accessibilityLabel`。
- **iPad 横竖屏、分屏和台前调度都要成立。** 布局判断见 `ReaderLayout.swift`：宽窗口用 A，窄窗口用 B。
- **字体只用系统字体**（SF、New York 等），或 iOS 自带的字体。不引入需要授权的第三方字体。
- **不改动交互、功能和数据：**
  - 不改 `ReaderModel`、`PDFKitView`、`PageInk`、`Exporter`、`Library`、`Model/`、`AI/AISettings.swift` 和 `Packages/` 里的逻辑。
  - 不改手势和点击区域的行为，不删任何按钮或功能。
  - 卡片位置的计算（`MarginLayout.stack`、各 layer 的 `positions()`）保持不变。卡片的宽度和间距可以调，调了就在说明里写清楚。
  - `HighlightColor` 的枚举名会被存进数据库，**不能改名或删除**，只能改颜色值。
  - 如果你认为某个交互应该改，写进第 7 节的说明里，由我们讨论，不要直接改。
- **只用原创设计**，不模仿某个现有 App 的界面。

## 5. 交付物

1. 代码修改，在一个新分支上。基于 `claude/app-foundation`（正式 App 目前在这个分支上，还没合进 main）。
2. `App/Ginkgo/Design/` 下的设计参数文件。
3. 截图对比：放在 `docs/design/screens/`，第 6 节列出的每个状态各一张，浅色、深色都要，文件名写清状态（例如 `reader-portrait-review-dark.png`）。
4. 一份简短的设计说明 `docs/design/visual-notes.md`：配色和字体的选择、各界面的改动要点、对交互的建议（如果有）。

## 6. 怎么运行和截图

```bash
cd App && xcodegen && open Ginkgo.xcodeproj      # 用 Xcode 跑
```

不用手动点，也能用启动参数直接进入各个状态（只在 Debug 构建里生效，详见 `App/README.md`）：

```bash
B=com.kenjia.ginkgo
xcrun simctl launch booted $B -inMemoryStore YES -seedSample YES                                   # 书库
xcrun simctl launch booted $B -inMemoryStore YES -seedSample YES -openFirst YES -demoAnnotate YES   # 阅读模式 + 示例批注
#   加 -demoMode review   回顾模式
#   加 -demoNotes YES     批注列表
#   加 -demoInk YES       书写模式与三种手势
#   加 -demoSelect "rather than one thing brilliantly"   选区浮条
xcrun simctl io booted screenshot out.png
```

- 示例批注要有 AI 回答，需要把 key 传进模拟器：`SIMCTL_CHILD_OPENAI_API_KEY=... xcrun simctl launch ...`。没有 key 时，卡片会显示出错状态，正好用来检查出错样式。
- 深色模式：`xcrun simctl ui booted appearance dark`。
- 横屏截图要用 UIRequiresFullScreen 构建（`-orientation landscape`），或在 Xcode 里旋转模拟器。

需要截的状态：书库（空的、有书的）、阅读页竖屏（阅读模式、回顾模式）、横屏页边栏（阅读模式、回顾模式）、选区浮条、高亮菜单、提问面板、卡片的四种状态（等待、流式输出、完成、出错）、手写提问卡片、书写模式提示条、批注列表、设置。

## 7. 验收标准

审核时我会逐条对照：

- [ ] 整体气质符合第 2 节：安静、像书、AI 不张扬。
- [ ] 第 3 节的 12 项都处理过（不改的要说明理由）。
- [ ] 设计参数集中在 `Design/`，视图里没有散落的颜色和尺寸。
- [ ] 浅色、深色截图齐全，都好看、都清楚。
- [ ] 五种高亮颜色在白纸上和谐、彼此分得清，文字压在上面依然好读。
- [ ] 卡片在 A（页边栏）和 B（浮起）两种布局下都成立，长回答、短回答、手写笔迹都排得好。
- [ ] 动态字体调到最大，界面也不崩。
- [ ] 第 4 节的硬性要求都满足；交互、功能、数据没有变化；`App/README.md` 的验收清单依然全部可用。
- [ ] `swift test`（`Packages/GinkgoKit`）和 App 的单测依然通过，Debug 构建没有警告。
