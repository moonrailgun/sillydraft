# 原生平台整合验证

## 操作与布局

- 手机保持单页导航；宽度达到 900 时，作品工作区显示目录与嵌入的阅读器（与独立阅读器同一实现，目录和阅读位置互相同步）。目录支持拖动、键盘方向键和辅助功能增减操作，宽度保存在本地设置中。
- macOS 使用原生应用、文件、编辑和窗口菜单；Windows/Linux 显示应用内菜单。文字编辑菜单向当前焦点发送标准编辑操作。
- `Ctrl/Cmd+S` 立即保存正文；`Ctrl/Cmd+N` 新建作品；`Ctrl/Cmd+O` 打开创作资源库；`Ctrl/Cmd+,` 打开设置；`Ctrl/Cmd+Shift+F` 搜索所有作品的当前分支。阅读器中 `Ctrl/Cmd+F` 只搜索正在阅读的分支。
- 全文搜索包含归档作品，结果上限 200 条，仅检索作品元信息和正文，不把 Agent 对话作为小说内容。
- 应用暂停时尝试保存，保存错误显示在界面。收到可取消的系统退出请求后等待保存；失败时取消退出。系统强制结束进程不能被这一机制拦截，后台长任务仍需可选远程执行器。
- 字体跟随系统缩放。书架卡片随字体增高，分类和外观选项可换行；360×800、200% 字体的书架及设置通过界面测试。
- 阅读器配色与应用外观独立；深色应用中的纸色页面使用浅色按钮配色，已用回归测试验证主要操作文字与背景对比度不低于 4.5:1。
- 平台图标使用橙色「Silly」与酒红色「Draft」双层字标、白色圆角底；[SVG 与 PNG 源文件](../../assets/branding/README.md)位于 `assets/branding/`。运行 `flutter test tool/generate_icons.dart` 可以重新输出 Android、iOS、macOS、Windows 和 Linux 图标；iOS 输出无透明通道的白底，由系统应用圆角。

## 平台权限与存储

| 平台 | 配置 |
| --- | --- |
| Android | 正式 manifest 包含联网权限；允许用户配置的 HTTP 模型端点；导入使用系统选择器，导出使用系统分享，不申请整个存储目录权限。禁用系统云备份和设备迁移，避免本机明文密钥文件被复制到云端；使用加密作品备份迁移。 |
| iOS | 使用系统文件选择与分享；声明连接用户配置的局域网服务的用途及本地网络 ATS 例外；密钥存于应用数据目录的明文密钥文件，随设备备份一起备份，与数据库一致。 |
| macOS | 未启用 App Sandbox：本地订阅连接需要启动用户安装的 `claude`/`codex`，并让它们读取各自在用户目录与 Keychain 中的登录状态，沙箱内的子进程无法做到。网络客户端和用户选择文件权限保留在 entitlements 中，供日后恢复沙箱；调试额外保留 Flutter 所需的 JIT/本地服务权限。如需上架 Mac App Store，须恢复沙箱并在该版本中移除本地订阅。密钥存于应用数据目录的明文密钥文件，权限为仅本人可读写，不再使用 Keychain。窗口位置与大小由系统保存，最小窗口 480×540。 |
| Windows | 系统文件选择与保存；密钥存于应用数据目录的明文密钥文件；桌面菜单和硬件快捷键。 |
| Linux | 系统文件选择；密钥存于应用数据目录的明文密钥文件，权限为仅本人可读写。全新安装不需要桌面密钥环，旧安装只在迁移旧密钥时访问一次。 |

所有平台的密钥（资源加密密钥、模型密钥、同步认证与口令）统一以明文 JSON 存在应用数据目录的 `secrets.json`，这是作者的选择：各平台行为一致，macOS 调试构建重新编译后也不再弹出钥匙串授权。该文件不进入作品备份、同步或导出，数据库也拒绝在设置中保存凭据。旧版本存在系统钥匙串或 Keystore 中的密钥会在启动时迁移一次并从钥匙串删除；迁移被拒绝时下次启动重试，迁移完成前缺失的密钥仍按需从钥匙串读取，读取被拒绝时报错而不是当作没有密钥，避免重新生成资源密钥导致已导入的 ST 原文件无法解密。

## 可复现检查

```sh
flutter analyze
flutter test test --reporter expanded
flutter test integration_test/native_smoke_test.dart -d macos --reporter expanded
flutter test integration_test/native_smoke_test.dart -d <ios-simulator-id> --reporter expanded
flutter test integration_test/native_smoke_test.dart -d <android-device-id> --reporter expanded
flutter build apk --debug
flutter drive --driver=test_driver/native_verification.dart \
  --target=integration_test/native_smoke_test.dart \
  --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false -d <device-id>
```

`native_smoke_test.dart` 使用单独临时资料库和临时密钥：验证本机密钥文件读写删除、SQLite 文件保存、编辑到阅读、关闭后重开数据库，以及已采纳正文的标题/列表/引用和 ST 显示正则。macOS 同时验证原生原子保存通道的新建、替换及读回。测试代码不会打开正式作品库或发送模型请求。原生测试工具会安装及清理测试应用，应在开发模拟器上运行。`native_verification.dart` 驱动器在清理前将工作区、阅读器及预设编辑截图传回宿主，保存到本目录。

2026-10-13 最终审查修复后的结果：

- macOS arm64 / Xcode 26.4.1、iOS 26.4 / iPhone 17 模拟器、Android API 36 / arm64 模拟器均通过上述原生流程。三平台阅读器截图已逐张检查，标题、编号列表、引用和显示正则呈现正常；保存内容仍是原正文。
- 每个平台都传回工作区、阅读器及 ST 提示词编辑页面截图。驱动器使用 VM Service 收集测试结果；macOS 未注册 XCTest 结果上报插件，命令中关闭重复上报，不影响失败判定与截图。
- macOS 另有 2 项 XCTest 通过，覆盖原子导出创建、替换及失败保留已有文件。`python3 tool/verify_macos_atomic_export.py` 在仅授予单文件写权限的系统沙箱中，验证旧的同目录临时写入被拒绝、新的 Foundation 同卷临时目录写法成功；未声称自动操作过 NSSavePanel。
- Flutter 界面套件 33 项通过；核心 90 项、服务端 9 项通过。三个分析器无问题，137 个 Dart 文件格式检查通过。
- Android 调试模拟器在键盘动画中报告丢帧；本次未进行性能基准测试。iOS 系统分享打开有既有原生证据，系统“存储到文件”的最终点击未自动化验证。
- Windows/Linux 平台工程及 CI 已提供，本机未验证对应原生二进制。远程 CI 尚未发布运行；本地开发包未做商店发布或 macOS 公证。

Android Release 需要正式签名配置，或显式设置 `SILLYDRAFT_DEVELOPMENT_SIGNING=true` 进行本地开发签名验证；未配置签名的 Release 已确认会被拒绝。正式签名和发布命令见 [构建说明](../building.md)。原生测试与生产构建必须按平台顺序运行，避免竞争共享的插件注册文件。

审查修复后的生产入口构建全部通过：macOS Release 61.8 MB、Android Release 开发签名 APK 76.2 MB、iOS 模拟器 Debug 应用。安装包路径为 `build/macos/Build/Products/Release/SillyDraft.app`、`build/app/outputs/flutter-apk/app-release.apk`、`build/ios/iphonesimulator/Runner.app`。APK 签名校验通过，macOS 包的沙箱、网络客户端和用户选择文件读写权限已核验。

截图：[Android 工作区](native-android-workspace.png)、[Android 阅读器](native-android-reader.png)、[Android 预设](native-android-preset.png)、[iOS 工作区](native-ios-workspace.png)、[iOS 阅读器](native-ios-reader.png)、[iOS 预设](native-ios-preset.png)、[macOS 工作区](native-macos-workspace.png)、[macOS 阅读器](native-macos-reader.png)、[macOS 预设](native-macos-preset.png)。

依据：[Flutter 可取消退出](https://api.flutter.dev/flutter/widgets/AppLifecycleListener/onExitRequested.html)、[macOS 构建与沙箱](https://docs.flutter.dev/platform-integration/macos/building)、[安全存储插件平台配置](https://pub.dev/packages/flutter_secure_storage)。
