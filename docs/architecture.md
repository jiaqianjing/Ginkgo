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

- **笔画分类（StrokeClassifier）**：Pencil 抬笔后，根据笔画形状和落点判断意图：
  - 横着划过文字：高亮，吸附到所在行。
  - 圈住一段：选中这段，弹出翻译 / 解释 / 提问。
  - 写在页边空白处：手写提问，挂到旁边那一行。
  - 其他：普通手写笔迹。

  纯几何计算，输入点序列和文字行的矩形，所以可以单测。

### GinkgoAI

- **`AIProvider` 协议**：`func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>`，回答按流式返回，卡片里一个字一个字出来。
- **三家实现**：OpenAI（Responses API）、Anthropic（Messages API）、Gemini（generateContent）。只用 `URLSession`，不引入第三方 SDK。
- **`PromptBuilder`**：四种任务（翻译、解释、提问、手写提问）。上下文包括选中的原文、前后段落、书名，以及目标语言（默认跟随系统语言）。要求回答简短，像页边批注，不像聊天。
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
  - **页内叠加层**：用 `PDFPageOverlayViewProvider` 给每页挂一个视图，高亮记号和 PencilKit 笔迹画在里面，滚动和缩放时自动跟随页面，不用自己换算坐标。
  - **页边层**：横屏 A 的页边卡片和连线、竖屏 B 的色条和展开卡片，放在页面上方的 SwiftUI 层里，用 PDFKit 做坐标换算（原型验证过的做法）。
  - 横竖屏判断依据是可用宽度，不是设备方向，这样分屏和台前调度下也成立。
  - 阅读模式下批注几乎隐形；回顾模式下全部展开。
- **持久化**：
  - SwiftData：`Book`、`AnnotationRecord`、`Reply`。
  - 现在就按 CloudKit 的约束设计：所有属性可空或有默认值，不用唯一约束，关系都可选。等开通 iCloud 时直接打开同步，不用迁移数据。
- **设置**：
  - 选择 AI 服务商、填 key、选模型。
  - 目标语言。
  - 默认高亮颜色。

### 视觉设计

先用系统控件和 iOS 26 默认的 Liquid Glass 把交互做对。页面视觉，包括配色、字体、卡片样式，按 `CLAUDE.md` 的分工交给 codex 或 agy 出稿，我按产品简报审核后再接入。图标用已定稿的 `Ginkgo-Lemon.icon`。

## 阶段

每个阶段一个分支、一个 PR。

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

## 测试

- GinkgoKit：用 `swift test` 测锚点编码、页边排版、笔画分类、提示词拼装。AI 请求的编码和流式解析用 `URLProtocol` 打桩测试，不真的联网。
- App：关键流程用模拟器手动截图验证；Pencil 相关必须真机验证。
