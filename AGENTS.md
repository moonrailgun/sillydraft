# AGENTS.md

本文件为在此仓库中工作的编码代理（Claude Code、Codex 等）提供指引。

## 首要原则：与 SillyTavern 生态对齐

SillyDraft 用 ST 的角色卡、预设、世界书、正则和社区前端起步，用户的资源都是为 ST 写的。**凡是 ST 已有定义的行为，都按 ST 的做法实现，不另起语义。**

- 基线固定为 SillyTavern **1.19.0 / `06bde939fb1e9c4c8d8641d810f0a916b5bce127`**。判断行为时去读该提交的源码（`public/script.js` 的 `messageFormatting`、`openai.js`、`PromptManager.js` 等），在注释里写明依据；不用浮动分支作参照。
- 社区扩展同样是对齐对象：HTML 代码块与接口按[酒馆助手 JS-Slash-Runner](https://github.com/N0VI028/JS-Slash-Runner)，变量按 MVU（MagVarUpdate）。
- 正文显示要和 ST 聊天楼层看起来一致：Markdown 按 showdown（及 ST 的选项）解析，HTML 片段按 DOMPurify 净化。例如代码围栏只要一行以围栏开头就算结束，同一行的余下内容仍是正文（showdown 的规则，见 `HtmlBlocks.find`）。
- 做不到的地方明确报告缺口（诊断、提示、文档），不静默丢弃，也不冒充兼容。兼容范围与依据记录在 `docs/st-preset-compatibility.md`，行为变化时同步更新。
- ST 对照数据由 `packages/sillydraft_core/tool/capture_st_reference.mjs`（Node 22，在核心包目录运行）从固定源码生成。重新生成后先比对 reference JSON 的差异，再跑 `dart test test/st_compiler_test.dart test/provider_test.dart`；不要为让测试通过而更新基准。
- SillyDraft 与 ST 没有直接关系，只是复用 ST 的生态：ST 是要兼容的标准之一，不是上游。代码中按对齐对象照搬的名单和规则（如推理强度的模型名单）需要定期同步：流程与清单见 `.claude/skills/sync-baselines/SKILL.md`，新增这类照搬时把它登记进清单。

## 命令

基线 Flutter 3.47.7 / Dart 3.13.5。根目录、`packages/sillydraft_core`、`server` 各有锁文件，安装用 `--enforce-lockfile`。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test                                   # 界面测试（test/）
flutter test test/reader_presentation_test.dart  # 单个文件
flutter run -d macos

cd packages/sillydraft_core                    # 纯 Dart 核心
dart analyze
dart test
dart test test/html_blocks_test.dart -N '用例名的一部分'  # 单个用例

cd server && dart analyze && dart test         # 可选远程执行器

./release.sh [--allow-dirty] [patch|minor|major]  # 发布：升版本、提交、打 tag、推送，CI 出包（见 docs/building.md“发布”）
```

格式检查（仓库根目录）：

```sh
dart format --output=none --set-exit-if-changed lib test integration_test test_driver tool packages/sillydraft_core/lib packages/sillydraft_core/test server/lib server/bin server/test
```

真实网页视图只能原生验证：`flutter test integration_test/html_render_test.dart -d macos`。其他平台构建、签名与原生截图流程见 `docs/building.md`。

macOS 在 `macos/Runner/Info.plist` 里设置了 `FLTEnableImpeller=false`（绕过中文字形噪点问题），改动它需要重新构建，热重载无效。

## 架构

三个 Dart 包：

- `lib/`：Flutter 界面（Riverpod、forui、flutter_quill）。`lib/app/services.dart` 组装仓库、模型连接和密钥；功能按 `lib/features/<领域>/` 划分。
- `packages/sillydraft_core/`：纯 Dart，不依赖 Flutter。存储、版本与分支、ST 导入与编译、模型协议、任务、MVU、HTML 块、迁移导出都在这里。能放在核心的逻辑放核心，用 `dart test` 测。远程作品库与扫码传输在 `src/remote/`：桌面的 `RemoteHost` 经 drift 远程协议共享数据库，手机的 `RemoteSession` 断线重连时仓库对象不变。
- `server/`：可选的个人远程执行器。只接收客户端冻结好的模型请求，ST 编译和输出处理仍在客户端。

### 存储与版本

- 单个 SQLite（drift）库：`StoryRepository`（`storage/story_repository.dart`）是一个 library，各领域的方法以 `part` 文件中的 extension 实现（`manuscript_store.dart`、`proposal_store.dart`、`display_store.dart` 等）。
- 正文是 Quill delta（`ManuscriptContent`）。`revisions` 不可变；`branch_chapters` 把（分支, 章节）指向当前 revision。编辑、恢复历史都生成新 revision。
- 模型输出先成为 proposal（候选），采纳才写成正文 revision；写作任务都自动采纳（`autoAccept`），界面不显示候选。采纳时检查 `baseRevisionId` 和变量版本，生成期间正文或变量有变化就不写入，留作“未写入的正文”等作者处理。
- 生成任务（`generation_tasks`）持久化完整输入快照：编译后的请求、预设、宏值、时钟、种子、显示正则（`outputRegex`）。

### 正文与显示的分离

存储、导出和模型上下文永远使用正式正文。`ManuscriptPresentation` 是一次性的显示投影：阅读器按分支当前的 ST 显示正则呈现正文，有任务时沿用任务冻结的宏环境；未指定分支的历史版本投影与 proposal 预览使用任务冻结规则（见 `proposal_store.dart`、`display_store.dart`）。投影维护显示偏移到原文偏移的映射，书签和搜索据此落回原文。

阅读器渲染（`lib/features/reader/`）：`ReaderDocument` 把显示文本拆成段落；`HtmlBlocks.find` 找出 HTML 块：含页面的围栏代码块是 frontend，在隔离网页视图里运行酒馆助手风格接口；行首的原始 HTML 是 fragment，按 DOMPurify 规则净化，不给接口。其余文字由 `ProseMarkup` 按 ST `messageFormatting` 标出对话引号、强调和隐藏标记。

## 调试正在运行的应用

macOS 上的数据库位于 `~/Library/Application Support/com.moonrailgun.sillydraft/library.sqlite`。用只读方式打开（`sqlite3 "file:<路径>?mode=ro"`），不要在应用运行时写入。章节原文在 `revisions.content_json`，生成时的输入（含显示正则）在 `generation_tasks.input_json`。

## 约定

- 文档与界面默认中文，代码与注释用英文。
- 提交信息用 Conventional Commits 加作用域，如 `fix(reader): …`、`feat(core): …`。
- 测试使用本地协议服务器，不调用付费模型。
