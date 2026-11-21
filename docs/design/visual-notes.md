# Ginkgo · 纸与墨

基于 `claude/app-foundation`（`b4ea560`），实现分支 `codex/visual-design`。

## 视觉选择

书页之外是暖灰桌面，书库和批注是略带奶油色的纸；蓝紫色仅用于操作和选中。深色模式采用暖炭灰和浅墨色，PDF 保持白纸。没有新增 AI 装饰、渐变或聊天气泡。系统 Liquid Glass 留在工具栏、操作浮条、书写提示和页码上。

书名使用系统衬线 headline，回答使用系统衬线 subheadline，类型标签使用系统圆体 caption；其他控件沿用系统语义字号。所有正文随 Dynamic Type 缩放。玻璃控件内部使用系统 primary/secondary 前景；深色玻璃增加暗色染色，避免白色 PDF 把材质照亮后降低文字对比。`App/Ginkgo/Design/Theme.swift` 集中提供语义颜色、字体、间距、圆角和阴影参数。

## 12 项界面处理

| 界面 | 修改 |
| --- | --- |
| 书库 | 纸色底、封面窄书脊和柔和投影、衬线书名、细进度线；空状态用安静的书本图形。保留导入和拖放高亮。 |
| 阅读外框 | 暖灰桌面、较浅页边纸、细分隔线；页码用系统玻璃前景和等宽数字。PDFKitView 仅替换背景颜色，不改逻辑。 |
| 高亮 | 五种柔和荧光笔色，阅读/回顾/选中逐级提高浓度，multiply 保持原文可读；保留细下划线。 |
| 批注卡片 | 8pt 小圆角、16pt 内边距、细色线，类型和正文分层；侧栏卡片仅极轻投影。错误用可读的砖红，保留重试与设置。等待动画尊重减少动态效果。 |
| 横屏页边栏 | 暖纸色背景、细分隔线，原有曲线和色条用新墨色。 |
| 竖屏折叠 | 相同卡片使用较明显的浮起阴影，色条与原文保留现有关系。 |
| 选区与高亮菜单 | 五色与动作按空间自动排成一行或两行，无障碍字号下动作改为一列或两列网格，当前颜色增加勾号与选中无障碍特征；保留全部动作。 |
| 提问面板 | 引文使用页边纸色块和细蓝紫引线；保留输入、取消、提问与键盘逻辑。 |
| 书写提示条 | 提示与颜色/完成控制自动分行，保持原有颜色选择与完成动作；当前颜色加勾号。 |
| 批注列表 | 纸色面板、衬线引文、细墨色线、次级文字和错误色适配深色。 |
| 设置 | 保持系统 Form，只替换纸色背景、次级文字与错误色。 |
| 高亮色板 | fill 与 ink 分离：白纸使用相同的柔和标记色，卡片和面板标签使用深浅自适应墨色。五个持久化枚举名称不变。 |

卡片宽度、A/B 切换阈值、`MarginLayout.stack`、各 layer 的 `positions()` 和连线路径均保留。按钮回调和手势处理不变；菜单按实际可用宽度夹紧位置，书写提示改为顶部自适应高度。卡片内边距由 14pt 改为 16pt；圆角由 14pt 改为 8pt。菜单和提示条的换行属于视觉排版适配。卡片/列表中的笔迹预览使用随外观适配的单色墨色，原始 PencilKit 数据与 PDF 导出保持不变。

正文、次级文字、强调色、错误色和五种批注墨色对纸色底的 sRGB 对比度：浅色最低 5.61:1，深色最低 7.69:1，均超过普通文字 AA 的 4.5:1。高亮填充是白色 PDF 上的低透明度 multiply 标记，不作为文字颜色使用。

## 截图与复现

`docs/design/screens/` 只保留 10 张关键状态的 JPEG（见 `README.md`）；完整截图用 `scripts/design-screens.py` 在本地生成。设备为 iPad Pro 11-inch (M5)，iPadOS 27.0 模拟器；最大字号为 accessibility-extra-extra-extra-large。

原始 56 张截图中的等待、流式、完成、错误、长回答和问号笔迹为**本地固定演示数据**，不是在线 AI 回答或真实手写识别证据。`visualFixture` 等参数仅在 Debug 生效，且必须同时指定 `-inMemoryStore YES`；不修改真实书库、不发网络请求。原有真实 AI 调试入口仍保留。

```sh
# 正常 Debug 构建安装后；截图横屏时仅给临时 .app 的 Info.plist 加 UIRequiresFullScreen=true。
# 不改仓库中的 Info.plist，不改变正式 App 的多窗口能力。
python3 scripts/design-screens.py --group library
python3 scripts/design-screens.py --group portrait
python3 scripts/design-screens.py --group landscape
python3 scripts/design-screens.py --group states
python3 scripts/design-screens.py --group accessibility
```

脚本使用内存书库，采集后恢复原来的系统外观和动态字号。原有 `demoInk` 和基础分支 `demoAnnotate` 会走原来的 AI 入口；本次使用没有 key 的模拟器，停在本地缺少 key 的提示。复现也应使用没有服务商 key 的模拟器。每次启动等待首帧和示例批注加载完成。

## 交互建议（本次不实现）

- 原有竖屏回顾卡片会遮住原文；多条长回答或最大字号时，后面的卡片可能超出当前视口。建议后续讨论卡片内阅读或独立回顾布局，不能只靠缩小字号解决。
- 原有色条触点较窄，本次按要求保留点击区域；后续可讨论扩大无障碍触点。
- 真机 Pencil 的触感、手写识别和台前调度手动缩放仍需硬件验收。截图不能代替这些验证。

## 验证

- GinkgoKit：`swift test --package-path Packages/GinkgoKit`，18 项测试通过（Core 10、AI 8）。
- App：Debug `build-for-testing` 成功；`test-without-building` 运行全部 5 项单测通过，涵盖导入、损坏 PDF 拒绝、锚点存储、Markdown 和 PDF 导出。
- 无新增 Swift 编译警告。基础分支与本分支都存在 Xcode 的 `Metadata extraction skipped, no AppIntents.framework dependency found` 提示（App/测试目标均可能输出）；因此“Debug 构建完全零警告”尚未满足，本次未为视觉任务添加无关 App Intents 依赖或关闭诊断。
- 已保存 59 张 PNG：6 张基础分支对比图、50 张固定样例新版图、3 张真实 Gemini 测试图。覆盖所需全部状态的浅深色、最大字号，以及横屏手写和长回答。索引链接与 PNG 横竖尺寸均核对通过，重点状态逐张检查，剩余状态通过缩略图总览检查。
- 总览复核修复了深色玻璃页码/浮条前景过淡的问题，使用系统材质前景与暗色染色，并更新阅读界面截图。
- 最大字号下修复了菜单动作挤成竖排和勾号过大的问题。卡片与批注预览使用系统语义字号，未限制 Dynamic Type 上限。
- 所有 `positions()`、`MarginLayout.stack`、持久化枚举名称和功能模块保持原有逻辑；`git diff --check` 通过。
- **尚未声明通过**：真机 Apple Pencil、实际 Split View / 台前调度窗口缩放、VoiceOver 全流程，以及原有多条长卡片在当前视口之外的完整阅读体验。它们不由静态截图或单测替代。

构建及测试证据位于本机 `/tmp/ginkgo-visual-app-tests-build.log`、`/tmp/ginkgo-visual-app-tests.log`、`/tmp/ginkgo-visual-tests.log` 和 `/tmp/Ginkgo-Visual-Final-Tests.xcresult`。


## 真实 Gemini 补充验证（2026-11-21）

在用户授权后，用临时进程环境传入开发测试 key，没有写入代码、文件、钥匙串或截图。

- GinkgoAI 原有 `LiveProviderTests` 的 Gemini 流式翻译用例通过，模型为当前默认的 `gemini-3.5-flash`；其他两家未提供 key，未调用，不算它们的在线验证。
- 模拟器 App 通过原有 `demoAnnotate` 入口调用 Gemini；翻译、解释、提问三条批注均返回中文内容。检查了等待与已返回内容共存的画面，以及最终回答的浅深色排版。
- `reader-live-gemini-mixed-light.png` 是真实等待/已返回内容并存的时刻；`reader-live-gemini-review-light.png` 和 `reader-live-gemini-review-dark.png` 是三条请求均已返回后的画面。其余原有截图仍是固定样例。
- 验证结束已终止携带 key 的模拟器进程，恢复不含 key 的书库进程。仓库源文件和文档的密钥特征扫描无匹配。

这次补充仅增加实拍与验证说明，没有更改 AI、界面或数据逻辑。

## 审核后的调整（Claude，2026-11-21）

- 深色模式的批注卡片改用单独的 `Theme.card`（炭灰 `#3A3843`），比面板用的 `Theme.paper` 浅一档；深色下浮起卡片的阴影从 0.18 降到 0.10。卡片压在白色书页上，原来的近黑色太重。
- 页码移到批注层下面：底部的卡片盖住页码，而不是页码压在卡片上。
- 出错卡片只显示一句中文摘要（例如「额度用完了，约 4 小时后可以再试。」），服务商的完整报错写进系统日志（`com.kenjia.ginkgo` / `ai`）。
- 截图从 59 张 PNG（40MB）精简为 10 张 JPEG。
