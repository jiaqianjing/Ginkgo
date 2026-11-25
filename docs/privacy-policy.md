# Ginkgo 隐私政策（草稿）

> 草稿，2026-11-25。上架前需要放到一个公开网址（App Store Connect 的「隐私政策网址」要填），并补上联系方式。
> 放在哪里由开发者决定。

最后更新：（发布时填写）

## 简单说

Ginkgo 没有自己的服务器，也没有账号系统。你的书、划线、批注和笔迹都只保存在你的设备上。只有你使用 AI 功能时，相关文字才会离开设备，直接发给你自己选的 AI 服务商。

## 保存在设备上的内容

- 你导入的 PDF 文件。
- 划线、高亮、批注、AI 回答、手写笔迹和草稿纸。
- 设置项：工具、颜色、AI 服务商、模型、回答语言、外语水平。
- 你填写的 AI 服务 API key，保存在系统钥匙串里。

这些内容不会上传给开发者。删除 App 时会一并删除。

## 发给 AI 服务商的内容

你在书里使用翻译、解释、提问、追问或语法分析时，Ginkgo 会把下面这些内容，用你自己的 API key 直接发给你在设置里选的服务商（OpenAI、Anthropic 或 Google Gemini）：

- 你选中的原文，以及它前后的几段文字；
- 书名；
- 你的问题和之前的追问；
- 回答语言和外语水平这两项设置。

第一次向某家服务商发送之前，Ginkgo 会先说明并征得你的同意。你可以随时在「设置 → AI 服务」里关掉，关掉后下次使用 AI 时会再问你。

这些请求不经过开发者的任何服务器，开发者看不到也不保存它们。服务商如何处理这些数据，以它们各自的政策为准：

- OpenAI：https://openai.com/policies/privacy-policy/
- Anthropic：https://www.anthropic.com/legal/privacy
- Google Gemini API：https://ai.google.dev/gemini-api/terms （注意：Gemini 免费额度下提交的内容，Google 可能用于改进其产品）

## 不做的事

- 不收集使用数据或分析数据，不做广告追踪。
- 不把你的数据卖给或分享给任何其他第三方。

## 联系

（联系方式待填）

---

# Ginkgo Privacy Policy (draft)

Ginkgo has no server and no accounts. Your books, marks, notes and handwriting stay on your device. Text leaves the device
only when you use an AI feature, and then it goes straight to the AI service you chose (OpenAI, Anthropic or Google
Gemini), using your own API key: the passage you selected and the paragraphs around it, the book title, your question and
earlier follow-ups, and your answer-language and learner-level settings. Ginkgo asks for your permission before the first
request to each service; you can withdraw it in Settings › AI. The developer never receives or stores this text. Each
service handles it under its own policy (links above). Ginkgo does no tracking or advertising and shares nothing with
anyone else.
