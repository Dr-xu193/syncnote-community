# SyncNote Community

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

一个使用 Flutter 构建的个人记录、知识管理与研究工作台，支持 Windows 和 Android。

这里是独立的公开社区版，欢迎体验、阅读源码、提出建议和参与开发。社区版没有共享后台、共享 AI 余额或默认云盘账号；安装后需要配置自己的 Firebase，云文件与 AI 服务按需配置。安装包不会连接原作者的私人服务。

## 下载与安装

前往 **[Releases](https://github.com/Dr-xu193/syncnote-community/releases)** 下载：

- **Android**：`syncnote-community-0.1.0-android.apk`，安装后按首次启动页面配置服务。包名为 `com.syncnote.community`。
- **Windows x64**：`syncnote-community-0.1.0-windows-x64.zip`，完整解压后运行 `syncnote-community.exe`。不要只复制 EXE；DLL 和 `data/` 也必须保留。需要 Windows 10/11 x64 和 Microsoft Visual C++ 2015–2022 x64 运行库。

社区版与私人版本使用独立应用标识和 Android 签名，可以并存。它们不会自动继承对方的本地配置。

首次使用请阅读 **[服务配置指南](docs/SETUP.md)**。应用设置菜单和登录页都有“服务配置”入口。配置保存在当前设备的系统安全存储中，不作为笔记或完整 ZIP 备份上传。

## 主要功能

| 模块 | 能做什么 |
| --- | --- |
| 备忘录、任务、笔记、日记 | 分类标签、搜索、归档、回收站、关联笔记和任务提醒 |
| 云文件 | WebDAV 上传、跨设备访问、支持格式的内存预览 |
| AI 助手 | 选中文字调用 AI、记录问答、日记/任务相关分析 |
| 探索中心 | 新闻阅读、文献检索与解读、知识卡片、逻辑谜题 |
| 股票研究 | 免费公开行情、K 线、研究记录、关注池和虚拟账户实验 |
| 数据管理 | 完整 ZIP 备份/恢复、容量审计、坚果云冷归档 |

Firebase 用于登录与结构化数据；WebDAV 用于附件、文件和归档。DeepSeek 用于主要 AI 功能，Gemini 用于可选语音能力。服务可用性、网络条件、免费额度和收费由各提供商决定，本仓库不提供代充或托管账号。

股票模块是个人研究及模拟实验，未接入券商。免费公开接口不等同于授权商业行情，数据可能延迟或中断；向多人提供行情服务前应另行取得适当授权。股票实验、新闻和文献功能仍在演进，具体已知限制见 [KNOWN_LIMITATIONS](docs/KNOWN_LIMITATIONS.md)。

## 从源码构建

需要 Flutter 3.44.x / Dart 3.12.x。Windows 构建需要 Visual Studio 2022 的“使用 C++ 的桌面开发”；Android 构建需要 JDK 17 与 Android SDK。

```powershell
git clone https://github.com/Dr-xu193/syncnote-community.git
cd syncnote-community
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Android Release 需要自己的签名密钥和环境变量，详见 **[构建与签名](docs/BUILD.md)**。仓库不包含签名私钥。独立 Python 量化内核位于 `quant_core/`，只有 Windows 中依赖该内核的量化/模拟功能需要额外安装 Python；普通记录功能不需要。

Windows 下载包附带内核源码。需要量化功能时先安装 Python 3.11+，再运行 `setup_quant_windows.cmd`；该步骤会创建本机虚拟环境，不会连接作者的账号。

## 反馈与贡献

- 使用 **[Issues](https://github.com/Dr-xu193/syncnote-community/issues)** 报告错误或提出建议，说明平台、版本、复现步骤与预期结果。
- 提交截图和日志前，请遮住笔记正文、账号、API Key、应用密码及个人文件路径。
- 欢迎小而聚焦的 Pull Request。请先阅读 [CONTRIBUTING](CONTRIBUTING.md)。
- 安全问题请按 [SECURITY](SECURITY.md) 说明反馈，不要在公开 Issue 中贴出有效凭据。

## 开源范围

本仓库采用 [MIT](LICENSE) 许可证，不包含作者的私人服务凭据、签名私钥、个人数据、内部交接文档、构建缓存及私人 Git 历史。第三方依赖保留各自许可证，详见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。
