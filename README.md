<p align="center">
  <img src="assets/branding/logo.png" alt="SillyDraft Logo" width="144" height="144">
</p>

<h1 align="center">SillyDraft</h1>

<p align="center"><strong>把故事写下来，也把故事里的世界整理好。</strong></p>
<p align="center">本地优先的 AI 小说创作与阅读工作台 · 手机与桌面 · 兼容 SillyTavern 资源</p>

<p align="center">
  <a href="https://github.com/moonrailgun/sillydraft/releases/latest">下载应用</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="docs/user-guide.md">使用指南</a> ·
  <a href="CHANGELOG.zh-CN.md">更新日志</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="docs/building.md">开发与构建</a>
</p>

---

SillyDraft 把**写作、阅读、AI 助手、故事资料和插画**放在同一个作品里。你可以从空白开始，导入已有小说继续写，也可以用 SillyTavern（ST）的角色卡和预设开启故事。

阅读、编辑、资料管理和备份可以离线完成，不强制登录。需要 AI 时，再连接自己的模型服务。

## 你可以用它做什么

| 你想做的事 | SillyDraft 提供的工具 |
| --- | --- |
| **开始一本小说** | 新建空白作品，导入 TXT / Markdown / EPUB，或从角色卡的开场开始 |
| **和 AI 一起写** | 续写章节、改写片段、与编辑助手讨论；查看生成提示词和任务记录 |
| **整理故事世界** | 管理人物、设定、组织、物品、地点和伏笔，用关系图与地图梳理联系 |
| **尝试不同走向** | 从历史章节分出另一条故事线，比较不同版本与结局 |
| **给故事配图** | 生成插画、制作封面、插入正文；支持参考图的连接还可用于图片编辑 |
| **安心阅读和修改** | 自动保存、历史版本；沉浸阅读、书签、搜索、自动滚动和阅读样式设置 |
| **带走自己的作品** | 导出 TXT、含图片的 Markdown ZIP 或 EPUB，创建加密备份与恢复 |
| **在手机和桌面间协作** | 连接桌面远程作品库；也可配置手动同步或个人远程任务执行器 |

**正文有版本，改稿有退路。** AI 写作完成后会自动写入正文并保留历史；如果生成期间你修改了正文或故事变量，结果会保留为“未写入的正文”，等待处理，不覆盖新稿。删除助手对话也不会删除作品正文。

## 界面预览

| 桌面工作台 | 续写方向 |
| :---: | :---: |
| ![桌面工作台：章节目录与小说正文](docs/screenshots/desktop-workspace.png) | ![章节结尾的三个续写方向](docs/screenshots/story-directions.png) |
| 章节目录与正文并排，随时切换阅读与编辑。 | 选择接着写，或从当前章节另开一条故事线。 |

| 故事分支 | 世界设定 |
| :---: | :---: |
| ![故事分支树：北上、留在白塔和前往王都等走向](docs/screenshots/story-branches.png) | ![故事资料页面：七座烽火等世界设定条目](docs/screenshots/world-building.png) |
| 保留不同选择，切换故事线、比较版本。 | 分类管理人物、设定、组织、地点与伏笔。 |

| 正文插画 |
| :---: |
| ![小说正文中嵌入的场景插画，与上下文一起展示](docs/screenshots/story-illustration.png) |
| 为故事配上插画，插入正文，边读边看。 |

| 手机阅读 · 浅色 | 手机阅读 · 深色 |
| :---: | :---: |
| <img src="docs/screenshots/mobile-reading-light.png" alt="手机浅色阅读界面：纸色背景与底部阅读工具" width="280"> | <img src="docs/screenshots/mobile-reading-dark.png" alt="手机深色阅读界面：深色背景与底部阅读工具" width="280"> |
| 纸色背景，配合章节导航与书签。 | 深色主题，支持自动滚动与阅读样式设置。 |

## 开始使用

### 1. 安装应用

前往 [GitHub Releases](https://github.com/moonrailgun/sillydraft/releases/latest)，选择对应平台的文件：

| 平台 | 安装方式 |
| --- | --- |
| Android | 下载并安装 `*-android.apk`（arm64） |
| macOS | 下载 `*-macos.zip`，解压后按发布说明打开应用 |
| Windows | 下载并解压 `*-windows-x64.zip`，保留整个目录后运行 |
| Linux | 下载并解压 `*-linux-x64.tar.gz`，保留整个应用目录 |
| iOS | 不提供公开 Release 安装包；自行构建见 [构建说明](docs/building.md) |

macOS 发布包尚未经过 Developer ID 签名与公证，首次打开请查看对应版本的说明。本页介绍当前源码功能，已发布版本以 Release 说明为准。

### 2. 打开或创建作品

首次体验可以打开内置示例小说 **《雾港来信》**，无需配置模型，也不消耗模型额度。

准备开始创作时，在书架点击 **“新建作品”**：

- **空白作品**：填写书名与设定，从第一章写起。
- **从角色卡开始**：选择 JSON、PNG 或 CHARX 角色卡，再选择人设和开场。
- **续写已有小说**：导入 TXT、Markdown 或 EPUB，确认章节后接着写。桌面也支持把文件拖进书架。

打开作品后，围绕 **正文、资料、助手、插图** 四个分区创作；点书名下的分支切换故事走向，进入阅读器连续阅读。

### 3. 需要 AI 时，连接模型

在 **设置 → 添加模型连接** 中配置服务，再为正文、编辑助手、资料整理和插画选择模型。它们可以共用连接，也可以分别设置。

- **文本写作**：支持 OpenAI 兼容接口；桌面端还可使用已登录的本地 Claude Code / Codex 订阅连接。
- **插画生成**：支持 OpenAI 兼容生图、ComfyUI 工作流、NovelAI 文生图及具备生图能力的桌面 Codex 订阅连接；参考图支持因连接而异。
- **ST 资源**：在“资源”中导入预设、世界书和正则，再到作品中选择使用。世界书用于提供背景资料，预设用于配置提示词与生成参数。

具体操作见 [使用指南](docs/user-guide.md)。

> **密钥与数据**：模型密钥以明文保存在本机 `secrets.json`，不进入作品备份、同步或导出。使用 AI 时，任务所需的正文和资料会发送给你配置的模型服务；数据处理说明见 [隐私政策](docs/privacy-policy.md)。

## 已有 SillyTavern 资源？

SillyDraft 是独立应用，复用 ST 的资源生态。你可以继续使用熟悉的角色卡、预设和世界书，兼容行为以 **SillyTavern 1.19.0** 的[固定源码](https://github.com/SillyTavern/SillyTavern/tree/06bde939fb1e9c4c8d8641d810f0a916b5bce127)为依据。

| 资源或能力 | 支持情况 |
| --- | --- |
| 角色卡 | V1 / V2 / V3，支持 JSON、PNG、CHARX |
| 预设与世界书 | 聊天预设、提示词包、文本模板、宏、世界书触发和文本正则；可编辑并保留资源版本 |
| MVU 故事变量 | 内置变量初始化、更新、状态显示与变量管理，详见 [MVU 验证](docs/verification/mvu.md) |
| HTML 界面 | Android、iOS、macOS 可渲染隔离的 HTML 页面，并提供常用酒馆助手接口；Windows / Linux 显示源码 |

**导入成功不代表所有社区扩展都能运行。** 角色卡附带的脚本库不执行，部分宏和世界书扩展尚不支持，应用会给出兼容提示。HTML 页面不能读本地文件或自行调用模型，普通 HTML 片段经过净化，不提供助手接口。

Token 预算采用估算；原生 Anthropic / Gemini 协议及 Kobold / NovelAI 文本专用后端尚未实现。完整范围、差异和测试依据见 [ST 兼容说明](docs/st-preset-compatibility.md)。

## 从源码运行

安装 **Flutter 3.47.7 / Dart 3.13.5** 及目标平台的工具链后，获取源码并启动：

```sh
git clone https://github.com/moonrailgun/sillydraft.git
cd sillydraft
flutter pub get --enforce-lockfile
flutter run -d macos
```

Android、iOS 等设备可先用 `flutter devices` 查看，再将 `macos` 替换为目标设备标识。各平台依赖、打包与签名步骤见 [构建与发布说明](docs/building.md)。

<details>
<summary><strong>开发者：项目结构与常用检查</strong></summary>

```text
lib/                         Flutter 界面与平台服务
packages/sillydraft_core/     纯 Dart 核心：存储、版本、ST 编译、模型与任务
server/                      可选的个人远程任务执行器
test/                        Flutter 界面测试
integration_test/            原生集成测试
docs/                        使用、设计、兼容与验证文档
```

在仓库根目录检查界面层：

```sh
flutter analyze
flutter test test --reporter expanded
```

在 `packages/sillydraft_core/` 或 `server/` 目录检查对应的 Dart 包：

```sh
dart pub get --enforce-lockfile
dart analyze
dart test --reporter expanded
```

测试使用本地协议服务，不依赖付费模型。真实 HTML 网页视图需要原生验证；已有平台证据与待验证范围见 [原生验证记录](docs/verification/native-platforms.md)，远程 CI 状态请查看 [GitHub Actions](https://github.com/moonrailgun/sillydraft/actions)。

</details>

## 文档导航

| 想了解什么 | 从这里开始 |
| --- | --- |
| 具体功能怎么用 | [使用指南](docs/user-guide.md) |
| 角色卡、预设和扩展的兼容范围 | [ST 兼容说明](docs/st-preset-compatibility.md) |
| 如何开发、测试、打包与发布 | [构建说明](docs/building.md) · [iOS 发布](docs/ios-app-store.md) |
| 产品定位与界面规范 | [系统与设计规范](docs/design-guidelines.md) · [界面设计标准](design.md) |
| 如何部署个人远程执行器 | [执行器文档](server/README.md) |
| 数据与统计如何处理 | [隐私政策](docs/privacy-policy.md) · [Tianji 接入说明](docs/application-tracking.md) |
| 哪些能力经过验证 | [需求验收表](docs/verification/acceptance.md) · [原生验证](docs/verification/native-platforms.md) · [审查记录](docs/verification/final-review.md) |

<details>
<summary><strong>参考项目与规范</strong></summary>

- [SillyTavern](https://github.com/SillyTavern/SillyTavern/tree/06bde939fb1e9c4c8d8641d810f0a916b5bce127) · [酒馆助手 JS-Slash-Runner](https://github.com/N0VI028/JS-Slash-Runner)
- [角色卡 V2](https://github.com/malfoyslastname/character-card-spec-v2) · [角色卡 V3](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md)
- [Novelcrafter Codex](https://www.novelcrafter.com/help/docs/codex/anatomy-codex-entry) · [Sudowrite Story Bible](https://docs.sudowrite.com/using-sudowrite/1ow1qkGqof9rtcyGnrWUBS/what-is-story-bible/jmWepHcQdJetNrE991fjJC)
- [MuMuAINovel 编辑 Agent](https://github.com/xiamuceer-j/MuMuAINovel/blob/main/backend/app/services/project_agent_service.py)

ST 官方测试样本的来源、哈希和原项目许可证保留在核心包 fixtures 中。

</details>
