# 版本发布与更新检查设计

## 目标

一条命令发布版本：升版本号、提交、打 tag、推送；CI 据 tag 构建 Android、macOS、Windows、Linux 安装包并发布到 GitHub Releases。应用在设置里显示自身版本，并检查 GitHub 上的新版、提示用户下载。

本次不做：应用内下载安装、macOS 签名公证、应用商店、执行器独立发版、预发布渠道、CHANGELOG 文件。

## 现状

- 应用版本只在根目录 `pubspec.yaml`（`0.1.0+1`），Flutter 注入各平台：iOS/macOS `Info.plist` 的 `FLUTTER_BUILD_NAME/NUMBER`，Android `build.gradle.kts` 的 `flutter.versionName/Code`，Windows `Runner.rc`。`sillydraft_core`、`server` 的 `0.1.0` 是 `publish_to: none` 的内部版本，不参与发布。
- 无 tag、无发布工作流。`verify.yml` 在每次 push（含 tag）上测试并构建全部平台，不上传产物。
- 界面不显示版本。`package_info_plus` 10.2.2、`url_launcher` 6.3.3 已是锁文件中的间接依赖。
- 全局设置用 `settingProvider(key)` / `repository.setSetting(key, map)`，存于 `app_settings`。
- 数据格式各自带版本：库 `schemaVersion 8`、作品快照 `schema 8`、备份 `sillydraft-backup`、执行器 `user_version 1`。执行器遇到较新数据报错（`runner_server.dart:103`）；客户端没有对应检查——drift 在 `versionBefore != versionNow` 时都调用 `onUpgrade`（含降级），之后把版本写回 8，旧版应用会直接读写新结构。
- 库打开失败会在启动时（`recoverInterrupted` 首次查询）抛出，由 `main.dart` 的 `_StartupError` 显示。

## 版本规则

- 格式 `主.次.修订+构建号`，只改根目录 `pubspec.yaml`。1.0 前：功能或数据 schema 变化升次版本，修复升修订号。
- 构建号每次发布 +1，不复用（Android 覆盖安装要求 versionCode 不降低）。
- tag 为 `v主.次.修订`，必须与 pubspec 中 `+` 前的部分一致。

## 发布脚本 `release.sh`

位于仓库根目录，在根目录执行：`./release.sh [patch|minor|major]`。脚本先切到自身所在目录，从别处调用也作用于本仓库。

1. 未给参数时列出三项供选择，每项附结果版本，例如 `patch  0.1.0 → 0.1.1`；参数无效时报错退出。
2. 前置检查，任一失败即退出且不改动任何东西：工作区干净（`git status --porcelain` 为空）；当前在分支上（非游离 HEAD）；`git fetch` 后本地不落后于上游；目标 tag 不存在（本地与远端）。
3. 显示 `旧版本 → 新版本`，输入 `y` 确认后继续。
4. 改写 `pubspec.yaml` 的 `version:` 行，构建号 +1；只提交该文件，信息 `chore(release): v<版本>`。
5. 打附注 tag `v<版本>`。
6. `git push --atomic origin HEAD:refs/heads/<当前分支> refs/tags/v<版本>`，分支与 tag 同时成功或同时失败。推送失败时提示撤销本地提交与 tag 的命令。
7. 打印 Actions 页面地址。

## 发布工作流 `.github/workflows/release.yml`

`push: tags: ['v*']` 触发。默认权限 `contents: read`，需要写 Release 的任务单独授予 `contents: write`。各任务用运行器自带的 `gh`，不新增第三方 Action；已有 Action 沿用 `verify.yml` 中固定的提交。

1. **verify**：`uses: ./.github/workflows/verify.yml`，与 create/build 同时进行。`verify.yml` 增加 `workflow_call`，`push` 限定 `branches: ['**']`；分支推送的最新提交以 `chore(release):` 开头时各任务跳过，每次发布只测一遍。
2. **create**：完整检出（`fetch-depth: 0`），校验 tag 与 pubspec 版本一致；生成说明：上一个 tag 以来的提交标题（无上一个 tag 时写“首个发布版本”），附 macOS 未签名应用的首次打开方法。已存在同名 Release 则跳过创建，否则 `gh release create --draft`。
3. **build**（needs create，矩阵并行，`fail-fast: false`）。构建后 `gh release upload --clobber`，重跑可覆盖：

   | 平台 | 运行器 | 产物 |
   | --- | --- | --- |
   | Android | ubuntu-24.04，JDK 21 | `sillydraft-<版本>-android.apk`：由 Secret `ANDROID_KEYSTORE_BASE64` 解码 keystore，配合 `SILLYDRAFT_STORE_PASSWORD` / `SILLYDRAFT_KEY_ALIAS` / `SILLYDRAFT_KEY_PASSWORD` 签名；缺少则构建失败 |
   | macOS | macos-15 | `sillydraft-<版本>-macos.zip`：`ditto -c -k --keepParent` 打包 `.app` |
   | Windows | windows-2025 | `sillydraft-<版本>-windows-x64.zip`：整个 Release 目录，加 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll` |
   | Linux | ubuntu-24.04 | `sillydraft-<版本>-linux-x64.tar.gz`：整个 bundle |

4. **publish**（needs verify、build）：测试通过且全部打包成功后 `gh release edit --draft=false --latest`。任一平台失败则 Release 停在草稿，更新检查看不到它。

## 版本显示

- `package_info_plus`、`url_launcher` 改为直接依赖（锁定版本不变）。
- 设置页底部原有的“SillyDraft”署名后显示 `<版本> (<构建号>)`；其上新增一组“检查更新”“自动检查更新”开关。iOS 只显示版本（没有发布 iOS 安装包）。
- `AppServices.updateEndpoint` 为 null 时不检查、不显示更新项：测试默认如此，iOS 由 `AppServices.open` 置空，`open(checkUpdates: false)` 供真实数据的端到端测试使用。

## 更新检查

**核心包** `packages/sillydraft_core/lib/src/update/`，纯 Dart，用 dio：

- 请求 `https://api.github.com/repos/moonrailgun/sillydraft/releases/latest`（`Accept: application/vnd.github+json`，10 秒超时）。该接口不返回草稿和预发布。地址可注入，供测试指向本地服务。
- 解析 `tag_name`、`html_url`、`body`、`assets[].name/browser_download_url`。tag 不是 `v数字.数字.数字` 视为无更新；404（尚无 Release）视为无更新。
- 只按 `主.次.修订` 数值比较，远端更大才算新版。
- 按平台后缀选安装包（`-android.apk`、`-macos.zip`、`-windows-x64.zip`、`-linux-x64.tar.gz`），找不到则用 Release 页面地址。
- 返回 `UpdateInfo { version, notes, downloadUrl, pageUrl }` 或 null；网络或格式错误抛出，由调用方决定是否显示。

**界面**：

- 设置 `update` = `{auto: bool（缺省 true）, skip: 版本}`，只由作者操作写入；检查器只写 `updateCheck` = `{at: 毫秒时间戳}`，避免请求期间覆盖作者刚改的开关。
- 主界面首帧后：`auto` 未关闭且距 `updateCheck.at` 超过 24 小时（或该时间晚于现在，即时钟回拨），静默检查并写 `updateCheck.at`；有新版且不等于 `skip` 时弹窗。失败不提示。同一时间只有一次检查；检查进行中再点“检查更新”只提示“正在检查更新…”。
- 弹窗：标题“发现新版本 <版本>”，可滚动显示更新说明原文；按钮“下载”（浏览器打开安装包地址）、“跳过此版本”（写 `skip`）、“稍后”。
- 设置里手动检查：忽略 `skip` 与间隔，有新版弹同一个窗，否则提示“已是最新版本”或错误信息。
- iOS 不检查。

## 数据库防降级

`database.dart` 的 `onUpgrade` 开头：`from > to` 时抛出 `StateError('作品库来自较新版本的 SillyDraft（数据版本 $from），请下载新版')`。drift 只在迁移成功后写回版本，抛出后库保持原样，启动页显示该错误。

## 文档

- `docs/building.md` 新增“发布”：版本规则、`./release.sh` 用法、四个 Secret 的配置（含 keystore 转 base64 的命令）、草稿与发布的关系。
- `docs/user-guide.md`：更新检查会访问 GitHub，可在设置中关闭。
- `AGENTS.md` 命令段加 `./release.sh`。

## 测试

- 核心包：本地 HTTP 服务模拟接口，覆盖新版、同版本、旧版、非法 tag、404、选包与回退到页面地址；库 `user_version` 为 9 时打开报错且版本仍为 9。
- 界面：设置页显示 `PackageInfo.setMockInitialValues` 给出的版本。
- 脚本：在临时目录用本地裸仓库作远端，实际执行 patch / minor / major、菜单选择，以及工作区不干净、tag 已存在时退出。
- 工作流：本地做语法检查；完整验证是首次发布，失败时停在草稿。
