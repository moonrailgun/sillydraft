# SillyDraft · 胡闹草稿

使用 Flutter 构建、以手机体验为优先的跨端小说创作应用。通过写作 Agent 辅助故事起草、修改与打磨，并随创作积累人物、世界观、暗线与剧情分支。

项目工作目录：`/Users/moonrailgun/sillydraft`。

已确定的产品方向：

- **手机优先**：优先满足 Android、iOS 上的阅读、创作指令、正文编辑和修改审阅，再扩展桌面布局。
- **角色卡开局**：支持导入 SillyTavern（ST）角色卡，以人物、场景、开场白和角色书建立小说开头与初始世界观，后续边写边补充。
- **ST 预设兼容**：以 SillyTavern 源码行为为依据，兼容聊天补全预设、独立提示词包、文本补全参数及上下文、指令、系统提示词模板；保留提示词顺序、动态占位、宏、注入与正则规则的语义，按能力报告兼容程度。详见 [ST 预设兼容方案](docs/st-preset-compatibility.md)。
- **Agent 与正文分离**：写作 Agent 是编辑工具，正文是独立保存、具有版本的作品产物；对话、任务记录和编辑说明与正文分别存储。
- **独立阅读器**：直接读取小说正文，支持目录、阅读进度、排版和插画，不依赖 Agent 会话。
- **旁路创作**：写作过程中可创建或更新世界观、人物信息、暗线、伏笔、地点、地图和人物关系；这些任务独立于正文生成。
- **故事分支**：根据当前故事发展，在正文末尾提出多个后续走向，也支持结局候选；选定方向后继续生成，可保留不同分支。
- **分支资料隔离**：各分支的剧情事实、人物状态、关系变化和伏笔回收状态分别管理，未选中的候选不进入当前故事的事实记忆。
- **模型生图**：调用生图模型创建人物、场景和章节插画，图片与对应资料、分支和文稿版本关联。
- **参考现有写作器**：研究公开文档与开源实现，借鉴上下文检索、章节生成、编辑工具和记忆更新流程。

建议的首个完整流程：

1. 手机导入 ST 角色卡与写作预设，选择开场与叙事视角；未导入预设时使用内置默认配置。
2. 建立初始人物和世界观，生成第一幕候选文稿。
3. 审阅、修改并采纳，进入独立阅读器。
4. 在正文末尾查看后续走向，选择一个方向继续生成。
5. 旁路整理新出现的人物、设定、关系和伏笔，按需生成插画。

项目正在实现中，完整要求见 [产品规格](docs/product-spec.md)，当前进度以测试和提交记录为准。采用以下技术栈：

| 部分 | 候选方案 |
| --- | --- |
| 状态管理 | Riverpod |
| 本地数据 | Drift 与 SQLite，附件单独存储 |
| 正文编辑 | Flutter Quill，优先验证中文输入、长章节和撤销体验 |
| 模型通信 | Dio 与模型服务商适配层，文字与生图分别适配 |
| Agent | 独立 Dart 模块，负责上下文组装、工具调用与修改提案 |
| ST 预设 | 独立解析与编译模块，将角色、世界书、当前分支正文和预设转换为模型请求；与编辑 Agent 的控制指令分开 |
| 持久化任务 | 保存输入版本、任务状态和结果，支持中断后的恢复处理 |
| 密钥 | 平台安全存储 |

界面建议按「阅读、创作、资料」组织。正文直接编辑使用专注页面；地图和关系图按需全屏打开。桌面端可同时展示多个区域。

ST 导入应保留原始文件和未知字段。卡中明确设定、正文提取事实和模型推测分别标记来源；多个备用开场只采用选中的一个。角色卡中的提示词与扩展内容不能改变应用的工具权限。

ST 预设绑定正文生成任务。编辑 Agent 调用正文生成服务，后者按预设生成候选文稿，再通过统一采纳流程形成正文版本。编辑会话和工具执行记录不进入预设的故事历史。预设兼容分为格式导入、提示词行为、模型参数和输出处理四个层面；成功读取 JSON 不代表所有行为已经生效。

Agent 生成结果建议先保存为候选文稿或修改提案，并绑定所依据的正文版本。采纳后形成新版本，再触发旁路整理；原文变化时，关联的旧分析结果应标记为待复核。普通修改形成版本，剧情方向变化形成分支。

手机端保存草稿与任务状态，离线阅读和编辑不依赖服务端。可选远程执行器用于断开应用后继续执行长任务；多设备同步保留冲突版本。

## 开发环境

基线：Flutter 3.47.7、Dart 3.13.5。当前机器的 Flutter 位于 `/Users/moonrailgun/.local/share/sillydraft-sdk/flutter/bin/flutter`；其他机器使用本机的 Flutter SDK。

```sh
flutter pub get
flutter run -d macos
cd packages/sillydraft_core
dart test
dart analyze
```

核心包不依赖 Flutter。正文、分支和修改提案使用 SQLite 事务及不可变版本存储，平台工程覆盖 Android、iOS、macOS、Windows 和 Linux。

目前已实现正文版本、分支基础、ST 导入与编译、OpenAI 兼容的聊天/文本补全接口、流式工具调用和持久化任务。界面已接入书架、富文本编辑、独立阅读、Agent 会话、正文候选比较与采纳、任务取消/重试，以及 ST 资源库和写作配置。资料、地图、插画、备份同步与平台整合仍在实现中，不能将当前工程视为完整可用版本。

点击书架的资源库图标导入角色卡、预设、世界书或正则。在作品的创作助手里选择「角色卡与预设」绑定具体版本；编辑正文时可选中片段改写，先预览提示词，再生成候选。资源编辑会创建新版本。原始导入文件使用 AES-256-GCM 加密，密钥存在系统安全存储中；预览和 JSON 导出移除已识别凭据。角色卡 JSON 导出不包含二进制附件。

书架、编辑和阅读的原生验证见 [编辑与阅读记录](docs/verification/editor-reader.md)。资源加密使用 [cryptography 的 AesGcm 实现](https://pub.dev/documentation/cryptography/latest/cryptography/AesGcm-class.html)。

任务保存输入快照、部分输出与错误。失败后重新生成会创建新任务，不会自动重复网络请求。编辑 Agent 的工具限定在当前分支，正文候选需要作者采纳；预设中暂不支持的预填行为会给出明确诊断。

网络协议参考 [OpenAI 流式事件](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events) 与 [工具调用文档](https://developers.openai.com/api/docs/guides/function-calling)。测试使用本地 HTTP 服务，不需要模型密钥或付费请求。

参考资料：

- [ST 预设兼容方案与固定源码依据](docs/st-preset-compatibility.md)
- [角色卡 V2 规范](https://github.com/malfoyslastname/character-card-spec-v2)
- [角色卡 V3 规范](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md)
- [Novelcrafter 资料条目与上下文管理](https://www.novelcrafter.com/help/docs/codex/anatomy-codex-entry)
- [Sudowrite Story Bible](https://docs.sudowrite.com/using-sudowrite/1ow1qkGqof9rtcyGnrWUBS/what-is-story-bible/jmWepHcQdJetNrE991fjJC)
- [MuMuAINovel Agent 实现](https://github.com/xiamuceer-j/MuMuAINovel/blob/main/backend/app/services/project_agent_service.py)
- [MuMuAINovel 章节上下文构建](https://github.com/xiamuceer-j/MuMuAINovel/blob/main/backend/app/services/chapter_context_service.py)
