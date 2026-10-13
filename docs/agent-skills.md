# 助手技能（Agent Skills）

编辑助手支持开放的 [Agent Skills](https://agentskills.io/specification) 格式（`SKILL.md`）。这是 Claude、Codex、Cursor、Gemini CLI 等工具共同采用的技能格式，社区分享的技能可以直接导入。

## 格式

一个技能是一个目录，至少包含 `SKILL.md`：YAML 头信息加 Markdown 说明。

```markdown
---
name: villain-voice            # 必填：小写字母、数字、连字符，最多 64 字符
description: 让反派说话更有压迫感。写反派对白时使用。   # 必填：做什么、什么时候用
metadata:
  display-name: 反派声音        # 可选：界面显示名
disable-model-invocation: true # 可选：只允许手动 /villain-voice 启用
---

# 反派声音
1. ……
```

可附带 `references/` 等文本文件（md、txt、json、yaml、csv 等），说明里用相对路径引用。`scripts/` 中的脚本和二进制文件会被列出，但**不会读取或执行**。解析按规范的客户端指南从宽：名称不规范、值里含冒号等问题会被修正并提示；缺少 description 或头信息无法解析时拒绝导入。

## 加载方式（渐进披露）

1. **目录**：每次对话，系统提示只包含已启用技能的名称和简介。
2. **说明**：助手判断任务相符时调用 `activate_skill`（名称限定为已启用技能），拿到 `<skill_content>` 包裹的正文和附带文件列表。
3. **资源**：说明提到附带文件时，助手用 `read_skill_file` 读取。

作者也可以在消息开头输入 `/技能名` 直接启用，输入 `/` 会提示可用技能。

已加载的技能在本会话后续每一轮都会保留，且只发送一次；助手重复加载会被告知“已加载”。技能只改变做事方法，不扩大工具权限，也不能改变编辑规则（只能提出候选，不能自行采纳）。

## 管理

设置 →「助手技能」，或助手顶部的「技能」标签：

- 开关技能；关闭的技能不会出现在助手的目录里。
- 导入 `SKILL.md`，或包含一个或多个技能目录的 `.zip` / `.skill` 包。同名技能会替换旧的（包括替换内置技能；删除后内置版本恢复）。
- 新建或编辑技能、导出为 `SKILL.md`。

技能保存在本机应用设置中，所有作品共用，不进入作品备份。

## 内置技能

| 名称 | 用途 |
| --- | --- |
| `character-consistency` 人物一致性检查 | 性格、动机、语气、已知事实前后是否一致 |
| `foreshadowing-audit` 伏笔与暗线梳理 | 已回收、未回收、疑似遗忘的线索 |
| `chapter-pacing` 章节节奏诊断 | 信息密度、张力曲线、拖沓与仓促 |
| `dialogue-polish` 对白打磨 | 人物声音、说明性台词、潜台词（附检查清单） |
| `continuity-check` 设定与时间线连续性检查 | 时间、地点、物品、谁知道什么 |
| `next-chapter-plan` 下一章规划 | 当前局面、三种方向、章节节拍 |

内置技能只使用助手已有的工具：`list_chapters`、`read_chapter`、`propose_chapter`、`list_lore`、`read_lore`、`propose_lore`。

## 注意

技能内容会随对话发给模型，只导入你信任来源的技能。本地订阅连接（Claude Code / Codex）同样支持技能：工具调用通过提示词模拟。
