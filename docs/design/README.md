# 视觉截图索引

设计说明见 [visual-notes.md](visual-notes.md)。这里只放 10 张关键状态（JPEG，模拟器实拍，AI 文本是本地固定样例）。完整的浅色、深色、最大字号截图不进仓库，需要时用脚本在本地重新生成：

```bash
python3 scripts/design-screens.py --group states --appearance dark --output /tmp/ginkgo-screens
```

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 书库 | [查看](screens/library-populated-light.jpg) | [查看](screens/library-populated-dark.jpg) |
| 竖屏回顾 | [查看](screens/reader-portrait-review-light.jpg) | [查看](screens/reader-portrait-review-dark.jpg) |
| 横屏回顾 | [查看](screens/reader-landscape-review-light.jpg) | |
| 选区浮条 | [查看](screens/selection-menu-light.jpg) | |
| 出错卡片 | [查看](screens/card-failed-light.jpg) | [查看](screens/card-failed-dark.jpg) |
| 批注列表 | [查看](screens/notes-panel-light.jpg) | [查看](screens/notes-panel-dark.jpg) |
