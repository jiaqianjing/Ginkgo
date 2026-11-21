# Ginkgo 原型（iPad）

用 SwiftUI + PDFKit 写的最小 App，用来在真实的 iPad 尺寸和横竖屏下比较三种批注风格。

## 运行

```bash
cd Prototype && xcodegen && open GinkgoPrototype.xcodeproj
```

选一个 iPad 模拟器运行即可。示例 PDF 在启动时用 Core Text 排版生成，是可以搜索、可以选中文字的真 PDF。左上角可以打开自己的 PDF（打开后批注清空）。

## 能试什么

- 顶部切换 **A 页边旁注 / B 一线一卡 / C 手写回应**，以及 **阅读 / 回顾** 模式。
- A 和 C 在页面右边留出页边栏（横屏更宽）。B 不留栏，记号画在书页自己的页边上，卡片浮在页面上。
- 长按选中文字，弹出 **翻译 / 解释 / 提问**，生成一条新批注。原型没有接模型，回答是示意文字。
- 点页面上的批注会激活对应卡片；阅读模式下点一下展开，再点收起。长按卡片可以删除。
- 右上角的笔：在页边栏里手写（模拟器里用鼠标），停笔约 1 秒后，笔迹会变成一个问题，挂到旁边那一行。Vision 识别手写文字，A / B 里显示识别结果，C 里保留笔迹。

## 截图用的启动参数

`-style sidenote|foldedMark|handwritten`、`-mode reading|review`、`-demoSelect "<文字>"`、`-demoCreate YES`、`-demoInk YES`。
`-orientation landscape` 只在 `UIRequiresFullScreen=YES` 的构建里有效（iPad 窗口模式不允许程序改方向）。

## 已知限制

- Pencil 的手感、悬停、捏笔杆都要在真机上试。
- C 风格的手写问题想用楷体显示。楷体是 iOS 的按需下载字体，没下载好时用系统字体代替。
- 笔迹只能写在页边栏里，还不能直接在书页上圈画。
