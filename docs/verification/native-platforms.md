# 原生平台整合验证

## 操作与布局

- 手机保持单页导航；宽度达到 900 时，作品工作区显示目录与正文预览。目录支持拖动、键盘方向键和辅助功能增减操作，宽度保存在本地设置中。
- macOS 使用原生应用、文件、编辑和窗口菜单；Windows/Linux 显示应用内菜单。文字编辑菜单向当前焦点发送标准编辑操作。
- `Ctrl/Cmd+S` 立即保存正文；`Ctrl/Cmd+N` 新建作品；`Ctrl/Cmd+O` 打开创作资源库；`Ctrl/Cmd+,` 打开设置；`Ctrl/Cmd+Shift+F` 搜索所有作品的当前分支。阅读器中 `Ctrl/Cmd+F` 只搜索正在阅读的分支。
- 全文搜索包含归档作品，结果上限 200 条，仅检索作品元信息和正文，不把 Agent 对话作为小说内容。
- 应用暂停时尝试保存，保存错误显示在界面。收到可取消的系统退出请求后等待保存；失败时取消退出。系统强制结束进程不能被这一机制拦截，后台长任务仍需可选远程执行器。
- 字体跟随系统缩放。书架卡片随字体增高，分类和外观选项可换行；360×800、200% 字体的书架及设置通过界面测试。
- 阅读器配色与应用外观独立；深色应用中的纸色页面使用浅色按钮配色，已用回归测试验证主要操作文字与背景对比度不低于 4.5:1。
- 平台图标使用同一矢量书页图案生成；运行 `flutter test tool/generate_icons.dart` 可以重新输出 Android、iOS、macOS、Windows 和 Linux 的图标资源。

## 平台权限与存储

| 平台 | 配置 |
| --- | --- |
| Android | 正式 manifest 包含联网权限；允许用户配置的 HTTP 模型端点；导入使用系统选择器，导出使用系统分享，不申请整个存储目录权限。禁用系统云备份和设备迁移，避免复制无法同时迁移 Keystore 密钥的本地密文；使用加密作品备份迁移。 |
| iOS | 使用系统文件选择与分享；声明连接用户配置的局域网服务的用途及本地网络 ATS 例外；密钥存于 Keychain。 |
| macOS | 沙箱中启用网络客户端和用户选择文件的读写权限；调试额外保留 Flutter 所需的 JIT/本地服务权限。使用登录 Keychain，不启用跨应用密钥共享。窗口位置与大小由系统保存，最小窗口 480×540。 |
| Windows | 系统文件选择、保存与系统安全存储插件；桌面菜单和硬件快捷键。 |
| Linux | 系统文件选择与 Secret Service 插件；运行环境需要可用的桌面密钥环。 |

macOS 的 `usesDataProtectionKeychain: false` 仍使用系统 Keychain，避免本地未配签名的开发构建依赖 provisioning profile。没有在安全存储失败时退回明文的路径。

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

`native_smoke_test.dart` 使用单独临时资料库和临时密钥：验证真实平台密钥读写删除、SQLite 文件保存、编辑到阅读、关闭后重开数据库。测试代码不会打开正式作品库或发送模型请求。原生测试工具会安装及清理测试应用，应在开发模拟器上运行。`native_verification.dart` 驱动器在清理前将工作区及阅读器截图传回宿主，保存到本目录。

2026-10-13 的结果：

- macOS arm64 / Xcode 26.4.1：原生构建及上述集成流程通过，截图已检查。测试启动器报告无法把窗口置前，但应用内测试和截图均完成。
- 截图驱动器通过 VM Service 收集结果；macOS 没有 `integration_test` 的 XCTest 结果上报插件，命令中关闭重复的原生测试框架上报，不影响驱动器的失败判定与截图收集。
- iOS 26.4 / iPhone 17 模拟器：构建、系统 Keychain、SQLite、编辑与阅读流程通过；手机截图已检查。
- Android API 36 / arm64 模拟器：APK 构建、系统安全存储、SQLite、编辑与阅读流程通过；手机截图已检查。首次运行的原生文件保存较慢，测试改为等待工作区实际出现后继续，不能仅用帧动画停止来判断 I/O 完成。
- 界面测试：快捷保存、失败退出保护、面板宽度持久化、阅读器快捷搜索、阅读器对比度和手机大字体六项通过。
- 完整 Flutter 界面套件 25 项通过，`flutter analyze` 无问题。macOS Release 构建为 61.6 MB；Android Release APK 构建为 75.9 MB，包含标准目标 ABI，正式 manifest 的联网和备份配置已核验。
- Windows/Linux 需要对应宿主的构建与运行检查；本机未验证原生二进制，不能将 Windows 布局模拟当作 Windows 原生验证。
- 本地开发构建未做商店签名、发布或 macOS 公证。
- Android Release 当前使用开发签名，仅供本地验证。各平台 Flutter 原生构建应依次执行；集成测试与正式构建会重写共享的插件注册文件，同时运行可能把测试插件混入正式构建。

截图：[Android 工作区](native-android-workspace.png)、[Android 阅读器](native-android-reader.png)、[iOS 工作区](native-ios-workspace.png)、[iOS 阅读器](native-ios-reader.png)、[macOS 工作区](native-macos-workspace.png)、[macOS 阅读器](native-macos-reader.png)。

依据：[Flutter 可取消退出](https://api.flutter.dev/flutter/widgets/AppLifecycleListener/onExitRequested.html)、[macOS 构建与沙箱](https://docs.flutter.dev/platform-integration/macos/building)、[安全存储插件平台配置](https://pub.dev/packages/flutter_secure_storage)。
