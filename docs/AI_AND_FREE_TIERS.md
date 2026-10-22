# AI、免费额度与服务成本

核对日期：2026-10-21。提供商可调整模型、区域资格、额度、速率限制和价格，实际以自己的控制台与官方规则为准。

## 可以从哪些免费额度开始？

- **基础记录不要求 AI Key**：配置自己的 Firebase 后，可先使用笔记、任务等基础能力；不配置 DeepSeek Key 时，社区版跳过自动 AI 日报弹窗。
- **Firebase Spark**：Cloud Firestore 的免费额度按项目计算，包括有限的存储和每日操作次数。达到限制后的处理遵循官方规则，不代表无限容量或永久免费托管。[官方额度](https://firebase.google.com/docs/firestore/quotas)
- **Gemini API 免费层**：官方目前为 Gemini 2.5 Flash 标准 API 列出免费层，仍有速率、账号与地区限制。可在 [Google AI Studio](https://aistudio.google.com/api-keys) 创建自己的 Key，核对可用模型和 [Billing](https://ai.google.dev/gemini-api/docs/billing)。[官方价格表](https://ai.google.dev/gemini-api/docs/pricing)
- **WebDAV**：可以使用自己的坚果云免费账号或其他服务，但空间与流量由所选套餐限制，本项目不提供共享空间。

## 代码现在把请求发给谁？

| 提供商 | 当前主要用途 | 是否可以直接宣称免费 |
| --- | --- | --- |
| DeepSeek `deepseek-flash` | 文本问答、划词处理、内容整理，以及文献 / 新闻 / 股票等 AI 分析 | 不能。模型 API 按用量计费；若账号有赠送余额，会按平台规则抵扣。 |
| Gemini `gemini-2.5-flash` | 可选音频转写 | 可按自己的免费层资格和限额使用，但不保证所有账号、地区或将来的模型都免费。 |

[DeepSeek 官方计费规则](https://api-docs.deepseek.com/quick_start/pricing/)明确区分模型用量计费和其他接口计费。网页聊天产品是否免费，不能推导出 API 也免费。

当前主要文本功能不会因为只填 Gemini Key 就自动改用 Gemini。统一多提供商路由属于后续可以贡献的方向，不作为当前已经实现的功能宣传。

## Key 与隐私

Key、云盘应用密码和桌面 OAuth 配置由使用者自己申请，保存在设备安全存储中。不要把它们提交到 Git、Issue、截图或公开配置示例。改配置后彻底退出重启，费用和用量应在对应提供商控制台核实。

Google 的免费 API 层与付费层在数据使用政策上也可能不同；官方价格页列明免费层相关请求可能用于改进产品。发送私人笔记或音频前，请先确认适用政策与自己的数据要求。

## ChatGPT / Codex 权益与应用 API 的区别

ChatGPT Pro / Codex 会员权益不自动转成此应用使用 DeepSeek 或 Gemini 的免费额度。OpenAI 的 [Codex for Open Source](https://developers.openai.com/community/codex-for-oss) 是维护者支持计划，申请需审核；其中 API credits 与会员权益是分别说明的支持内容。本项目不提供兑换码，也不宣称已获得该计划支持。
