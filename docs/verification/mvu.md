# MVU 变量框架验证（MagVarUpdate 兼容）

对照对象：[MagVarUpdate（MVU）](https://github.com/MagicalAstrogy/MagVarUpdate) `master` 分支的 `src/function/update_variables.ts`、`src/function/initvar/variable_init.ts`、`src/function/schema.ts`、`src/function/update/structured_update.ts`、`src/function/request/filter_prompts.ts`、`src/function/global/index.ts` 及其 `tests/`；[酒馆助手](https://github.com/N0VI028/JS-Slash-Runner) `src/function/macro_like.ts` 的 `get_*_variable` / `format_*_variable` 宏；酒馆助手文档《变量管理器》。SillyDraft 内置这些行为，不运行 MVU 的脚本库。

## 对应关系

| MVU / 酒馆助手 | SillyDraft |
| --- | --- |
| 每条消息的变量表 `stat_data`、`display_data`、`delta_data`、`schema`、`initialized_lorebooks` | 同名变量保存在分支该章的版本化局部变量中（JSON 字符串）；`MvuData.fromStored` / `toStored` |
| 新聊天加载时读取名称含 `[InitVar]` 的世界书条目（可关闭）初始化 | 从角色卡开始创建小说时 `createNovelFromCard` 读取角色卡世界书的 `[InitVar]` 条目；绑定的额外世界书在“重新读取初始变量”或写作请求时参与。条目支持 YAML / JSON / 宽松 JSON，去掉 `<initvar>` 包裹与代码围栏，先做宏替换；同一世界书内按顺序深合并（数组整体替换），已有顶层键保留 |
| 开场白中的 `<initvar>` 块覆盖世界书初值；开场白中的 `_.set` 等命令在初值上执行 | `MvuInit.openingOverride` 与 `MvuUpdater.apply(opening)`；切换开场后用“重新处理变量”重算 |
| `$meta.extensible` / `recursiveExtensible` / `required` / `template`、`$__META_EXTENSIBLE__$`、`$arrayMeta` 生成 schema，之后从数据中清除 | `MvuSchema.generate` / `cleanUpMetadata`；根 `$meta.strictTemplate`、`concatTemplateArray`、`strictSet` 保留在 schema |
| 命令扫描：全文中的 `_.set/insert/assign/remove/unset/delete/add(...);//原因`（括号配对、引号内忽略、必须有分号），`<think>/<thinking>/<reasoning>/<analysis>/<analyze>` 内忽略；`<JSONPatch>` 块内 RFC 6902 风格 `replace/delta/insert/add/remove/move` | `MvuCommandParser.extract`，JSON Patch 路径按 JSON Pointer 分段转为精确方括号路径；补丁块可带代码围栏、注释与尾随逗号 |
| 参数求值：JSON → JSON5 数据字面量 → 单引号文本（YAML）→ mathjs 表达式 → YAML → 去引号字符串 | `MvuValue.parseCommandValue`；表达式用内置安全求值器（四则、`^`、括号、`Math.`/`math.` 前缀的常用函数与常量），不支持矩阵、复数、求导、单位；`YYYY-MM-DD` 形式保留为字符串而不是做减法 |
| 路径修正 `pathFix` | 逐条移植 |
| `set`：路径必须存在；`[值, 说明]` 只改值；旧值为数字时字符串转数字；`strictSet` 关闭该行为 | 相同；显示串 `旧->新 (原因)` |
| `insert/assign`：基本类型拒绝；对象不可扩展时拒绝合并与新键；数组不可扩展拒绝；父路径必须存在；两参数追加/合并，三参数按索引或键插入（`-` 追加）；模板应用；之后为新结构补充 schema | 相同 |
| `delete/remove/unset`：数组索引路径、整路径、按值/索引/键删除；不可扩展数组与必需键拒绝 | 相同 |
| `add`：数字增量（12 位有效数字）、ISO 日期毫秒增量；`[值, 说明]` 作用于值 | 相同 |
| `move`（仅 JSON Patch）：上游只解析不执行 | SillyDraft 执行移动（扩展） |
| 更新后 `display_data` = 完整数据且变更路径替换为显示串，`delta_data` 只含变更；数据有变动则重新调和 schema | 相同 |
| 角色卡自带 `registerMvuSchema`（MVU Zod）脚本时，schema 变为 `any`，结构校验交给脚本 | 不运行脚本；检测到该脚本时结构校验默认关闭（schema `{"type":"any"}`），变量管理器可手动开关（`writing/<分支>` 的 `mvuSchemaChecks`） |
| 收到回复后：从上一条含变量的消息取数据，执行本条消息中的命令，去掉 `<status_current_variable>` 块，末尾追加 `<StatusPlaceHolderImpl/>`，写入本条消息 | 生成完成时从上一章的记录（第一章为初值）执行整章正文中的命令；写入正文时随其他变量一起提交，生成期间正文或变量有变化则不写入。追加续写时整章只保留一个占位符 |
| 变量按楼层的 swipe 保存，切换 swipe 即换成该 swipe 的变量；改动前面的楼层不重算后面的楼层 | 章节版本相当于 swipe：从版本历史恢复时，该章变量回到那个版本写入的记录（那个版本及其前身都没有记录时沿用前面章节的状态），状态不变时不写入；后面章节的记录不变（`restoreRevision`） |
| 发送提示词时去掉 `\n<StatusPlaceHolderImpl/>`；“随AI输出”模式保留 `<UpdateVariable>`（由角色卡的仅提示词正则移除） | `PromptCompiler` 去掉历史中的占位符；`<UpdateVariable>` 交给正则 |
| `{{get_message_variable::路径}}`、`{{get_chat_variable}}`、`{{get_global_variable}}`、`{{get_character_variable}}`、`{{get_preset_variable}}`：字符串原样，其余 JSON；`{{format_*_variable::路径}}` 输出 YAML（多行按宏所在列缩进），`_quoted` 变体字符串加双引号；去掉 `$` 开头的键 | `MacroEngine`：`message`/`chat` 读当前章局部变量，`global` 读分支共享变量；角色/预设作用域暂为空表 |
| 额外模型解析、工具调用、`[mvu_plot]` / `[mvu_update]` 条目按阶段过滤、通知设置 | 未实现；始终按“随AI输出”处理，`[mvu_update]` 条目照常进入提示词 |
| 全局 `Mvu`：`getMvuData`、`replaceMvuData`、`parseMessage`、`reloadInitVar`、`getMvuVariable`、`setMvuVariable`、`getRecordFromMvuData`、`events` | HTML 界面内：读写走页面变量快照；`parseMessage` 与 `reloadInitVar` 经桥接 `mvuParseMessage` / `mvuReloadInitVar` 在 Dart 端执行并触发 `mag_variable_update_started/ended` |
| 变量管理器：全局 / 预设 / 角色 / 聊天 / 消息楼层 分页与 JSON 编辑器 | 资料页的“故事变量”：五个分页、JSON 编辑、按楼层查看与重算，MVU 操作“重新读取初始变量”“重新处理变量”“结构校验开关” |

## 已知差异

- 变量按分支与故事位置隔离；只有写入正文时才提交模型产生的变更。
- 一章内多次续写时，该章的记录始终是“上一章记录 + 本章全文命令”，与 MVU 按消息计算一致；提示词展示的是该章当前已保存的记录。
- 不执行角色卡脚本：MVU Zod 的 `prefault`/`clamp` 等 zod 规则不生效，只关闭结构校验。
- 表达式求值不含 mathjs 的高等运算；日期字符串不参与减法。
- 角色/预设作用域变量来自界面写入的 `htmlVariables/<分支>`，提示词宏中暂不读取。
- 变量管理器保存时校验分支变量版本，界面打开后别处（写入正文、恢复版本、HTML 界面）写入的变化会让保存被拒绝而不是被覆盖；楼层页按需读取每一章的变量。

## 验证

| 证据 | 内容 |
| --- | --- |
| `packages/sillydraft_core/test/mvu_test.dart` | 参数拆分、取值优先级、路径修正、宽松 JSON/YAML；脚本命令与 JSON Patch 提取、思考块忽略、分号要求；`set` 配对值与数字转换、`insert` 可扩展/模板/必需键、`delete` 变体、`add` 数字与日期、`move`、`any` schema；初值合并、包裹去除、开场覆盖；从角色卡创建时初始化、schema 脚本检测、生成→采纳→变量写入→占位符唯一→下一次提示词包含最新状态且不含占位符、重新处理与重新读取初值、桥接解析；开场 `<initvar>` 覆盖在重新处理与写作请求中保留、章内选区改写后占位符唯一且空行不累积、`{{lastMessage}}` 不含占位符 |
| `packages/sillydraft_core/test/chapter_snapshot_test.dart` | 每章写入后各有状态快照、按章分叉；恢复版本时该章状态随版本来回切换、恢复到写作前的空白版本时沿用前一章、后面章节不受影响 |
| `packages/sillydraft_core/test/macro_variable_test.dart` | `get_*_variable` / `format_*_variable` 宏 |
| `test/variables_flow_test.dart` | 变量管理器：MVU 状态卡、JSON 编辑保存、无效 JSON 报错、重新处理、按楼层查看 |
| `packages/sillydraft_core/test/mvu_review_test.dart` | 审查后补充：复数 `status_current_variables` 与任意大小写占位符的清理；结构校验开关对已存储记录生效；角色卡解绑后以已存记录为基准；`reloadInitVar` 无条目返回空、条目损坏报错；界面写入不含 `stat_data` 的变量表时保留 MVU 记录 |

真实角色卡《道渊》v5.4.2 的 `[initvar] 初始` 条目为 YAML（含 `$器灵台词` 等 `$` 开头键），输出格式为 `<UpdateVariable><Analysis>…</Analysis><JSONPatch>[…]</JSONPatch></UpdateVariable>`，`变量列表` 条目使用 `{{format_message_variable::stat_data}}`，并自带 ZOD 脚本；上述测试以同结构的缩减样本覆盖这条路径。
