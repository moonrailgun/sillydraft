---
name: sync-baselines
description: 定期检查并同步 SillyDraft 按外部标准照搬的名单、规则和版本固定点：SillyTavern 生态（ST 固定提交、酒馆助手、MVU）、对接的外部接口（ComfyUI、NovelAI、Claude Code/Codex 命令行）与工具链。用户说“同步 ST”“升级 ST 基线”“同步 NovelAI”“更新 NovelAI 模型”“检查对齐对象更新”“定时同步配置”时使用，也用于定时任务的例行检查。
---

# 同步对齐基线

SillyDraft 与 SillyTavern 没有直接关系：它不是 ST 的分支或下游，不共享代码，也不跟随 ST 的开发。它直接复用 ST 的生态，用户的角色卡、预设、世界书、正则和社区前端都是为 ST 写的，所以凡是 ST 已有定义的行为都按 ST 的做法实现（见 `AGENTS.md`“首要原则”）。ST 只是其中一种需要兼容的标准；酒馆助手、MVU 等社区扩展也是，ComfyUI、NovelAI、Claude Code/Codex 则是对接的外部接口。下文统称“对齐对象”，**不要称为“上游”**。

每个对齐对象都按固定版本实现。对齐对象发新版后，代码里照搬的名单和规则会过时。本技能用来检查差异、更新基准、同步实现和文档。

## 原则

- 对照数据只由脚本从对齐对象的源码生成，不手改 `test/fixtures/st/*-reference.json`，也不为让测试通过而改基准。
- 先看差异，再改代码。升级 ST 基线会影响全部文档链接和行为，**先把差异摘要报告给作者，确认后再升级**。例行检查只报告，不升级、不提交。
- 跟进新版是为了继续兼容用户手里的资源，不是照单全收：新版改了已有行为时，先判断对用户资源的影响，再决定是否跟进；决定不跟进的，在文档中写明差异。
- 每个同步项改完都更新对应文档（主要是 `docs/st-preset-compatibility.md`、`docs/verification/`），行为差异写明依据。
- 新增照搬对齐对象的名单或规则时，把它登记进下方清单。

## 一、检查 ST 是否有新版本

```sh
grep -m1 "const commit" packages/sillydraft_core/tool/capture_st_reference.mjs   # 当前固定提交
git ls-remote https://github.com/SillyTavern/SillyTavern refs/heads/release      # release 分支最新提交
git ls-remote --tags --refs https://github.com/SillyTavern/SillyTavern | awk -F/ '{print $3}' | sort -V | tail -3
```

release 分支没有前进就不用升级，跳到“四”复核其他对齐对象。前进了，就在本地 ST 仓库（`~/Develop/SillyTavern`，先 `git fetch`）中看清单涉及的文件改了什么：

```sh
git -C ~/Develop/SillyTavern diff --stat <旧提交> <新提交> -- \
  public/script.js public/scripts/openai.js public/scripts/instruct-mode.js \
  public/scripts/PromptManager.js public/scripts/preset-manager.js public/scripts/power-user.js \
  public/scripts/macros/ public/scripts/world-info.js public/scripts/extensions/regex/engine.js \
  public/scripts/authors-note.js public/scripts/reasoning.js public/scripts/nai-settings.js \
  src/constants.js src/endpoints/backends/chat-completions.js src/endpoints/novelai.js \
  default/content/ package-lock.json
```

## 二、升级 ST 基线（作者确认后）

1. 替换所有出现旧提交的地方：`grep -rl <旧提交> --exclude-dir=build --exclude-dir=.dart_tool .`，包括 `capture_st_reference.mjs`、`AGENTS.md`、`README.md`、`docs/`、代码注释。版本号（如 1.19.0）一并更新；`pubspec.lock` 里的 `meta 1.19.0` 与 ST 无关。
2. 文档和注释里的链接带行号（如 `#L2545-L2664`），升级后逐个在新提交里重新定位。
3. 重新生成对照数据并看差异：

   ```sh
   cd packages/sillydraft_core
   node tool/capture_st_reference.mjs
   git diff test/fixtures/st/
   ```

4. 从新提交重新下载 `test/fixtures/st/manifest.json` 列出的官方样本（默认预设与模板），更新其中的提交和 SHA-256，看差异。这些文件不由脚本生成。
5. 按差异逐项更新下方清单中的实现，然后运行：

   ```sh
   dart test test/st_compiler_test.dart test/provider_test.dart test/st_import_test.dart test/novelai_image_test.dart
   dart test
   cd ../.. && flutter test
   ```

## 三、ST 同步清单（随基线升级）

路径中 `core/` 指 `packages/sillydraft_core/lib/src/`，`test/` 指 `packages/sillydraft_core/test/`。

### 推理强度 `reasoning_effort`（有对照数据）

| | |
|---|---|
| 来源 | `src/constants.js` 的 `OPENAI_REASONING_EFFORT_MODELS`、`OPENAI_FIXED_REASONING_EFFORT`；`public/scripts/openai.js` 的 `getReasoningEffort`；`src/endpoints/backends/chat-completions.js` 中注释 “A few of OpenAIs reasoning models support reasoning effort” 后的过滤 |
| 实现 | `core/providers/openai_compatible.dart`：`stReasoningEffortModels`、`stFixedReasoningEffort`、`stReasoningEffort` |
| 对照 | `test/fixtures/st/reasoning-effort-reference.json`，由 `capture_st_reference.mjs` 生成；`provider_test.dart` 校验名单一致、各用例结果一致 |
| 文档 | `docs/st-preset-compatibility.md`“推理强度 `reasoning_effort` 只在 ST 会发送时发送” |

名单有变化时把 `stReasoningEffortModels` 改成与 JSON 中 `models` 相同（顺序也相同）。`functionSha256` 或 `filterSha256` 变化说明 ST 改了规则，读新源码再改 `stReasoningEffort`。脚本报 “Pinned … missing” 说明 ST 改了函数名或注释，先在新源码里找到对应位置再改脚本。OpenAI 发布新推理模型后，ST 通常在下个版本把它加入名单；在此之前，用户可以在连接的“后端支持的额外参数”里手动启用。

### 其他有对照数据的项

| 项 | 来源 | 实现 | 对照 |
|---|---|---|---|
| 深度注入顺序 | `openai.js` `populationInjectionPrompts` | `core/st/prompt_compiler.dart` | `injection-reference.json`，`st_compiler_test.dart` |
| 文本补全序列 | `instruct-mode.js` `formatInstructMode*`、`getInstructStoppingSequences`；`script.js` `Generate` | `core/st/text_compiler.dart` | `text-format-reference.json`，`st_compiler_test.dart` |
| 文本补全预设的参数键 | `textgen-settings.js` `setting_names` | `core/st/preset_importer.dart` `_parameterKeys` 末尾一段 | `textgen-settings-reference.json`，`st_import_test.dart` |
| NovelAI 生图模型列表的 ST 部分（第一项是默认模型） | `extensions/stable-diffusion/index.js` `loadNovelModels` | `core/providers/novelai_image.dart` `models`；V5 扩展见第四节 | `novelai-models-reference.json`，`novelai_image_test.dart` |

文本补全参数键：`setting_names` 新增的项默认加进 `_parameterKeys`；如果它不是请求参数（模型选择、连接状态、界面设置），就加进 `st_import_test.dart` 的 `notParameters`，并在 `_parameterKeys` 的注释和文档里写明。NovelAI：ST 部分跟着 JSON 改，顺序也相同；保留官方 V5 扩展，ST 纳入后去重，同时看 `novelai.js` 的请求体有没有按模型区分。

### 没有对照数据、需要读源码比对的项

升级时对每项读 ST 的改动，有变化就改实现、补测试、改文档。

| 项 | 来源 | 实现 | 现有测试 |
|---|---|---|---|
| 宏注册表（名字、别名、参数个数；文档写明 105 个宏、31 个别名） | `public/scripts/macros/definitions/`，及 `authors-note.js`、`reasoning.js`、memory、stable-diffusion、expressions 扩展 | `core/st/macro_engine.dart` 注册部分 | `macro_engine_test.dart` |
| 宏词法、解析、块配对、前后处理 | `macros/engine/MacroLexer.js`、`MacroParser.js`、`MacroCstWalker.js`、`MacroEngine.js` | `core/st/macro_engine.dart` | `macro_engine_test.dart` |
| 宏环境、全新安装的指令/上下文/推理模板 | `env-macros.js`、`MacroEnvBuilder.js`、`instruct-mode.js`、`power-user.js`、`default/content/settings.json` | `core/st/macro_env.dart` | `macro_engine_test.dart` |
| moment.js 子集 | ST `package-lock.json` 中的 moment 版本（当前 2.30.1） | `core/st/moment.dart` | `macro_engine_test.dart` |
| 世界书扫描默认值、`GENERATION_TYPE_TRIGGERS`、支持的插入位置、扫描字段、`convertCharacterBook` | `world-info.js`、`src/constants.js`、`default/content/settings.json` | `core/st/world_book_engine.dart`、`core/st/world_book.dart`、`lib/features/settings/world_info_budget.dart` | `world_book_engine_test.dart`、`test/world_info_budget_test.dart` |
| 正则脚本规则、`sanitizeRegexMacro`、placement 编号 | `extensions/regex/engine.js` | `core/st/regex_pipeline.dart`；placement 数字散落在 `prompt_compiler.dart`、`tasks/task_runner.dart`、`model/manuscript_presentation.dart`、`lib/features/resources/resource_preview.dart` | `macro_engine_test.dart`、`st_compiler_test.dart` |
| 聊天补全预设的参数键、连接字段 `_connectionKeys`、预设类型识别 | `openai.js` `settingsToUpdate`（第四项为 true 的是连接设置）、`preset-manager.js` | `core/st/preset_importer.dart` | `st_import_test.dart` |
| 凭据字段（导入时隐藏） | 同上 | `core/st/import_types.dart` `credentialKeys` | `st_import_test.dart` |
| 文本预设字段别名、角色卡覆盖、提示词标记（含未填充扩展标记的选择） | `preset-manager.js`、`script.js` `setGenerationParamsFromPreset`、`nai-settings.js`、`openai.js` `preparePromptsForChatCompletion` / `populateChatCompletion` | `core/st/prompt_compiler.dart` | `st_compiler_test.dart`、`agent_preset_test.dart` |
| PromptManager 内置条目 | `PromptManager.js` | `lib/features/resources/preset_prompt_editor.dart` | `test/preset_panel_test.dart` |
| 采样参数界面的字段与范围 | `public/index.html` 滑块、`preset-manager.js` | `lib/features/presets/preset_screen.dart` | `test/preset_panel_test.dart` |
| 默认允许的额外采样字段（四项） | `openai.js` OpenRouter / NanoGPT 分支；Custom 不默认发送，差异见兼容文档 | `core/providers/provider.dart` `stSamplingParameters`；`openai_compatible.dart`；连接高级参数开关 | `provider_test.dart`、`test/model_settings_flow_test.dart` |
| 对话引号、强调（showdown 及 ST 选项） | `script.js` `messageFormatting`；ST `package-lock.json` 中的 showdown 版本（当前范围 ^2.1.0） | `lib/features/reader/reader_markup.dart`、`core/html/html_blocks.dart` 围栏规则 | `test/reader_markup_test.dart`、`html_blocks_test.dart` |
| HTML 片段净化 | ST `package-lock.json` 中的 DOMPurify 版本（当前范围 ^3.4.2）及 `messageFormatting` 的净化配置 | `core/html/html_blocks.dart` 净化部分 | `html_blocks_test.dart` |
| NovelAI 请求体，以及按采样器和模型强制关闭 `sm`/`sm_dyn` | `src/endpoints/novelai.js` `/generate-image`；`extensions/stable-diffusion/index.js` | `core/providers/novelai_image.dart` 请求体部分 | `novelai_image_test.dart` |

## 四、其他对齐对象与外部接口（不随 ST 升级，每次检查都看）

酒馆助手、MVU、ComfyUI 各自独立发布，与 ST 的版本无关，核对过的提交记在下表“记录位置”。检查时列出记录的提交到它们最新提交之间改了哪些文件：

```sh
gh api repos/<仓库>/compare/<记录的提交>...<分支> --jq '.files[].filename'
```

只看表中“关注”的文件。核对并同步完，把新提交、日期和链接写回记录位置。NovelAI 按下方流程核对官方文档和前端构建；Claude Code、Codex 和工具链按版本号检查。

| 对象 | 记录位置 | 关注 | 实现 | 测试 |
|---|---|---|---|---|
| [Pi](https://github.com/earendil-works/pi) v1.3.0：工具循环与自动压缩 | `docs/st-preset-compatibility.md`“Agent 循环与上下文压缩” | `packages/agent/src/agent-loop.ts`、`packages/coding-agent/src/core/compaction/compaction.ts`；只对照已采用的循环和压缩机制 | `core/tasks/agent_runner.dart`、`core/tasks/agent_compaction.dart` | `agent_compaction_test.dart`、`agent_write_state_test.dart`、`sidecar_test.dart` |
| [智绘姬 st-chatu8](https://github.com/damoshen123/st-chatu8)：独立生图上下文、角色与服装视觉资料 | `docs/st-preset-compatibility.md`“插图的视觉资料与画面规则”，固定 `6e159481b15a975ba4ab2ba43d449d659eca6cd5` | `index.js` 的 `processImageLikeRequest`、`processCharacterPrompt`；只对照已采用的机制，不自动导入外部分发预设 | `core/agent/editor_agent.dart`、`core/agent/image_prompt.dart`、`core/agent/persona_service.dart` | `illustration_prompt_test.dart`、`persona_service_test.dart`、`agent_image_test.dart` |
| [酒馆助手 JS-Slash-Runner](https://github.com/N0VI028/JS-Slash-Runner)（分支 `main`）：前端块识别、`srcdoc` 骨架与 `vh` 改写、高度算法、接口函数名、事件名、斜杠命令、助手宏 | `docs/verification/html-rendering.md` 第一段 | `src/util/is_frontend.ts`、`src/panel/render/iframe.ts`、`src/iframe/`、`src/function/`、`@types/function/` | `core/html/html_blocks.dart`、`core/html/tavern_runtime.dart`（接口列表、事件、高度）、`core/html/tavern_bridge.dart`、`lib/features/html/html_block_view.dart`、`core/st/macro_engine.dart` 助手宏 | `html_blocks_test.dart`、`tavern_bridge_test.dart`、`integration_test/html_*_test.dart` |
| 酒馆助手预载的 lodash、jQuery、Font Awesome（只固定大版本）、jQuery UI 1.14.2、Touch Punch 0.2.3、showdown 2.1.0、Vue 3.5.43、VueRouter 5.4.0、Zod 4.4.3、YAML 2.9.1、Tailwind 4.1.12 | `docs/verification/html-rendering.md`“公共依赖” | `src/iframe/third_party_message.html`、`src/iframe/predefine.js`、`src/third_party_object.ts`、`package.json` | `core/html/html_blocks.dart` 中的 CDN 地址与 Vue 标志；`core/html/vendor/` 用 `packages/sillydraft_core/tool/bundle_frontend_libraries.mjs` 重建 | `html_blocks_test.dart`、`integration_test/html_libraries_test.dart` |
| [MVU MagVarUpdate](https://github.com/MagicalAstrogy/MagVarUpdate)（默认分支 `beta`，发布分支 `master`，两者都要看）：命令语法、JSONPatch、`$meta` 结构、记录字段、全局 `Mvu` 对象 | `docs/verification/mvu.md` 第一段 | 该段列出的 `src/function/` 文件与 `tests/` | `core/mvu/`、`core/html/tavern_runtime.dart` 的 `Mvu` 部分 | `mvu_test.dart`、`tavern_bridge_test.dart` |
| ComfyUI 画布转 API 格式 | `docs/st-preset-compatibility.md`“ComfyUI 工作流读取”，`core/providers/comfy_workflow.dart` 注释 | Comfy-Org/workflow_templates 的 `scripts/comfyui_node_compat/workflow.py`、Comfy-Org/ComfyUI_frontend 的 `docs/WIDGET_SERIALIZATION.md`。按文件查最新提交：`gh api "repos/<仓库>/commits?path=<文件>&per_page=1" --jq '.[0].sha'` | `core/providers/comfy_workflow.dart` | `comfy_canvas_test.dart`、`comfy_workflow_files_test.dart` |
| NovelAI 生图模型及请求格式 | `docs/st-preset-compatibility.md`“NovelAI 生图连接”中的日期、官方前端构建和来源链接 | 官方模型文档、图片 OpenAPI、前端实际可选模型与请求参数，按下方流程核对 | `core/providers/novelai_image.dart` | `novelai_image_test.dart`、`agent_image_test.dart`、`test/model_settings_flow_test.dart`（仓库根目录） |
| Claude Code、Codex 命令行：参数、流式事件名、登录检查 | 无（按版本号） | `claude --version`、`codex --version` 及各自 `--help`；测试只用假脚本，**须用真实命令行跑一次写作**确认 | `core/providers/local_cli.dart` | `local_cli_test.dart` |
| Codex 生图协议与对话模型单价 | `docs/st-preset-compatibility.md`“Codex 订阅生图连接”“成本”，CLI 0.165.0 / 单价快照 2026-10-29 | 实验性 App Server Schema 的实际模型、累计与单次用量、缓存读写、模型切换及图片用量字段；[OpenAI 定价](https://developers.openai.com/api/docs/pricing)、模型页的长上下文规则、[缓存时长](https://developers.openai.com/api/docs/guides/prompt-caching)。只登记核实的精确 ID，保留“对话估算、未含图片费”范围 | `core/providers/codex_image.dart`、`core/providers/codex_pricing.dart`、`core/providers/usage_meter.dart`、`core/storage/usage_store.dart` | `codex_image_test.dart`、`usage_meter_test.dart`、`usage_store_test.dart`、根目录 `test/usage_screen_test.dart`（本地假协议，不调用付费模型） |
| 工具链：Flutter 3.47.7 / Dart 3.13.5 | 无（按版本号） | Flutter stable 发布页 | `AGENTS.md`、`README.md`、`docs/building.md`（含 Impeller 绕过说明）、`.github/workflows/`、各 `pubspec.yaml` 的 sdk 约束 | CI |

### NovelAI 生图同步操作

每次例行检查都执行，即使 ST 没有更新。只要求检查时报告差异；要求同步 NovelAI 时按以下范围更新，不连带升级 ST 基线。

1. 读取 `docs/st-preset-compatibility.md`“NovelAI 生图连接”的上次记录，对照 [官方模型说明](https://docs.novelai.net/en/image/models/)、[图片 OpenAPI](https://image.novelai.net/docs/doc.json)和[官方生图页面](https://novelai.net/image)。确认公开可用的模型、弃用情况及图片接口变化。
2. 文档没有精确模型 ID 或参数时，从生图页面 HTML 找出本次构建加载的脚本，下载相关 JS 到临时目录，搜索 `nai-diffusion-`、`params_version`、`v4_prompt`、`v4_negative_prompt`、`generate-image`，沿模型菜单、默认参数和请求组装处核对。每次从页面重新定位脚本，不复用旧 chunk 文件名；被阻止时可用 `curl -L --fail -A 'Mozilla/5.0'` 读取公开页面，仍不可读则报告未核实项。只把实际出现在公开模型菜单、且受当前文生图接口支持的模型加入选项，不把 bundle 中每个字符串都当作可用模型。
3. 比较 `core/providers/novelai_image.dart` 的 `models` 和请求体：模型 ID、`params_version`、正负 caption 结构、尺寸/步数/采样器限制、返回格式。先列出变化与证据。模型发现接口须确认返回的是**图片模型**；不能把文本补全的 `/oa/v1/models` 当作图片模型列表。未确认图片发现接口时继续维护内置名单，保留手填 ID。
4. 同步已核实的模型与必需请求参数，保留现有默认模型和旧模型行为；新模型放在 ST 列表之后，ST 后续纳入时去重。官方菜单隐藏旧模型不等于接口已停用，删除选项需停用依据。NovelAI 单独同步不改 `capture_st_reference.mjs` 或 `novelai-models-reference.json`，新增模型在测试中单独断言。参考图等新增能力只记录缺口，不随模型名单同步扩展实现。
5. 为新增或变化的模型补本地 HTTP 请求与 ZIP 响应测试，同时保留旧模型回归。从仓库根目录运行以下检查，并按 `AGENTS.md` 完成受影响代码的分析和格式检查；不调用付费模型：

   ```sh
   (cd packages/sillydraft_core && dart test test/novelai_image_test.dart test/agent_image_test.dart)
   flutter test --no-pub test/model_settings_flow_test.dart
   ```

6. 更新 `docs/st-preset-compatibility.md` 的检查日期、前端构建标识、来源链接、参数差异与未核实项；用户可见的模型或配置变化同步到 `docs/user-guide.md`，代码来源注释一并更新。报告区分本地协议测试与真实服务验证，不能把前者写成实际生图成功。

## 已知缺口（待处理时从这里划掉）

- 聊天补全预设里与请求有关的 `verbosity`、`show_thoughts`、`enable_web_search` 当前保留原值但不应用，导入时逐字段给出 `preset_setting_not_applied` warning。后续实现映射时需核对 ST 服务端适配；例如 ST 会把 `verbosity` 发给 `OPENAI_VERBOSITY_MODELS` 匹配的模型（`chat-completions.js` 推理强度过滤之后的一段）。
- NovelAI：ST 在 ddim 采样器或 V4 Full、V4 Curated 模型下强制关闭 `sm`、`sm_dyn`，这里没有（文档已写明差异）。
- `manifest.json` 和对照数据里的 SHA-256 没有测试校验。
- `GENERATION_TYPE_TRIGGERS`、正则 placement 编号、PromptManager 内置条目、`credentialKeys`、OpenAI 兼容连接转发的参数集合，都没有标注来源，也没有测试列出完整集合。
- showdown、DOMPurify 的确切版本没有记录（应取 ST `package-lock.json` 中的版本）。

## 定时运行

可以用 Claude Code 的 `/schedule` 建立每月一次的例行任务，提示词写：“在 sillydraft 仓库运行 sync-baselines 技能，只检查并报告差异，不升级基线、不提交”。
