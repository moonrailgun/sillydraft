# 成本记录设计

## 目标

每一次模型请求都记一笔用量与成本，作者在设置里能看到整体花了多少钱：累计、按月、按连接与模型。

成本的来源按优先级：

1. **上游给了成本**，就用上游的数字。
2. **上游没给**，就按 ST 的做法，用模型列表里的单价乘 token 数。
3. **两者都没有**，就记为“无价格”。token 照记，总额旁边明确写出有多少次请求没算进去，不估、不猜。

本次不做：按作品或按任务统计、预算与超额提醒、手填单价、多币种、发送前的“最大成本”预估、导出账单。

## 现状

- **ST（1.19.0 / `06bde93`）不记录实际花费。** 它只对 OpenRouter、ElectronHub、Chutes 三个来源，在发送前显示一个“最大提示成本”：`completion 单价 × openai_max_tokens + prompt 单价 × (openai_max_context − openai_max_tokens)`（`public/scripts/openai.js` 的 `calculateOpenRouterCost`、`calculateElectronHubCost`、`calculateChutesCost`）。单价来自各来源的 `/models`：
  - OpenRouter（`https://openrouter.ai/api/v1`）：`data[].pricing.prompt` / `pricing.completion`，美元每 token，字符串。
  - ElectronHub（`https://api.electronhub.ai/v1`）：`pricing.input` / `pricing.output`，美元每百万 token。
  - Chutes（`https://llm.chutes.ai/v1`）：上游返回 `pricing.prompt` / `pricing.completion`，ST 服务端改名为 `input` / `output`（`src/endpoints/backends/chat-completions.js` 的模型列表处理），美元每百万 token。
  - 其他来源（OpenAI、Claude、DeepSeek、自定义等）ST 没有单价。NanoGPT 的模型列表只显示价格，不参与计算。缓存、推理、按次和图片费用都不计。ST 也不发 `stream_options.include_usage`。
- **SillyDraft 已经解析用量，但没有保存。** `GenerationFinished.usage` 带着上游 `usage` 原样传出：OpenAI 兼容接口取流里最后一个 `usage`，Claude Code 取 `result` 事件的 `usage`，Codex 取 `turn.completed` 的 `usage`，远程执行器和手机走桌面的路径都原样转发。写作、编辑助手、旁路整理任务拿到后就丢弃了，只有插图任务存在 `result.usage` 里。Claude Code `result` 事件顶层的 `total_cost_usd` 目前没有读取。
- **所有请求都经过两个工厂函数。** `AppServices.provider` / `imageProvider`（`lib/app/services.dart`）创建真实的 provider，`TaskRunner`、`WritingService`、`PersonaService`、`IllustrationService`、`RemoteHost` 都通过 `providerFactory` / `imageProviderFactory` 拿 provider；连接测试走 `draftProvider`。手机上 `provider` 返回 `DesktopModelProvider`，真正的请求在桌面的 `RemoteHost` 里，同样经过桌面的工厂。
- **token 计数**：核心只有 `estimateTokens`（`world_book_engine.dart`），是估算，提示里已注明“未绑定模型 tokenizer”。
- **数据库**：schema 10，只支持从 9 升级（加 `task_progress`），更旧的版本一律拒绝。

## 记账点

在 `AppServices` 创建**真实** provider 的地方包一层计量：`provider`、`imageProvider`、`draftProvider` 返回的 OpenAI 兼容、本地命令行、远程执行器、ComfyUI、NovelAI、OpenAI 图像 provider 都包。`DesktopModelProvider` / `DesktopImageProvider` 不包，桌面那一侧已经记过。测试注入的工厂不包。

计量层放在核心（`providers/` 下，一个文本、一个图像），只做转发和记账：

- 事件原样、及时地转发，不缓冲。
- 文本流结束后记一笔：
  - 收到 `GenerationFinished`：用它的 `usage`。
  - 失败或取消，但之前收到过任何文字、推理或工具调用：按估算记一笔，上游已经开始计费了。
  - 在任何输出之前就失败（连接失败、HTTP 4xx 等）：不记。
- 图像请求成功后记一笔，用 `GeneratedImage.usage`。失败不记。
- **记账绝不影响生成。** 记账（含拉取单价）不阻塞流的结束，失败只打日志，不抛给调用方。
- **去重**：请求带 `executionId` 时，以它作唯一键，插入时冲突就忽略。远程任务重连（`retrieveOnly`）取回的是同一个作业，不会记两次；如果原连接在记账前就断了，重连取回结果时补记。

## 一笔记录怎么算

### token

从 `usage` 归一成输入、输出两个数：

- 输入：`prompt_tokens`，没有时用 `input_tokens`；Anthropic 形状（Claude Code）再加 `cache_creation_input_tokens` 和 `cache_read_input_tokens`。Codex 的 `input_tokens` 已含缓存部分，不再加。
- 输出：`completion_tokens`，没有时用 `output_tokens`。

`usage` 里没有 token 数（例如官方 OpenAI 流式不带 usage、vLLM 系后端），或者是失败/取消的估算记录时，用 `estimateTokens` 估：输入是 `messages` 的 JSON（文本补全用 `completionText`），输出是收到的文字加推理。这一笔标为“估算”。不发 `stream_options.include_usage`：ST 不发，部分兼容后端还会因此拒绝请求。

### 成本

1. **上游**：`usage.cost` 是非负数时取它（OpenRouter 及兼容网关的约定，单位美元）。Claude Code 的解析器把 `result.total_cost_usd` 复制进 `usage`，同样当作上游成本。实现时按 OpenRouter 文档核对 BYOK 时的总额（`is_byok`、`cost_details.upstream_inference_cost`）。
2. **ST 单价**：只用于文本请求。连接是 OpenAI 兼容协议、地址的主机是上面三个来源之一时，用连接的密钥拉该来源的 `/models`，按 ST 的字段和单位取当前模型的单价，`输入 token × prompt 单价 + 输出 token × completion 单价`。和 ST 的唯一区别是 token 数用这次的实际值（或估算值），不用上限。单价为 0 就是 0，不算“无价格”。单价列表在进程内按来源地址缓存；拉取失败时这一笔记为无价格，下一次请求再拉。
3. **无价格**：其余情况，包括 Codex、NovelAI、ComfyUI、远程执行器背后没回传成本的上游、`/models` 里找不到该模型。

成本在记账时算好并冻结，之后单价变了也不重算，和任务冻结输入快照是同一个思路。币种只有美元。

## 存储

schema 升到 11，`onUpgrade` 在升到 11 的那一步建表（9 的库先经过 10 的 `task_progress`），更旧的版本照旧拒绝；新库在 `onCreate` 里一起建。新表 `usage_records`：

| 列 | 说明 |
|---|---|
| `id` | 主键，uuid |
| `execution_id` | 请求的 `executionId`，可空，唯一 |
| `created_at` | 毫秒时间戳 |
| `connection_id`、`connection_name`、`protocol`、`model` | 请求时的快照，连接改名或删除后历史照旧可读 |
| `kind` | `text` / `image` |
| `input_tokens`、`output_tokens` | 可空（生图引擎常常没有） |
| `tokens_estimated` | 0 / 1 |
| `cost_usd` | REAL，可空 |
| `cost_source` | `upstream` / `stPricing` / `unknown` |
| `usage_json` | 上游 `usage` 原文，供以后核对 |

按 `created_at` 建索引。不关联作品，删除作品不删记录；不进入作品备份与迁移导出。仓库方法放在新的 `part` 文件 `usage_store.dart`：写入一笔、按月汇总、按连接与模型汇总。

## 界面

设置页模型连接一节下加一行“用量与成本”：标题写累计金额和本月金额，副标题写“另有 N 次请求没有价格”（N 为 0 时不写）。点开是一个页面，两张表：

- **按月**：月份（本地时间）、请求数、输入 / 输出 token、成本。
- **按连接与模型**：同样的列，再加一列无价格次数。

含估算的金额前加“≈”，并在页面底部用一句话说明估算和无价格分别是什么意思。手机连着桌面时读的是桌面的库，看到的是同一份账。

## 文档

- `docs/st-preset-compatibility.md` 加一节“成本”：写 ST 的做法、SillyDraft 的差别（实际 token 而非上限）、缺口（只有三个来源有单价、token 估算不是 tokenizer、缓存不打折、币种只有美元）。
- `docs/user-guide.md` 说明在哪里看成本、“≈”和“无价格”是什么意思。

## 测试

核心（本地协议服务器，不调付费模型）：

- 上游 `usage.cost` 优先于单价。
- OpenRouter 形状的 `/models` 按每 token 计价，ElectronHub、Chutes 形状按每百万 token 计价，结果与 ST 公式一致。
- 非 ST 来源记为无价格，但 token 照记。
- 流中途取消：有输出时记估算，没有输出时不记。
- 同一 `executionId` 只记一笔。
- 记账抛错时生成照常完成。
- Claude Code 的 `total_cost_usd` 被当作上游成本。
- schema 9 的库能升级到 10，旧数据不变。

界面：设置页显示累计、本月和无价格次数；页面按月、按连接汇总正确。
