# 开发、测试和打包

基线是 Flutter 3.47.7 / Dart 3.13.5，依赖锁文件分别位于根目录、核心包与 server。使用 `--enforce-lockfile` 安装，升级依赖后重新运行完整测试。`flutter doctor -v` 检查本机目标工具链。

## 检查

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test test --reporter expanded
cd packages/sillydraft_core
dart pub get --enforce-lockfile
dart analyze
dart test --reporter expanded
cd ../../server
dart pub get --enforce-lockfile
dart analyze
dart test --reporter expanded
```

格式检查从仓库根目录运行：

```sh
dart format --output=none --set-exit-if-changed lib test integration_test test_driver tool packages/sillydraft_core/lib packages/sillydraft_core/test server/lib server/bin server/test
```

ST 对照数据可在核心包目录使用 Node 22 重新生成：`node tool/capture_st_reference.mjs`。该脚本只下载固定提交的 ST 源码，在空扩展环境中执行指定注入与指令格式函数。重新生成后先比较两个 reference JSON 的差异，再运行 `dart test test/st_compiler_test.dart`；不要无条件更新基准来掩盖兼容回归。

HTML 界面渲染依赖 `webview_flutter`（Android 需要 SDK 24+，iOS 13+，macOS 10.15+），Windows/Linux 没有对应平台实现，应用在这两个平台显示源码。真实网页视图只能在原生运行时验证：`flutter test integration_test/html_render_test.dart -d macos`。

`.github/workflows/verify.yml` 提供核心/界面/服务端测试、三个桌面系统构建、iOS 模拟器及 Android 构建，在分支推送和 PR 上运行。Actions 固定提交，Flutter 固定版本；工作流不包含上传商店步骤，不读取模型密钥。推送到用户自己的 GitHub 仓库后才会运行；工作流文件不代表 CI 已通过。发布版本见下文“发布”。

## Android

配置 Android SDK、SDK 许可和 JDK 21；本机验证使用 API 36、NDK 28.2.13676358。调试可运行 `flutter run -d <android-id>` 或 `flutter build apk --debug`。

正式签名可以复制 `android/key.properties.example` 为 `android/key.properties` 并填写，或设置环境变量 `SILLYDRAFT_KEYSTORE`、`SILLYDRAFT_STORE_PASSWORD`、`SILLYDRAFT_KEY_ALIAS`、`SILLYDRAFT_KEY_PASSWORD`。环境变量优先。相对 keystore 路径以 `android/` 为基准；文件及密钥已加入忽略规则。

```sh
flutter build appbundle --release
flutter build apk --release
```

没有完整正式签名配置时，Release 构建报错。仅为本地验证，可以明确使用开发签名：

```sh
SILLYDRAFT_DEVELOPMENT_SIGNING=true flutter build apk --release
```

该 APK 不属于商店交付包。发布者保管自己的上传密钥、设置应用标识和商店资料。依据：[Flutter Android 发布文档](https://docs.flutter.dev/deployment/android)。

## iOS 和 macOS

使用 macOS、Xcode 及目标 SDK。项目使用 Flutter 的 Swift Package Manager 集成。

```sh
flutter build ios --simulator --debug
flutter run -d <ios-simulator-id>
flutter build macos --release
flutter run -d macos
```

本机验证为 Xcode 26.4.1 / iOS 26.4 模拟器 / macOS arm64。真机 iOS 与 `flutter build ipa --release` 需要发布者设置 Team、证书和 provisioning。macOS 对外分发还需 Developer ID 签名及公证；本地构建不等于公证包。

macOS 在 `macos/Runner/Info.plist` 中设置 `FLTEnableImpeller=false`，使用 Skia（Metal），绕过 Flutter 3.47.7 下运行期间部分中文字形变成噪点或条纹的问题。这个设置需要重新构建并重启应用，热重载不生效；不影响 iOS 和 Android。升级 Flutter 后，先验证长文滚动、字体切换和反复进入阅读页，再考虑恢复 Impeller。

## Windows 和 Linux

Windows 使用 Visual Studio 的 Desktop development with C++ 工具链，然后 `flutter build windows --release`。Linux 需要 Flutter 桌面工具链及 GTK、Secret Service、JSONCPP 开发库；Ubuntu 可安装 `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev`，然后 `flutter build linux --release`。

Windows 分发时保留整个 Release 目录；Linux 保留整个 bundle，不能只复制主程序。Linux 运行需要桌面 Secret Service/密钥环；没有明文回退。

这两个目标的工程和 CI 任务已提供，本机未执行 Windows/Linux 原生构建或运行。对应宿主上的结果需单独验收。

## 原生集成与截图

```sh
flutter drive --driver=test_driver/native_verification.dart \
  --target=integration_test/native_smoke_test.dart \
  --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false \
  -d <device-id>
```

只在开发设备/模拟器上运行：Flutter 测试工具会安装和清理应用。数据和临时密钥使用单独测试范围，截图在 `docs/verification/` 中。原生构建按平台依次执行；并行构建会竞争共享插件注册文件。

测试只访问本地模拟模型，不需要真实 API key。测试真实服务时，由使用者明确设置连接，并承担对应服务费用。

macOS 键盘事件、网页背景和文件保存还有独立原生检查（在仓库根目录运行）：

```sh
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/macos-command-tests \
  -parallel-testing-enabled NO \
  'PRODUCT_BUNDLE_IDENTIFIER=com.moonrailgun.sillydraft.command-tests.$(PRODUCT_NAME:rfc1034identifier)' \
  FLUTTER_TARGET="$PWD/macos/RunnerTests/main.dart" test
python3 tool/verify_macos_atomic_export.py
```

XCTest 使用空 Dart 入口，不打开作品库；独立应用标识和构建目录避免替换或退出正在运行的 SillyDraft。键盘测试直接向测试实例分发构造事件，并在本地监听器截住，不向系统发送快捷键，也不执行复制。后者在临时目录中验证仅授予单个文件写权限时的创建和替换，不读取或改动现有作品。

独立原生测试与常规 Flutter 构建切换时，生成的 `macos/Flutter/ephemeral/FlutterOutputs.xcfilelist` 可能暂时包含另一个构建目录，引发 `Stale file ... outside of the allowed root paths` 警告。下一次构建会更新输出清单，无需为此修改应用权限。正式应用仍用默认入口重新执行 `flutter build macos --release`。

Flutter 3.47.7（engine `deb287481e`）的 [Command 映射](https://github.com/flutter/flutter/blob/deb287481e/engine/src/flutter/shell/platform/darwin/macos/framework/Source/KeyCodeMap.g.mm) 依赖左右设备标记，只有通用 Command 标记的模拟事件可能导致快捷键未处理并响铃，参见 [Flutter #178609](https://github.com/flutter/flutter/issues/178609)。`SillyDraftApplication.sendEvent` 仅为这类 `keyDown` / `keyUp` 补齐左 Command 标记，复制原 CGEvent 保留其余信息，转换失败则转发原事件；入口早于 AppKit 快捷键分发和 Flutter 的本地 keyUp 监听。升级引擎后需重新核对该兼容处理是否仍必要。

这是原生修复，Dart 热重载或热重启无效：先保存草稿并正常退出旧实例，再打开重新构建的 `build/macos/Build/Products/Release/SillyDraft.app`。自动化测试通过只证明事件处理符合预期；实际双击是否不再响、外部事件是否来自 Lark 及其具体功能，仍需现场确认。已有外部 ⌘C 在修复后可能正常复制并更新剪贴板，应用本身不添加自动复制行为。

## 发布

版本号只维护根目录 `pubspec.yaml` 的 `version: 主.次.修订+构建号`，Flutter 注入各平台。1.0 前功能或数据 schema 变化升次版本，修复升修订号；构建号每次发布 +1（Android 覆盖安装要求 versionCode 不降低）。`packages/sillydraft_core` 与 `server` 的版本号不参与发布，执行器按同一 tag 的源码运行。

在仓库根目录执行：

```sh
./release.sh patch   # 0.1.0 → 0.1.1；minor → 0.2.0；major → 1.0.0
./release.sh         # 不带参数时列出三项和结果版本供选择
./release.sh --allow-dirty minor   # 工作区有未提交改动时照常发布
```

脚本要求工作区干净、当前在分支上、不落后于 `origin`、目标 tag 不存在。加 `--allow-dirty` 时只要求 `pubspec.yaml` 没有未提交改动，其余改动原样留在工作区，不进入发布提交，CI 也只按 tag 构建。确认后只提交 `pubspec.yaml`（`chore(release): vX.Y.Z`），打附注 tag，再用 `git push --atomic` 同时推送分支和 tag。

tag 触发 `.github/workflows/release.yml`：

1. 调用 `verify.yml` 跑完整测试与构建；与下面的打包同时进行。发布提交推送到分支时 `verify.yml` 跳过，测试只在这里跑一遍。
2. 校验 tag 与 pubspec 版本一致，创建草稿 Release，说明为上个 tag 以来的提交标题与安装提示。
3. 并行构建并上传 `sillydraft-<版本>-android.apk`（只含 arm64-v8a；三种 ABI 合打时原生库未压缩，约 85 MB，仅 arm64 约 32 MB）、`-macos.zip`、`-windows-x64.zip`（含 VC++ 运行库）、`-linux-x64.tar.gz`。iOS 需要证书，不出包。
4. 测试通过且所有平台打包成功后转为正式发布。任一失败时 Release 停在草稿，应用的更新检查看不到它；修复后在 Actions 里重跑失败的任务即可（上传会覆盖同名文件）。

Android 签名需在仓库 Settings → Secrets and variables → Actions 中配置：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 上传密钥库的 base64：`base64 -i upload.jks \| pbcopy`（Linux 用 `base64 -w0 upload.jks`） |
| `SILLYDRAFT_STORE_PASSWORD` | 密钥库密码 |
| `SILLYDRAFT_KEY_ALIAS` | 密钥别名 |
| `SILLYDRAFT_KEY_PASSWORD` | 密钥密码 |

缺少时 Android 任务失败，Release 保持草稿。macOS 包未经 Developer ID 签名与公证，Release 说明中写有首次打开的方法。

应用在设置中显示版本号，并通过 GitHub 的 latest release 接口检查更新（每天最多一次，可关闭）；有新版时提示下载本平台安装包，不在应用内安装。

## 数据与升级

作品库位于系统 Application Support 目录：SQLite 保存结构和版本，图片以内容哈希管理，ST 原文件使用本地密钥加密。数据库 schema 有迁移版本。改动 schema 前添加旧版迁移测试，不删除迁移代码来规避已有作品。旧版应用打开较新 schema 的库会报错并保持数据不变，不会降级写入。

跨设备迁移使用加密作品备份，不能只复制数据库而遗漏图片或本机密钥文件。不要在有用户作品的目录运行测试夹具脚本。

## 本地订阅（Claude Code / Codex）

桌面版可以把已登录的 Claude Code 或 Codex 命令行工具当作模型连接，使用作者自己的订阅额度，不需要 API Key。应用直接启动可执行文件（不经过 shell），提示词通过标准输入传递：

- Claude Code：`claude -p --output-format stream-json --include-partial-messages --tools "" --no-session-persistence …`，关闭全部内置工具，不保存会话。
- Codex：`codex exec --json --sandbox read-only --ephemeral --skip-git-repo-check -`，只读沙箱，不保存会话。

两者都在每次生成新建的空临时目录中运行，结束后删除。Codex 另加 `--ignore-user-config --ignore-rules`，不加载个人配置中的 MCP 服务、自定义服务商和执行规则，模型请在连接里指定。两者仍会读取各自的全局个人说明（`~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`）；这无法在不影响登录的情况下关闭，提示词会要求模型忽略其中面向编程的内容。桌面应用不继承终端的 PATH，因此会询问登录 shell 的 PATH 并检查 `~/.local/bin`、`/opt/homebrew/bin` 等常见位置；仍找不到时在连接里填写完整路径。

这些工具没有函数调用接口：编辑 Agent 的工具在提示词中描述，模型以 ```` ```sillydraft-tool-calls ```` 代码块返回调用，格式无效时任务失败而不会把 JSON 当作回复。采样参数、停止序列不能传给这些工具，会在任务诊断中列出；文本补全模板和插画不支持。

macOS 因此不启用 App Sandbox（沙箱中的子进程无法读取工具的登录状态）。上架 Mac App Store 的版本需要恢复 `com.apple.security.app-sandbox` 并移除这类连接。手机端不提供本地订阅。
