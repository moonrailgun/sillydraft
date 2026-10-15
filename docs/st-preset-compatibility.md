# SillyDraft 的 SillyTavern 预设兼容方案

SillyDraft 将 SillyTavern（ST）预设作为正式的写作配置，支持用户把已有角色卡、世界书与预设组合用于小说创作。预设作用于正文生成服务；编辑 Agent 的工具流程、资料整理和正文版本管理分别运行。

导入、编译、资源库、手机条目编辑与正文候选闭环已接入应用。源码基线为 ST `release` 分支的 `1.19.0`，提交 `06bde939fb1e9c4c8d8641d810f0a916b5bce127`，提交日期为 2026-09-14，核查日期为 2026-10-13。后续升级按提交维护兼容记录，不把浮动分支作为测试依据。[版本依据](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/package.json)

实现证据位于 `packages/sillydraft_core/test/st_import_test.dart` 与 `st_compiler_test.dart`。官方样本附有提交与 SHA-256 清单；`packages/sillydraft_core/tool/capture_st_reference.mjs` 从固定源码运行隔离的注入及指令序列化函数，生成对照数据。对照函数使用明确的空扩展环境，不等同于整个 ST 浏览器运行时。

显示专用正则已接入候选预览和独立阅读器。阅读器使用当前分支的显示规则，调整后已有章节立即重新渲染；生成章节仍使用任务中冻结的时钟、随机种子和宏变量，手动编辑继承此前生成的宏上下文。候选预览及历史对比保留任务中冻结的规则。可切换查看原正文，显示阶段的变量副作用不会提交。保存、导出及后续模型上下文仍使用正式正文，书签位置映射回原正文。对应 `manuscript_presentation_test.dart`、`reader_presentation_test.dart` 和三平台原生检查。

当前受测范围包括 V1/V2/V3、PNG、CHARX 导入，完整预设与提示词包区分，100001 顺序、关闭条目、角色覆盖、深度注入、条件和变量宏、正则阶段、默认 Handlebars 模板、文本指令序列及世界书递归。宏变量只在任务副本中变化，存储提交由候选采纳流程负责。未知宏、模板 helper 与已识别的未实现世界书依赖会阻止无提示运行。

限制仍需明确：token 预算为估算；随机宏按任务固定，`pick` 的种子不等同于 ST 聊天标识；世界书的定时、分组及自动化扩展尚未实现；浏览器脚本扩展不执行。模型参数诊断、输出处理、资源库 UI 与采纳时变量提交已接入。现有证据覆盖固定样本和本地模拟模型，不代表全部社区预设或真实模型行为等价。

## ComfyUI 工作流读取

ST 1.19.0 的 [`stable-diffusion.js`](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/src/endpoints/stable-diffusion.js#L446) 按文件名读取 ST 用户目录内的工作流，再提交 API 节点图到 ComfyUI。社区“智绘姬” [`st-chatu8`](https://github.com/damoshen123/st-chatu8/blob/8b07f4554355671e0a288afa94c1ae89ddfb8b8b/index.js#L45901) 也以 API JSON 保存工作流预设，导入时明确拒绝包含 UI 节点的画布格式。

SillyDraft 沿用 API 节点图执行语义，支持本地导入、粘贴，以及通过 ComfyUI `userdata` 接口按文件名读取 `workflows/` 下的 JSON。服务端目录与 ST 自身的预设目录不同；不读取 ST 插件设置、不实现智绘姬预设占位符。标准核心节点画布根据 `object_info` 的输入定义、命名控件或控件顺序转换为 API 图；参考 ComfyUI 官方 [`workflow_templates` 转换代码](https://github.com/Comfy-Org/workflow_templates/blob/main/scripts/comfyui_node_compat/workflow.py) 和[控件序列化说明](https://github.com/Comfy-Org/ComfyUI_frontend/blob/main/docs/WIDGET_SERIALIZATION.md)。自定义前端序列化、子图、禁用/绕过节点等不支持时明确要求导出 API 格式，不猜测转换。密钥、格式、文件大小（2 MB）、节点数量（4096）分别诊断。服务端文件在新建任务前重读，再冻结到任务快照；重试不重新读取。默认沿用工作流模型，覆盖模型和 API JSON 导入收在高级设置。画面描述选择默认仅显示 `text`、`prompt`、`text_g`、`text_l` 和已有绑定；展开高级设置可选其他字符串字段，兼容自定义 API 节点。测试见 `comfy_canvas_test.dart`、`comfy_workflow_files_test.dart`、`comfy_workflow_refresh_test.dart`、`comfy_workflow_editor_test.dart`。

## 预设面板与助手对话

作品菜单「预设」、助手顶部的「预设」标签和生成正文页都进入同一个预设面板，对应 ST 的“AI 回复配置”：

- 下拉框切换本作品当前预设，选择即生效；“不使用预设”回到 SillyDraft 默认写作配置。导入 ST 预设后自动选中。
- 面板按「采样参数」「提示词管理」「预设正则」「兼容提示」分组，按预设内容显示适用页签；预设选择、助手开关与自动保存状态保留在顶部。各页签独立滚动，提示词长列表只构建可见区域及邻近缓存的条目。
- 预设正则：列出 `extensions.regex_scripts` 内的规则名称、用途、查找表达式与启停开关；查找表达式使用等宽字体并自动换行，仅操作开关可切换启停，点击条目正文不会更改状态；「查看正则内容」展示可选取的完整查找表达式、替换内容及其余字段，支持复制完整规则 JSON。开关只修改 `disabled`，保留规则顺序和其他字段，语义依据固定 ST 基线的[正则开关](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/extensions/regex/index.js#L653-L656)。显示规则变更后阅读器刷新已有章节，与 ST [保存规则后重载聊天](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/extensions/regex/index.js#L557-L560)一致；切换到其他分支时使用该分支规则。后续生成也使用新设置，已有任务记录和正式正文不变。
- 采样参数：聊天补全预设显示温度、Top P/K、Min P、频率/存在/重复惩罚、最大回复与上下文长度、随机种子；文本补全预设与高级格式组合包编辑对应的 `temp`、`rep_pen` 等字段，最大回复长度为 `genamt`、上下文长度为 `max_length`（ST 保存文本补全预设时的字段）。未设置的参数不写入预设，交由模型默认值。
- 提示词管理：开关、拖动或箭头排序、编辑、新增与删除自定义条目；ST 内置条目和动态标记只能关闭，不能删除。
- 面板调整自动保存到当前分支，不修改预设库原件或其他分支；“恢复预设”清除本分支调整。“存入预设库…”创建并选中新资源，也可导出当前配置的 JSON（移除已识别凭据）。

**助手对话也可以按预设组装。** 绑定聊天补全预设或提示词包后，默认开启“助手对话也使用此预设”：编辑会话作为 `chatHistory`，最新用户消息作为 `{{lastUserMessage}}`，预设的主提示词、历史后指令、深度注入、角色卡与世界书照常参与；采样参数随请求发送。SillyDraft 的编辑规则与工具定义始终放在最前，不能被预设改变；预填参数无法与工具循环同时成立，会被移除并记录在任务输入的 `agentPreset` 中。宏变量在助手对话中的变化不提交为故事状态。文本补全模板不能用于助手对话，开启时会给出明确错误，可在预设面板关闭该开关；正文生成不受影响。

**兼容需要分别验证文件格式、提示词行为、模型参数和输出处理。** 导入成功只表示能够读取文件。只有已支持的提示词规则、当前模型能力和所需扩展都通过检查，才显示为可按预设运行；未支持功能明确列出。模型自身的生成结果不属于等价性承诺。

ST 的预设存储按 API 与格式分开，聊天补全预设、提示词包和高级格式组合包也走不同的导入路径。解析时依据结构识别类型，同时保留用户选择入口作为识别依据；结构冲突时显示类型选择，不能仅依赖文件名或 `name` 字段。[预设分类源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/src/endpoints/presets.js#L16)、[组合导入源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/preset-manager.js#L117)

| 输入类型 | 识别与主要内容 | SillyDraft 处理方式 |
| --- | --- | --- |
| Chat Completion 预设 | 通常包含采样参数、`prompts`、`prompt_order`，也有旧格式 | 导入完整配置，按当前连接能力编译；不能要求所有现代字段同时存在 |
| Prompt Manager 提示词包 | `version`、`type`、`data.prompts`、可选 `data.prompt_order` | 作为提示词集合导入，不能误当完整模型配置 |
| Text Completion 参数预设 | 如 `temp`、`top_p`、`top_k`、`rep_pen` | 与后端能力和其他文本模板组合使用 |
| Context Template | `name`、`story_string` 及位置、深度、角色等配置 | 编译人物、世界资料与上下文模板 |
| Instruct Template | `name`、`input_sequence`、`output_sequence` 等 | 序列化文本补全模型的角色边界、前后缀与停止串 |
| System Prompt | `name`、`content`、可选 `post_history` | 保留主提示词和历史后指令 |
| Reasoning Formatting | `name`、`prefix`、`suffix`、`separator` | 处理服务端返回中实际存在的对应格式，不能承诺取得模型未提供的内容 |
| 高级格式组合包 | `instruct`、`context`、`sysprompt`、`preset`、`reasoning`、`srw` 中的有效部分 | 分项导入并保留组合关系；不是聊天补全完整预设的别名 |
| Kobold、NovelAI 等参数预设 | 专用参数与后端类型 | 可识别、保留；运行支持随具体后端适配补齐 |

ST 导出的预设通常不含 `name`，ST 以文件名作为预设名；SillyDraft 同样在文件没有名字时使用去掉扩展名的文件名（如 `Reborn2.3.json` → `Reborn2.3`），世界书与正则一致。早期版本把这类预设存为“导入的预设”，升级时会按原文件名自动改名。未知字段与原始标识保留。编辑后导出时，回写已编辑的已知字段并保留其余数据；跨格式转换和敏感字段处理要列出变化，不能声称所有导出都是字节级无损。

**聊天补全的关键是复现组装语义。** `prompts` 保存条目定义，`prompt_order` 决定采用哪些条目、启停状态和相对顺序。完整预设中的顺序是按 `character_id` 分组的列表；独立提示词包中的顺序形状不同，需要单独解析。[提示词包导入导出](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/PromptManager.js#L632)

| 行为 | 兼容要求 |
| --- | --- |
| 条目标识与角色 | 保留 `identifier`、`name`、`role`、`content`、`system_prompt`、`marker`，不按显示名称推断含义 |
| 顺序与开关 | 使用被选中的 `prompt_order`，不把未启用条目重新拼回请求；重复 ID、无效引用分别诊断 |
| 当前顺序组 | 此基线中聊天补全使用全局虚拟 ID `100001`；原文件可能保留 `100000` 等历史组，不能直接取数组第一组 |
| 相对与深度注入 | 兼容 `injection_position`、`injection_depth`、`injection_order`；同深度时的角色分组、拼接与排序一并对照 |
| 生成触发条件 | 按 `injection_trigger` 和实际生成类型决定是否参与本次请求 |
| 角色卡覆盖 | 按 `forbid_overrides`、启停状态和卡片字段处理主提示词及历史后指令；保留 `{{original}}` 的原值语义 |
| 动态标记 | 填充角色描述、性格、章节、用户身份、世界书、对话示例与故事历史，而不是输出标记名称 |
| 旧格式迁移 | 识别 `main_prompt`、`nsfw_prompt`、`jailbreak_prompt` 等旧字段；迁移内部结构，同时保留导入来源 |
| 预算与输出前缀 | 保留上下文、输出预算、预填、继续生成和停止配置；实际生效受模型能力约束 |

虚拟 ID、注入分组及角色卡覆盖规则以 [openai.js](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/openai.js#L682) 为依据；默认值、触发与旧格式迁移以 [PromptManager.js](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/PromptManager.js#L31) 为依据。解析器按基线选择规则，多个无法对应的顺序组交由用户选择，不猜测为某个小说人物。

**正文生成服务与编辑 Agent 分开调用模型。** 编辑 Agent 负责理解要求、检索资料、调用工具和组织修改提案；正文生成服务接收不可变输入快照，按 ST 预设组织请求并返回候选正文。两者可以使用同一个模型配置，也可以分别设置。

```text
用户的创作要求
  → 编辑 Agent 确定任务与参考资料
  → 固定分支、正文版本、预设版本和变量快照
  → 构造故事历史与角色、世界书输入
  → 编译 ST 预设
  → 模型生成正文
  → 保存原始输出并按规则生成候选文稿
  → 用户采纳后形成正文新版本
```

预设中的角色扮演要求只作用于写作模型。它不能关闭应用中的工具校验、指定任意正文写入位置，或改变资料整理服务的输出协议。这样可以使用直接输出长篇文本的预设，而不要求它同时遵守编辑 Agent 的结构化工具调用协议。

首版预设默认绑定小说，单次任务允许临时覆盖；任务记录固定所用预设版本。预设更新不会改变已经生成的候选或历史版本。资料整理、分支建议和插画提示词使用各自的任务模板，除非用户明确选择应用某个写作预设。

**小说需要一个公开、稳定的 ST 输入映射。** 这是 SillyDraft 的设计约定，不是 ST 原有的小说功能。

| ST 输入 | 小说中的对应来源 |
| --- | --- |
| `charDescription`、`charPersonality` | 当前绑定的主要角色及其档案；其他人物作为相关资料提供 |
| `scenario` | 当前章节和开局设定 |
| `personaDescription`、`{{user}}` | 作品绑定的人设：`{{user}}` 是人设名字，`{{persona}}` 是人设描述后接“外貌：”“服饰：”两行（空的省略）；未绑定时为内置人设“我”。修改人设立即影响之后的生成与显示。ST 的人设描述插入位置（作者注释、指定深度）不支持，只经 `personaDescription` 标记进入提示词 |
| `worldInfoBefore`、`worldInfoAfter` | 本次触发、并符合当前分支和故事位置的世界书条目 |
| `dialogueExamples` | 卡中的示例，用于声音和文风参考，不视为已经发生的剧情 |
| `chatHistory` | 当前分支中已采纳章节构造的有序消息视图 |
| 当前用户消息 | 本次写作要求；不自动带入整个编辑会话 |

首版用稳定的章节记录构造历史消息，一段已采纳章节正文对应一个 assistant 消息；当前写作要求作为独立 user 消息。消息 ID 与章节及版本关联，不因屏幕分页、字号或段落自动换行而变化。编辑对话、工具日志、被拒绝候选和其他分支正文不进入该历史。

深度在该消息视图上按 ST 规则计算，并在请求预览中展示。写“下一章”使用正常生成语义；继续补完同一段模型输出才使用 ST 的 `continue` 路径。其他生成操作逐项建立映射，不能仅根据界面上的“续写”二字决定触发类型。

用户可以直接按导入预设生成，也可以创建“小说适配副本”，显式调整叙事视角、篇幅与正文格式。适配改动可比较、撤回，不静默把“扮演角色”替换成“小说旁白”。即便按原预设运行，小说提供的历史也与某个现成 ST 聊天记录不同，不承诺产出相同文字。

**Chat Completion 和 Text Completion 使用两条编译路径。** 前者保留消息的角色、顺序与注入；后者组合采样预设、Context、System Prompt 和 Instruct Template，输出文本及停止串。不能把 ChatML 等分隔符无条件再包进聊天接口的消息内容。

ST 的 `story_string` 先用 Handlebars 模板渲染，再做 ST 宏替换，并处理换行；因此它不是普通的字符串替换功能。[renderStoryString 源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/power-user.js#L2234)

SillyDraft 使用独立 Dart 模块实现预设解析、模板求值、宏求值、消息编译和模型适配。模板语法维护明确的受测范围；默认模板使用的条件块与换行必须先通过对照。复杂 helper 或扩展语法未支持时保留内容并报告，不能删掉后继续显示为完全兼容。

**宏与正则是预设行为的一部分。** 宏除了人物名称替换，还有变量读写等带状态操作；预设正则可以存放在 `extensions.regex_scripts` 中。[变量宏源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/macros/definitions/variable-macros.js)、[预设正则读取源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/extensions/regex/engine.js#L108)

- 基础宏覆盖人物、用户身份、章节、描述、原提示词等常用输入；变量宏覆盖首批样本实际使用的读写、增减和条件行为，未知宏报告为依赖缺口。
- `setvar`、`addvar` 及其 global 版本要求两个参数；参数缺失或多余时保留宏文本、不执行该次变量写入，记录 warning，继续编译和生成。显式空值 `{{setvar::体型差::}}` 合法；缺少分隔冒号的 `{{setvar::体型差:}}` 会原样保留。这与固定 ST 1.19.0 的参数检查及非阻断错误处理一致。[参数检查](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/macros/engine/MacroRegistry.js#L403-L419)、[错误处理](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/macros/engine/MacroEngine.js#L220-L237)
- 酒馆助手的助手宏 `{{get_(message|chat|global)_variable::路径}}` 和 `{{format_(message|chat|global)_variable::路径}}`（MVU 状态写入提示词的方式）内置支持：按路径读取变量（JSON 值按对象/数组取路径），`format` 输出 YAML 并按行首缩进。角色/预设变量域为空。
- ST 的 local/global 变量保留不同命名空间；在 SillyDraft 中附加项目和分支作用域。这是为剧情隔离作出的适配，不能宣传为跨聊天全局状态完全等价。
- 生成使用变量快照和任务内变更。预览、计算预算与正式发送复用一次编译结果，不重复执行变量副作用；候选的状态变更只有在采纳时才提交，其他候选丢弃或独立保留。
- 随机宏、时间宏和重试使用任务记录的求值结果或固定输入，保证同一次任务可诊断；重新生成可以显式产生新的一次求值。
- 正则保留 `placement`、`disabled`、`promptOnly`、`markdownOnly`、`runOnEdit`、深度范围、宏替换策略和捕获组替换规则。
- 全局、预设、角色卡正则按 ST 的来源顺序和适用阶段处理。Dart 与 JavaScript 的正则及替换边界通过样本对照，不预设所有表达式都可直接等价执行。

ST 对“仅提示词”“仅显示”和一般文本处理有不同执行条件。[正则阶段源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/extensions/regex/engine.js#L334)

SillyDraft 分别保存模型原始结果与候选正文。提示词专用正则不能修改已保存正文；显示专用规则不写回正文；用于清理生成文本的规则在候选采纳前应用，原始输出仍可追溯。正文导出以用户采纳的作品为准。替换结果中的 `html` 代码块和块级 HTML 片段按酒馆助手的渲染规则显示：代码块进入带脚本的隔离网页视图并获得消息、变量、事件和 Slash 命令接口；片段去除脚本和事件后显示。没有生成任务的章节（例如角色卡开场）按分支当前绑定的全局、预设和角色卡正则显示。范围、沙箱和未支持项见 [HTML 界面验证](verification/html-rendering.md)。

阅读设置中的「纯净模式」是可选的小说阅读投影，默认关闭并记住选择。开启后沿用 `HtmlBlocks.find` 的识别范围，隐藏 HTML 代码块、块级 HTML 片段和正文插图，不创建对应网页视图或显示源码；正文格式及书签、搜索的原文偏移映射保留。当前章节与续写预览均应用此设置，关闭后恢复正常显示，不修改存储、导出或模型上下文。这不是 ST 的新增语义；未被现有解析器识别为 HTML 块的内容仍按普通正文处理。对应 `html_block_flow_test.dart`、`reader_features_test.dart`。

HTML 高度沿用酒馆助手 `src/iframe/adjust_iframe_height.js` 的 `body.scrollHeight` 测量：普通内容展开和收起都同步调整，`details` 的隐藏子元素不再撑住空白；收缩动画持续跟随实际内容高度。只有 `body { height: 100% }` 等受框架高度约束的布局保留每次 DOM 变化后一次的可见底边收缩，避免视口比例面板反复缩小。

HTML 网页视图的默认背景透明，未指定背景的区域透出阅读器底色；HTML 自身声明的背景色和图片保留。`webview_flutter_wkwebview 3.27.0` 的背景设置在 macOS 会调用未实现的 `opaque` 接口，因此 macOS 通过原生通道关闭 WKWebView 的默认背景绘制。此处暂用 WebKit 的 `drawsBackground` KVC 属性（[上游缺口](https://bugs.webkit.org/show_bug.cgi?id=221663)），调用前检查 setter 是否存在；不支持时输出诊断并继续显示内容。原生修改须重新构建、重启，热重载无效。

HTML 未声明文字颜色时继承所在阅读器的正文颜色，切换阅读主题只更新默认色，不重载页面；页面自带颜色优先。原生网页视图额外把未消费的纵向滚轮／触控板 `wheel` 事件转给外层滚动容器：内部区域还能沿该方向滚动、页面调用 `preventDefault()` 或设置 `overscroll-behavior: contain/none` 时保留网页行为，到边界后才继续滚动正文。此为原生宿主的适配；手机触摸拖动仍由原有平台手势仲裁处理。

**酒馆输入框按小说续写适配。** ST 1.19.0 的 `#send_textarea` 与 `#send_but` 分别是聊天输入框和发送入口，`/setinput` 填入文本并返回管道值（依据固定提交的 `public/script.js`、`public/scripts/slash-commands.js`）。按产品要求，SillyDraft 将前端对该输入框的赋值、`input`/`change`、发送按钮和 `SillyTavern.getContext().generate()` 适配为直接续写下一章；同一轮赋值和发送合并，已有写作任务时拒绝重复启动。`/setinput` 同样直接续写，含 `/cut` 的管道仍确认改写。这是小说产品的语义适配，不等同于 ST 仅填入草稿。普通 HTML 片段无此权限；角色卡创建前的预览只保存要求。

**MVU 变量框架内置实现。** 社区角色卡常用 [MagVarUpdate（MVU）](https://github.com/MagicalAstrogy/MagVarUpdate) 维护状态：世界书 `[InitVar]` 条目给出初值，模型在回复末尾输出 `<UpdateVariable>` 中的 `_.set('路径', 旧值, 新值);//原因` 或 `<JSONPatch>` 命令，脚本把结果存为每条消息的 `stat_data`、`display_data`、`delta_data`、`schema`，并用 `{{get_message_variable::stat_data}}` / `{{format_message_variable::stat_data}}` 把状态送回提示词。SillyDraft 不运行该脚本，而是在核心包中实现同样的规则：从角色卡创建小说时初始化，生成候选时按上一章记录执行本章正文中的命令，采纳时提交；`<StatusPlaceHolderImpl/>` 追加到正文末尾供显示正则渲染状态栏，提示词中去掉。结构校验遵循 MVU 的 `$meta` 规则；角色卡自带 `registerMvuSchema` 脚本时默认关闭。额外模型解析、`[mvu_plot]` 分阶段过滤与 MVU Zod 的 zod 规则未实现。对应关系、差异与测试见 [MVU 验证](verification/mvu.md)。

**模型参数和连接配置分别处理。** 兼容层识别温度、top-p、top-k、重复惩罚、输出限制、上下文预算、停止串、预填及后端专用采样参数。目标模型是否接受某个参数，由模型适配层判断；缺省、关闭值和数值范围不能统一猜测。

**回复长度与上下文长度按 ST 的预设字段读取。** 聊天补全预设的回复长度是 `openai_max_tokens`。文本补全预设按 ST 保存的格式：回复长度是 `genamt`，`max_length` 是上下文长度（ST 保存时写入、载入时读回）；NovelAI 自带的预设没有 `genamt`，此时 `max_length` 是回复长度、`max_context` 是上下文长度。回复长度作为请求的最大输出 token 发送，预设未设置时用连接的最大输出 token。上下文长度一律取模型连接的「上下文 token 上限」：预设中的 `openai_max_context`、`max_length`、`max_context` 都不发送、也不参与写作前的预算检查；ST 不从预设读取的 `truncation_length` 同样不用。[保存字段](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/preset-manager.js#L744-L747)、[载入字段](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/script.js#L8121-L8136)、[NovelAI 预设](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/nai-settings.js#L177-L186)

不支持的参数显示为未生效。模型能力不足导致关键语义无法实现时，用户可以换连接或明确采用兼容降级；不默默转成另一种采样行为。

预设可能带代理地址、自定义请求头、请求体覆盖和密码，ST 自身也在导入导出时处理这些字段。[导入处理源码](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/openai.js#L4770)

导入预设不会自动切换当前连接。连接相关配置在导入预览中单独展示；密钥和已识别凭据进入本机密钥文件，不进入普通分享导出。需要保留的原始含密文件使用受保护存储。未知扩展字段继续保留，但不会自动获得网络、文件或工具执行能力。

**手机上提供导入预览、提示词条目编辑和可折叠的诊断。** 导入流程为：选择文件 → 识别预设类型 → 查看已支持项和缺口 → 绑定小说或保存到预设库。主界面只展示预设名称、作用范围和可用状态。

高级详情可以查看条目开关、顺序、注入位置，以及最终请求中的有效内容、来源和预算占用。不会把整个 ST 配置面板直接缩放到手机上。显示“哪些规则没有生效”和“是否会更换连接”，帮助用户作出实际选择。

内部保存预设原始数据、解析类型、归一化配置、来源版本和兼容诊断。任务保存预设版本引用、输入历史映射、变量快照与必要的编译记录；日志隐藏密钥等敏感内容。预设库可以复用同一配置，小说绑定关系独立保存。

**首版把主流聊天补全预设纳入写作闭环。** 其他格式仍属于项目兼容目标，按真实样本与后端能力逐项交付。

| 阶段 | 交付范围 |
| --- | --- |
| 第一阶段 | Chat Completion 完整预设与独立提示词包；旧字段迁移；条目顺序、开关、标记、角色卡覆盖、注入与触发；首批样本所需的基础及变量宏；文本正则；兼容报告与正文生成隔离 |
| 第二阶段 | Text Completion 与 Context、Instruct、System Prompt 组合；高级格式组合包；模板语法及 Reasoning Formatting；更多模型参数与正则边界 |
| 后续补齐 | 更广泛的社区预设、Kobold/NovelAI 等文本专用后端、扩展宏与特殊展示；每项单独标注支持状态 |

现有验收集合包含固定 ST 官方默认文件和自行构造的边界样本；用户尚未提供特定社区预设，不能声称已验证其全部依赖。社区预设出现新的必需依赖时，将该依赖纳入对应预设的交付条件；不以“JSON 已导入”替代行为验收。

验收以相同固定输入下的请求结构和文本为主，不比较两次模型随机生成的文字：

1. 区分完整聊天预设、独立提示词包及高级格式组合包；原样数据中的未知字段在未编辑往返时保留。
2. 对照 `100000` 与 `100001` 顺序组、关闭条目、缺失引用和重复标识，验证有效条目集合与次序。
3. 对照深度注入、同深度不同角色、注入优先级、空内容和不同生成触发类型。
4. 对照角色卡覆盖、`forbid_overrides` 与 `{{original}}`，验证实际拼装结果。
5. 对照变量宏、嵌套宏、预览和重试，确保一次编译不重复产生副作用，不串分支状态。
6. 对照世界书和故事历史映射，确保其他分支、未来剧情和未采纳内容不会进入请求。
7. 对照 Handlebars 与宏的处理顺序、空白、前后缀、停止串和继续生成行为。
8. 对照正则来源顺序、作用阶段、捕获组和深度范围；阅读显示规则不得改写正文数据。
9. 切换模型后，重新计算参数与预填支持情况；敏感连接字段不得静默改变发送目的地。
10. 保存原始响应、候选正文和依据版本，保证用户编辑后的正文不会被旧结果直接覆盖。

对照测试固定 ST 提交、人物卡、预设、历史、变量、时钟和随机输入；涉及预算截断时，还需固定模型和 tokenizer，或明确记录估算差异。用 ST 实际组装结果作为基准，逐项记录小说输入映射造成的差异。升级基线时先更新样本和差异说明，再扩大兼容声明。

## NovelAI 生图连接

NovelAI 文生图对齐固定基线 [SillyTavern 1.19.0 的 NovelAI 图片接口](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/src/endpoints/novelai.js#L306)：Bearer 密钥、`/ai/generate-image`、`action: generate`、`params_version: 3`、单图 `n_samples: 1`、正负提示词的 V4 caption 结构，以及 ZIP 内 PNG 的返回格式。默认使用 V4.5 Full、1024×1024、28 步、引导强度 5；提示词原样发送，不隐式加入质量标签。

只支持直连文生图与常用采样参数；不包含 NovelAI 文本后端、参考图编辑、Vibe Transfer、多角色定位、局部重绘、放大或 ST 生图扩展设置导入。取消仅终止等待，服务端可能继续执行和计费；不自动重试。常用模型列表为内置建议，不冒充服务端发现或连接验证。协议回归使用本地 HTTP 服务及 ZIP 图片，不调用付费模型。
