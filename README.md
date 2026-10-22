# SyncNote Community

### 记录生活，连接知识，让 AI 参与真正的工作流程。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Community checks](https://github.com/Dr-xu193/syncnote-community/actions/workflows/checks.yml/badge.svg)](https://github.com/Dr-xu193/syncnote-community/actions/workflows/checks.yml)
[![Platforms](https://img.shields.io/badge/Windows%20%7C%20Android-Flutter-6757FF)](https://github.com/Dr-xu193/syncnote-community/releases)

**一个将个人记录、任务管理、知识库、AI 私人助理与研究工具连接起来的开源工作台。**

在手机上记下想法、录音或任务，在电脑上继续整理；把网页、论文和研究结论沉淀成笔记，再围绕这些资料与 AI 连续对话。SyncNote 希望让信息从“保存下来”走向“理解、关联和行动”。

**双端同步 · Markdown 与知识图谱 · 有记忆的 AI 对话 · 文献阅读工作流 · 可回看的 AI 模拟操盘 · 分层存储与完整备份**

[下载安装](https://github.com/Dr-xu193/syncnote-community/releases) · [完整功能手册](docs/FEATURES.md) · [首次配置](docs/SETUP.md) · [AI 与免费额度](docs/AI_AND_FREE_TIERS.md) · [提交建议](https://github.com/Dr-xu193/syncnote-community/issues)

> 社区版由个人使用版本整理而来，当前为早期公开预览。使用者连接自己的 Firebase、WebDAV 和可选 AI 服务；安装包不包含共享后台、默认账号或作者的私人凭据。

## 从一次记录，到一套个人知识流程

| 你想完成的事 | SyncNote 提供的流程 |
| --- | --- |
| 随手抓住一个想法 | 文字、图片、录音和涂鸦 → 备忘录 → AI 提炼与整理 → 转为后续记录或行动 |
| 把事情真正推进 | 任务状态、优先级、截止时间、多次提醒、重复任务、子任务与筛选 |
| 让笔记产生联系 | Markdown 编辑与预览 → 分类和标签 → 双向关联入口与关系图谱 → 全局搜索 |
| 找到并读懂文献 | 输入研究方向 → 多源检索与相关性排序 → 摘要解读 / 开放 PDF 深读 → 收藏、摘录、阅读状态与笔记 |
| 与自己的资料对话 | 指定资料范围、会话专属资料与长期记忆 → 连续问答 → 查看本轮来源与用量 |
| 观察 AI 如何决策 | 免费行情与新闻资料 → AI 研究和目标组合 → 独立 Python 模拟执行 → 逐日日记、周报与期末复盘 |
| 长期保管而不只堆积 | 分页读取、归档与冷归档、容量参考、版本历史、完整 ZIP 备份及恢复 |

## 主要能力

### 1. 记录与任务：适合每天打开的基础工作区

- **备忘录**：快速记录、置顶、图片/语音附件与 AI 整理入口，列表通过摘要展示降低长内容的浏览负担。
- **任务**：待办 / 进行中 / 已完成，优先级与日期、多提醒、重复规则、子任务、标签、归档和时间筛选；支持 AI 辅助排序。
- **知识库笔记**：Markdown 编辑和预览、代码块高亮、分类标签、Wiki 风格笔记关联与关系图谱；提供有限历史版本和云端编辑冲突处理。
- **日记**：日期与心情记录、媒体附件、AI 分析；可选晨间简报和晚间复盘。
- **平台体验**：Windows 托盘与快捷记录，Android 分享入口、桌面小组件和提醒权限入口。后台提醒效果仍受系统权限与厂商策略影响。

### 2. AI 助手：围绕个人资料，而不只围绕一条提示词

- **划词 AI**：在已接入的输入框和可选中文本中，选中文字后唤起润色、结构化整理、中英互译或扩写；可复制结果或在支持的编辑器中替换原选区。
- **连续对话**：多个云端会话、历史消息、资料范围选择、用户可管理的长期记忆与会话专属资料。
- **资料检索与来源**：结合相关笔记、任务、日记等资料构建上下文，界面显示本轮来源；上下文受预算与检索结果影响，不承诺无限记忆或每次读取整个知识库。
- **多媒体整理**：图片文字识别、可选语音转写，以及网页 / 视频链接中可取得正文或字幕的提炼；支持大纲、深度总结与行动指南等输出方向。
- **用量可见**：提供调用量、Token 与估算费用信息，以及预算提醒入口。

### 3. 文献工作台：从“找到文章”继续走到“形成自己的理解”

- 按今天的研究问题或关键词搜索，不局限于固定研究方向。
- 接入 OpenAlex、Semantic Scholar、Crossref、arXiv、Europe PMC 等公开来源，结合主题、概念和相关性组织候选。
- 分别查看基于摘要的核心解读，以及取得开放 PDF 后的深度解读，避免把摘要解读冒充全文阅读。
- 收藏文献、记录阅读状态、标签和备注；保存深度解读、管理摘录，并转为 Markdown 研究笔记。
- 查看参考文献、后续引用和相关研究，沿文献关系继续探索。
- 开放 PDF 可在应用内预览，并保存到自己的 WebDAV 云文件；不提供绕过付费墙的下载。

### 4. 探索中心：新闻、思维模型和逻辑训练

- **新闻**：多主题、多来源聚合，正文提取、来源链接、当日快照和主动刷新，适合将阅读内容继续整理进个人知识库。
- **知识卡片**：当前内置 **168 条**思维模型与知识条目，围绕定义、底层逻辑和应用场景组织内容。
- **逻辑谜题**：当前内置 **100 个**谜题条目，提供阶段式作答、AI 评分反馈和进度记录。
- 阅读与训练内容、AI 判断都允许被质疑与校正；来源覆盖和评估能力仍在持续改善。

### 5. 股票研究实验室：观察研究、选择与执行之间的关系

- 行情雷达、自主搜索、K 线和确定性指标、可复现筛选器、关注池、研究记录、组合计划与模拟盘。
- 独立的 **1000 元 / 30 天 AI 虚拟账户实验**：AI 通过只读工具研究候选、新闻及历史日记，提交完整目标组合。
- **Flutter 负责交互和研究，Python 内核负责模拟执行**：区分研究目标、待执行意图、模拟成交和拒单，记录整手、现金、手续费等约束的影响。
- 每天的 JSON 日记保留研究理由、放弃的选择、不确定性、预期、执行事件和账户变化，并可生成周报与期末复盘。
- 这一模块用于个人研究和观察 AI 决策，不连接券商。当前尚未完整覆盖分红、红利税与全部公司行为，不能把模拟结果当作经过验证的投资收益。

### 6. 文件与数据：为跨设备和长期使用设计

- WebDAV 云文件上传、下载和跨设备访问；提供 PDF、文本、图片及支持格式的 Office 内容预览，具体还原能力以格式和解析器为准。
- Firebase 管理结构化记录，WebDAV 承载附件、文件和归档正文，减少把大文件塞入数据库的需要。
- 归档、冷热分层、容量参考和按需恢复；保留关联与索引，帮助在较大数据量下继续查找内容。
- 完整 ZIP 备份 / 恢复包含程序管理的数据及关联附件，用于迁移和灾难恢复；仍应定期验证自己的备份。
- 社区版凭据通过平台安全存储保存在当前设备，默认不随笔记备份上传。数据去向见 [PRIVACY](PRIVACY.md)。

## 免费额度与使用成本

**源码采用 MIT 免费开放；外部服务的费用和额度由各自提供商决定。** 基础记录功能不要求填写 AI Key，可以先从自己的免费云服务额度开始使用。

| 服务 | 当前应用用途 | 免费层与费用说明 |
| --- | --- | --- |
| Firebase Spark | 登录、笔记 / 任务等结构化数据 | Cloud Firestore 提供有限免费额度，官方当前列出 1 GiB 存储、每天 50,000 次读取和 20,000 次写入；按项目而非按每位用户计算，详见[官方额度](https://firebase.google.com/docs/firestore/quotas)。 |
| Gemini API | 当前主要用于可选音频转写 | Gemini 2.5 Flash 的标准 API 有免费层，仍受账号、地区、模型和速率限制影响；可在 [Google AI Studio](https://aistudio.google.com/api-keys) 创建自己的 Key，先核对[官方计费说明](https://ai.google.dev/gemini-api/docs/billing)与[价格表](https://ai.google.dev/gemini-api/docs/pricing)。 |
| DeepSeek API | 主要问答、内容整理和研究分析 | 当前模型 API 按量计费。有赠送余额时可按平台规则抵扣，但不能视为永久免费的公共服务，见[官方价格](https://api-docs.deepseek.com/quick_start/pricing/)。 |
| WebDAV | 文件、媒体附件和冷归档 | 使用自己的坚果云或兼容服务账号；空间与流量取决于所选账号套餐，项目不赠送共享云盘空间。 |

**仅配置免费 Gemini Key，不会自动让目前调用 DeepSeek 的问答、文献或股票模块切换为 Gemini。** ChatGPT / Codex 会员权益也不等于本应用获得免费的模型 API。更多说明和隐私注意事项见 [AI 与免费额度指南](docs/AI_AND_FREE_TIERS.md)。

## 下载与运行

从 **[官方 Releases](https://github.com/Dr-xu193/syncnote-community/releases)** 下载社区预览包：

- **Android**：`syncnote-community-0.1.0-android.apk`，包名 `com.syncnote.community`。
- **Windows x64**：`syncnote-community-0.1.0-windows-x64.zip`，完整解压后运行 `syncnote-community.exe`。DLL 与 `data/` 必须保留；需要 Windows 10/11 x64 和 Microsoft Visual C++ 2015–2022 x64 运行库。

首次启动按 **[SETUP](docs/SETUP.md)** 连接自己的服务。配置可在登录页或设置菜单中修改；修改后彻底关闭再重启。两端使用同一 Firebase 项目和同一 Google 账号，即可访问该账号的云端记录。

需要 Python 量化功能时，先安装 Python 3.11+，再运行包内 `setup_quant_windows.cmd`。普通记录功能不依赖 Python。完整边界见 [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md)。

## 面向开发者

技术基础为 **Flutter / Dart + Firebase + WebDAV + 可选 AI 服务 + Python 执行内核**。界面、数据模型、服务层和研究工具分层组织，提供 Flutter 与 Python 测试及 GitHub Actions 检查。

```powershell
git clone https://github.com/Dr-xu193/syncnote-community.git
cd syncnote-community
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

推荐 Flutter 3.44.x / Dart 3.12.x。Android 需要 JDK 17、Android SDK 和自己的 Release 签名；Windows 需要 Visual Studio 2022 C++ 桌面开发工作负载。完整步骤见 [BUILD](docs/BUILD.md)，架构与项目价值概览见 [PROJECT_OVERVIEW](docs/PROJECT_OVERVIEW.md)。

## 一起把它做得更好

欢迎体验者、学生、研究者和开发者分享真实使用场景。特别欢迎以下方向的建议与贡献：

- 文献匹配、引用关系与 PDF 阅读体验；
- 新闻来源覆盖、正文清洗和可追溯性；
- AI 检索、连续上下文、工具调度与费用控制；
- Android 后台提醒与跨平台交互；
- 备份恢复、数据规模与存储可靠性；
- 模拟执行中的公司行为核算、证据记录和可解释性。

[报告问题或提建议](https://github.com/Dr-xu193/syncnote-community/issues) · [贡献指南](CONTRIBUTING.md) · [安全反馈](SECURITY.md)

提交截图、日志和示例前，请移除个人内容与凭据。仓库从公开社区版的新历史开始，不包含作者私人 Git 历史、账号密钥、签名私钥或个人数据。自有代码采用 [MIT](LICENSE)，第三方组件保留各自许可，见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。
