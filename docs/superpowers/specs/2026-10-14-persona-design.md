# 人设（Persona）设计

## 目标

为 ST 的 `{{user}}` / `{{persona}}` 提供可复用的人设：作者可以建多个人设，附参考图与外貌、服饰，供之后的生图和服饰推演取用。内置一个人设“我”。创建尽量省事：看图反推、AI 补全润色、由外貌生成参考图。

本次不做：把人设参考图接进插画生成页、服饰推演、导入 ST 的 persona 备份、ST 人设描述的插入位置（作者注释 / 指定深度）。

## 现状

- 每个分支的 `writing/<分支>` 设置存两段自由文本：`userName`（缺省“主角”）与 `persona`。“从角色卡新建小说”页（`card_start_screen.dart`）与“角色卡与世界书”页（`writing_profile.dart`）各有两个输入框。
- 生成（`WritingContext.load` → 各调用点）、显示宏（`display_store.dart`）、酒馆助手接口（`branch_chat.dart` 的 `name1`）都从这两个字段取值。
- 分叉分支整份复制 `writing/` 设置（`variable_store.dart:197`）；项目导出原样带上 `writing/<分支>`（`project_store.dart:45`）。
- 图片文件按内容哈希存放，`AssetLibrary.prepare` 只落盘不建记录；启动时按 `assetFileNames()` 清理一天以上无人引用的文件。
- 模型请求的 `messages` 原样透传，OpenAI 兼容协议可以带图片内容；本地 CLI 连接把消息压平成文本。

## 数据

全局设置 `personas` = `{items: [Persona…]}`，与 `connections` 同样的存法。

```
Persona {
  id: String,            // 内置“我”固定为 'me'；新建时由仓库分配
  name: String,          // {{user}}
  description: String,   // 人设描述
  appearance: String,    // 外貌：脸、发型、体型等固定特征
  outfit: String,        // 默认服饰
  images: [{hash, thumbnailHash, width, height}],  // 最多 8 张
}
```

- “我”：名字“我”，其余为空。设置里没有它时读取也会补上；不能删除，字段都可改。
- 图片经 `AssetLibrary.prepare` 标准化后按哈希落盘，人设只记哈希。`assetFileNames()` 把所有人设的图片也算作引用。

## 行为

**绑定**：`writing/<分支>.personaId` 是 `{{user}}` / `{{persona}}` 的唯一来源。旧字段 `userName` / `persona` 与缺省值“主角”一并去掉。解析函数（核心包，唯一入口）：有 `personaId` 且找得到 → 该人设；否则 → “我”。

新建小说写入所选人设（默认 `'me'`）。分叉分支随设置复制继承绑定。各处 `userName = '主角'` 的参数缺省改为“我”。

**旧数据迁移**（一个核心函数，启动时与导入项目时都调用，可重复执行）：对仍带旧字段的 `writing/<分支>`：

- `userName` 为空或“主角”，且 `persona` 为空 → 绑定“我”。之后的生成里 `{{user}}` 由“主角”变为“我”。
- 否则 → 新建人设 `{name: userName, description: persona}` 并绑定；名字与描述完全相同的旧设定共用一个人设。
- 写入 `personaId` 后删除两个旧字段。

**宏取值**：

- `{{user}}` = `name`（空时用“我”）。
- `{{persona}}` = `description`，后接 `\n外貌：<appearance>`、`\n服饰：<outfit>`；空的部分及其前缀都省略，结果去掉首尾空白。
- 修改人设对之后的生成与显示立即生效（与 ST 相同）；已建的生成任务保留冻结快照。

**删除**：仍被任一分支的 `personaId` 引用时拒绝，提示“被 N 部作品使用”。

**项目导出**：绑定内置“我”的 `writing/<分支>` 原样保留 `personaId: 'me'`：各设备各用自己的“我”，修改“我”不改变任何作品的指纹。绑定其他人设的，`personaId` 换成 `personaSnapshot: {name, description, appearance, outfit}`；图片都不导出。导入时按快照找四个字段完全相同的人设（含“我”）绑定，找不到就新建；导入文件中除 `'me'` 外的 `personaId` 视为无效；不带快照的旧导出文件走上面的旧数据迁移。实现时要确认同步（`project_sync.dart`）的比较不会因此把本地与导出快照判为不一致。

## 界面

- **创作资源库**列表顶部加“人设”条目，进入人设列表页：列出全部人设（“我”在首位）与“新建人设”，点进入编辑页。
- **编辑页**（`lib/features/personas/`）：名字、人设描述、外貌、默认服饰、参考图条（从文件添加、删除、生成）；底部实时预览拼出的 `{{persona}}`。保存前可离开放弃；有绑定时删除按钮给出提示。
- **选择器**：替换“从角色卡新建小说”页与“角色卡与世界书”页里的两个输入框（“{{user}} 对应的主角名字”“主角身份 / Persona”），默认“我”，旁边“管理人设”链接。

## AI 辅助

三个按钮，结果只填入表单；填入前保存旧值，提供一步“撤销”。都在页面内直接调用，不建持久化任务（人设不属于分支），离开页面即取消。

| 按钮 | 模型角色 | 输入 → 输出 |
|---|---|---|
| 看图反推 | 资料整理（`analysis`） | 前 4 张参考图 + 当前字段 → `{appearance, outfit, description?}`；`description` 仅在原值为空时填入。 |
| AI 补全润色 | 资料整理 | 当前字段（可只有一句）→ `{name, description, appearance, outfit}`；名字原值非空时保留。 |
| 生成参考图 | 资料整理 → 插画生成（`image`） | 外貌 + 服饰 → 提示词（NovelAI / ComfyUI 用英文标签，OpenAI 图像用英文句子），弹窗供修改；再以该连接保存的默认参数（`IllustrationService.savedDefaults` / `requestFrom`）出图，经 `prepare` 加入参考图。ComfyUI 工作流沿用 `IllustrationService.generate` 中读取最新节点的做法。 |

- 文字类调用要求返回 JSON 对象，先去掉代码围栏再解析（同 `task_runner.dart` 的 `_structuredResult`）；缺字段或解析失败报错，表单不变。
- 看图：OpenAI 兼容与远程执行器以 `content: [{type: text}, {type: image_url, image_url: {url: 'data:image/jpeg;base64,…'}}]` 发送。发送的是 480px JPEG 缩略图。本地 CLI 连接直接报“当前资料整理模型不支持看图”。
- 未配置相应角色的模型时，按钮可点但报“请先配置资料整理模型 / 插画模型”，与现有页面一致。

## 代码位置

- `packages/sillydraft_core/lib/src/model/persona.dart`：`Persona`、`{{persona}}` 拼接、解析函数。
- `packages/sillydraft_core/lib/src/storage/persona_store.dart`：`StoryRepository` 的 part 扩展，增删改查、引用检查、旧数据迁移。
- `packages/sillydraft_core/lib/src/agent/persona_service.dart`：三个 AI 调用与提示词，依赖注入 `ProviderFactory` / 图片执行器工厂。
- `lib/features/personas/`：列表区块、编辑页、选择器。
- 修改：`writing_profile.dart`、`card_start_screen.dart`、`card_start_store.dart`、`display_store.dart`、`asset_store.dart`（`assetFileNames`）、`project_store.dart`（导出、导入校验与迁移）、`lib/app/services.dart`（注入服务、启动迁移），以及所有 `userName = '主角'` 缺省值。

## 测试

全部使用本地协议服务器，不调用付费模型。

- 核心：解析（绑定 → “我”）；旧数据迁移三种情形与重复执行无变化；`{{persona}}` 拼接与空字段省略；“我”的补齐与禁删；被引用时禁删；导出快照与导入时复用 / 新建；`assetFileNames` 含人设图片；三个 AI 调用的请求形状（含 `image_url`）、JSON 解析与错误；本地 CLI 看图报错。
- 界面：编辑页 AI 填入与撤销；选择器读写 `personaId`。

## 文档

- `docs/st-preset-compatibility.md`：`{{user}}`、`{{persona}}` 的取值来源；人设描述插入位置不支持，只经 `personaDescription` 标记进入提示词。
- `docs/user-guide.md`：新增“人设”一节。
