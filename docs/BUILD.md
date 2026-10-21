# 构建与签名

推荐 Flutter 3.44.x、Dart 3.12.x。执行 `flutter pub get` 后，可使用 `flutter analyze` 与 `flutter test` 检查项目。

## Android Release

创建自己保管的签名密钥（建议放在仓库外，命令会交互要求密码）：

```powershell
keytool -genkeypair -keystore C:\private-keys\community-release.jks -alias community -keyalg RSA -keysize 3072 -validity 10000
```

在当前终端设置以下环境变量，密码通过可信的本机秘密管理工具注入，不提交到仓库：

- `SYNCNOTE_COMMUNITY_KEYSTORE`：密钥文件的绝对路径
- `SYNCNOTE_COMMUNITY_STORE_PASSWORD`：密钥库密码
- `SYNCNOTE_COMMUNITY_KEY_ALIAS`：别名，默认 `community`
- `SYNCNOTE_COMMUNITY_KEY_PASSWORD`：密钥密码

```powershell
flutter build apk --release
```

也可双击 `build_android_release.cmd`。输出为 `build/app/outputs/flutter-apk/app-release.apk`。不依赖作者的 `debug.keystore`；发布更新时务必使用同一把社区版密钥，否则无法覆盖安装旧的社区版 APK。安装此 APK 前，自己的 Firebase 项目需要登记与此 APK 一致的 SHA-1 / SHA-256。

社区版运行时显式初始化 Firebase，不需要把 `google-services.json` 放入仓库。Android 调试构建使用本机调试签名，不需要上述 Release 环境变量。

## Windows x64

安装 Visual Studio 2022 的 C++ 桌面开发工作负载和 Windows SDK：

```powershell
flutter build windows --release
```

输出目录 `build/windows/x64/runner/Release/`，主程序为 `syncnote-community.exe`。分发时应打包整个目录及其中 Flutter 自动生成的第三方许可信息，不能只发 EXE。

社区版 Windows 包目前没有商业代码签名证书；请从项目自己的 Releases 下载，并使用发布页提供的校验文件核对下载完整性。

Windows 使用仓库内的 CMake 补丁修正 cloud_firestore 6.7.1 的持久缓存开关。升级该插件时应重新审查补丁；构建会在源码匹配失败时明确停止，而不是静默失效。

## 可选 Python 内核

需要 Python 3.11+，在源码根目录执行：

```powershell
python -m venv quant_core\.venv
quant_core\.venv\Scripts\python.exe -m pip install -e quant_core
```

Tushare、DuckDB 等扩展按 `quant_core/README.md` 安装。普通笔记功能不依赖它们。独立摆放 Windows 成品时，用 `SYNCNOTE_QUANT_HOME` 指向包含 `src/` 和 `.venv/` 的 `quant_core` 目录。
