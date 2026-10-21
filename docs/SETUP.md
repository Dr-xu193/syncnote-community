# 配置自己的服务

公开安装包首次启动显示配置页。在 Firebase 与 Google 登录必填项完成前，应用不会初始化 Firebase、运行股票调度器或连接 WebDAV。

## 1. Firebase 与 Google 登录

1. 在 [Firebase 控制台](https://console.firebase.google.com/) 创建自己的项目，选择适合自己的套餐。本程序按 Spark 免费方案设计，不需要部署 Cloud Functions。
2. 在 Authentication → Sign-in method 启用 Google 登录；创建 Cloud Firestore 数据库。
3. 将仓库的 `firestore.rules` 和 `firestore.indexes.json` 部署到自己的项目。规则以登录用户 UID 隔离数据；不要为了测试改为公开读写。也不要把它们直接覆盖到存有其他应用数据的项目。
4. Android 添加包名 **`com.syncnote.community`** 的应用；使用官方 APK 时，将 Release 附带的签名指纹登记到你的 Firebase 项目。自行构建时登记自己的签名指纹。
5. Windows 使用 Firebase Web 应用的配置。Google Cloud 中还需要创建“桌面应用”OAuth 客户端，并配置同意屏幕/测试用户；此项目桌面登录使用本机回调端口 8000。
6. 在配置页填写 Project ID、API Key、App ID、Messaging Sender ID。App ID 必须对应当前平台，Windows 与 Android 的 App ID 不能互换。Auth Domain 和 Storage Bucket 按控制台提供的值填写即可。
7. Android 的 Google Server Client ID 填 Web OAuth 客户端 ID（不是 Android 客户端 ID）；Windows 填自己的 Desktop Client ID 与 Client Secret。

使用同一个 Firebase 项目和同一个 Google 账号，可以在两端看到该账号的数据。不同 UID 的数据按 Firestore 规则隔离。安装包不提供原作者账号，也不会自动加入任何现有项目。

## 2. WebDAV（云文件、附件与冷归档）

以坚果云为例，开启第三方应用管理，创建专用应用密码。填写 `https://dav.jianguoyun.com/dav/`、自己的账号和应用密码。其他兼容 WebDAV 的服务可填写自己的 HTTPS 根地址。

应用使用 `SyncNote_Attachments/` 目录。使用独立账号或独立存储空间，不要把多人凭据指向未经隔离的同一目录。Firebase 的 UID 规则不会替 WebDAV 实现多用户文件权限。

## 3. AI（可选）

填写自己的 DeepSeek API Key，主要功能使用 `deepseek-flash`。Gemini API Key 用于可选音频转写，服务可用性与额度需自行确认。未配置 AI 时仍可使用已配置 Firebase 的基础记录功能。

API 请求会将当前功能选取的内容发送给对应服务商。先了解相关隐私政策与计费方式；不要提交不允许传出的资料。

## 保存与修改配置

配置通过 `flutter_secure_storage` 使用平台安全存储保存，不写入 Firestore 或 WebDAV。修改配置后请完全退出再重新打开。Windows 关闭按钮有托盘和彻底关闭两个选项，必须选择彻底关闭。

切换后端前先备份旧数据。换后端不会自动迁移数据；换设备也不会自动同步本机服务凭据。卸载应用可能清除本机配置，需重新填写。

Android 的通知、精确闹钟和厂商后台权限需要使用者在系统中授权；操作系统限制仍可能影响后台同步。网络必须能访问自己使用的 Firebase、Google 与 AI 服务。
