# SillyDraft · 胡闹草稿

Flutter 编写的手机优先小说工作室，平台工程覆盖 Android、iOS、macOS、Windows 和 Linux。用 SillyTavern 角色卡和预设起步，边写故事边整理人物、世界观、关系、暗线、地图和插画。

**正文是作品，Agent 是编辑工具。** Agent 对话、模型原始输出、待审阅候选、已采纳正文和旁路资料分别保存。候选只有在作者采纳后才形成正文版本；正文在生成期间被修改时，旧候选不能覆盖新稿。

## 开始使用

安装 Flutter **3.47.7 / Dart 3.13.5** 及目标平台工具链后：

```sh
flutter pub get --enforce-lockfile
flutter run -d macos
# 也可用 flutter devices 查找 Android 或 iOS 设备后指定 -d <设备标识>
```

当前工作目录为 `/Users/moonrailgun/sillydraft`。此机器的 Flutter 位于 `/Users/moonrailgun/.local/share/sillydraft-sdk/flutter/bin/flutter`。

首次打开可选“打开示例小说”，无需模型即可阅读和编辑。示例是内置创作样本，未冒充实时模型输出。使用 AI 时，在设置中添加 OpenAI 兼容连接，分别选择正文、编辑 Agent、资料整理和生图使用的模型；密钥进入系统安全存储。

1. 从书架的创作资源库导入角色卡、ST 预设、世界书或正则脚本。
2. 在角色卡详情选择“从角色卡新建小说”，指定身份与一个开场；在作品的写作配置中绑定资源版本。
3. 编写或选中正文片段，预览本次提示词后生成候选，比较并采纳。
4. 打开独立阅读器阅读；在资料库整理人物、关系、伏笔和地点，在分支页比较候选走向。
5. 生成插画、设置封面或地图底图；需要迁移时创建加密作品备份。

操作细节见 [使用指南](docs/user-guide.md)。

## 已实现的工作区

| 能力 | 行为 |
| --- | --- |
| 书架与正文 | 创建、搜索、归档/恢复、章节场景、富文本、自动保存、撤销、历史版本、片段改写、插画 |
| 阅读 | 独立目录、进度、主题、字号、行距、书签、搜索；删除编辑会话不影响作品 |
| 编辑 Agent | 流式回复、受分支和故事位置限制的工具、独立写作任务、候选审阅、取消和任务历史 |
| ST 资源 | V1/V2/V3 JSON、PNG、CHARX；聊天预设/提示词包、文本模板组合、宏、世界书、文本正则；条目编辑、原文件加密与未知字段保留 |
| 旁路资料 | 人物、设定、组织、物品、地点、事件、暗线/伏笔；事实/计划/推测、来源、分析建议、过期检查 |
| 地图与关系 | 有方向的关系图、地点标记、路线、可导入或生成的底图 |
| 分支 | 从历史场景分叉、候选走向/结局、差异比较；资料和宏变量按分支及故事位置隔离 |
| 插画 | OpenAI 兼容生图与参考图编辑、图库、封面、正文插入、来源版本和重试 |
| 迁移 | TXT、含图片的 Markdown ZIP、EPUB 3；加密完整备份/恢复；基于强 ETag 的手动同步与冲突副本 |
| 手机与桌面 | 手机单页导航和系统导入/分享；桌面目录分栏、可调宽度、菜单、快捷键、全局正文搜索 |
| 远程任务 | 可选个人执行器；手机断开后继续执行，取回同一任务，明确区分重新生成和恢复查询 |

离线阅读、编辑、资料管理和备份均在本地进行，不强制登录。

## ST 兼容边界

源码对照固定到 SillyTavern **1.19.0 / `06bde939fb1e9c4c8d8641d810f0a916b5bce127`**。兼容按文件格式、提示词行为、模型参数和输出处理分别检查；导入成功不代表所有扩展可以运行。

已实现两条编译路径、100001 顺序组、启停、覆盖与 `{{original}}`、深度注入、受测宏/变量、世界书触发与文本正则。手机可编辑提示词条目的开关、顺序、内容、角色、深度和覆盖规则；模板及扩展可使用完整 JSON 编辑。原资源保持不变，编辑生成新版本。

token 预算采用估算；世界书定时/分组/自动化扩展和未实现宏/helper 会报告缺口。任意 JavaScript 不执行，HTML 展示扩展不渲染，正则替换结果按纯文本呈现。Kobold/NovelAI 专用后端以及原生 Anthropic/Gemini 协议未实现；当前运行协议为 OpenAI 兼容接口及 SillyDraft 远程执行器。不会自动采用预设中的代理地址、请求头或凭据。

完整依据、映射及测试范围见 [ST 兼容说明](docs/st-preset-compatibility.md)。

## 工程与验证

```text
lib/                         Flutter 界面、平台服务、Riverpod 状态
packages/sillydraft_core/     纯 Dart：SQLite、版本/分支、ST 编译、模型、任务、资产、迁移
server/                      可选持久化远程执行器
test/                        界面工作流
integration_test/            原生安全存储、SQLite、编辑阅读验证
docs/verification/           测试与原生截图证据
```

```sh
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

[构建与发布说明](docs/building.md) 包含各平台命令及签名配置；[需求验收表](docs/verification/acceptance.md) 将需求映射到代码和证据；[原生验证](docs/verification/native-platforms.md) 区分已运行的平台和待验证平台。测试使用本地协议服务，不依赖付费模型。

macOS、iOS 模拟器、Android 模拟器已有原生构建与操作证据。Windows/Linux 提供平台工程及 CI 构建任务，本机没有对应宿主的原生验证；CI 配置尚未在远程仓库运行。商店签名、发布和 macOS 公证由发布者配置。

远程部署见 [执行器文档](server/README.md)。同步服务与模型执行器是不同接口：同步端点需要支持强 ETag 和条件 PUT，不能随意填写普通文件分享链接。

## 参考

- [SillyTavern 固定源码](https://github.com/SillyTavern/SillyTavern/tree/06bde939fb1e9c4c8d8641d810f0a916b5bce127)
- [角色卡 V2](https://github.com/malfoyslastname/character-card-spec-v2)、[角色卡 V3](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md)
- [Novelcrafter Codex](https://www.novelcrafter.com/help/docs/codex/anatomy-codex-entry)、[Sudowrite Story Bible](https://docs.sudowrite.com/using-sudowrite/1ow1qkGqof9rtcyGnrWUBS/what-is-story-bible/jmWepHcQdJetNrE991fjJC)
- [MuMuAINovel 编辑 Agent](https://github.com/xiamuceer-j/MuMuAINovel/blob/main/backend/app/services/project_agent_service.py)

ST 官方测试样本的来源、哈希和上游许可证保留在核心包 fixtures 中。

独立审查的五项重要问题及修复验证见 [最终审查记录](docs/verification/final-review.md)。
