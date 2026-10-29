import 'skills.dart';

/// Skills shipped with the app, written as ordinary SKILL.md files so they can
/// be exported, read as examples, or overridden by an installed skill with the
/// same name. They only use the assistant's own tools.
List<AgentSkill> builtInSkills() => [
  for (final (source, files) in _sources)
    parseSkill(source, files: files, builtIn: true),
];

const _sources = <(String, Map<String, String>)>[
  (
    '''
---
name: character-consistency
description: 检查人物的性格、动机、说话方式和已知事实在各章节之间是否前后一致，找出“人设崩了”的地方。用户提到人物不对劲、OOC、动机说不通、前后矛盾或想做人物体检时使用。
metadata:
  display-name: 人物一致性检查
  author: SillyDraft
---

# 人物一致性检查

## 步骤
1. 用 list_lore 找到相关人物条目，用 read_lore 读取设定；没有指定人物时，先问作者要检查谁，或挑出章节中出场最多的两三位。
2. 用 list_chapters 列出可见章节，按顺序用 read_chapter 读取该人物出场的章节。
3. 对每位人物逐项比对：
   - **动机**：行为是否有可追溯的理由，转变是否有铺垫；
   - **性格与语气**：用词、句长、口头禅、对不同对象的态度；
   - **已知事实**：年龄、伤疤、关系、知道或不知道的信息（不能知道尚未得知的秘密）；
   - **能力边界**：前文设定的能力或限制是否被无故打破。
4. 区分三类结论：确定的矛盾（引用两处原文）、可能的问题（说明依据）、看似矛盾但可以解释的地方。

## 输出
- 按人物分组，每条给出章节标题和简短引文；
- 先列最影响阅读的问题，每位人物最多五条；
- 需要补的设定用 propose_lore 提出（certainty 用 inference），需要改的正文先说明改法，作者同意后再用 propose_chapter 修改，不要直接下结论替作者改人设。
''',
    <String, String>{},
  ),
  (
    '''
---
name: foreshadowing-audit
description: 梳理已经埋下的伏笔、暗线和悬念，标出哪些已回收、哪些悬而未决、哪些可能被遗忘，并建议回收时机。用户提到伏笔、暗线、坑、悬念、线索或问“还有哪些没填”时使用。
metadata:
  display-name: 伏笔与暗线梳理
  author: SillyDraft
---

# 伏笔与暗线梳理

## 步骤
1. 用 list_lore 查看已有的 foreshadow、event 类资料，读取相关条目。
2. 用 list_chapters / read_chapter 通读可见正文，记下：反常细节、未解释的物件或人物、被打断的对话、刻意模糊的信息。
3. 为每条线索建立记录：首次出现的章节、之后的呼应、当前状态（已回收 / 部分回收 / 未回收 / 疑似遗忘：超过若干章节没有呼应）。
4. 对未回收的线索，给出一到两个回收方向，并说明适合放在哪类章节。

## 输出
- 表格或列表：线索、出处、状态、建议；
- 正文里新发现、资料中还没有的伏笔，用 propose_lore 提出（kind 为 foreshadow，sourceChapterId 填首次出现的章节）；
- 不要编造正文中不存在的线索；推测要标明是推测。
''',
    <String, String>{},
  ),
  (
    '''
---
name: chapter-pacing
description: 诊断一章的节奏：信息密度、张力曲线、拖沓或仓促的段落、章节目标是否达成。用户说节奏慢、拖、太赶、没劲、读不下去，或想优化某一章时使用。
metadata:
  display-name: 章节节奏诊断
  author: SillyDraft
---

# 章节节奏诊断

## 步骤
1. 确认要诊断的章节；未指定时用 list_chapters 取最近的章节。用 read_chapter 读取全文。
2. 先概括章节目标：谁想要什么，阻碍是什么，结尾局面是否改变。没有变化的章节要明确指出。
3. 按段落标出功能：推进、铺垫、描写、对话、内心、回忆。统计各功能的比重，找出连续三段以上同一功能的区域。
4. 画出张力曲线（用文字描述高低点），指出：
   - 拖沓：重复信息、过长的环境描写、没有冲突的对话；
   - 仓促：关键转折缺少反应或代价、情绪没有落地。

## 输出
- 章节目标与结论一句话；
- 最多五处具体问题，每处引用开头几个字定位，并给出删、并、补、换位中的具体做法；
- 作者同意后，用 propose_chapter 改写这几处（instructions 写清要改哪几处），不要整章重写。
''',
    <String, String>{},
  ),
  (
    '''
---
name: dialogue-polish
description: 打磨对白：让人物声音各不相同，去掉说明性台词和多余的对话标签，加强潜台词。用户提到对话生硬、像念稿、人物说话都一样、台词太直白时使用。
metadata:
  display-name: 对白打磨
  author: SillyDraft
---

# 对白打磨

## 步骤
1. 用 read_chapter 读取目标章节，用 list_lore / read_lore 了解说话人物的身份与性格。
2. 逐段检查对白，问题清单见 references/dialogue-checklist.md（需要时用 read_skill_file 读取）。
3. 每处修改都说明理由：哪一条问题、改后体现了人物的哪一点。
4. 保留作者的原意和情节信息，只改说法；不要加入新的情节事实。

## 输出
- 先给三到五处“原句 → 改写”的示例和理由，请作者确认方向；
- 作者确认后用 propose_chapter 调整整章对白。
''',
    {
      'references/dialogue-checklist.md': '''
# 对白检查清单

1. **说明性台词**：人物把双方都知道的信息说给读者听（“你也知道，我们是十年的老朋友”）。改为动作、反应或省略。
2. **声音同质**：遮住名字分不出是谁在说。从词汇、句长、语气词、回避方式区分人物。
3. **标签过多**：每句都有“他说道”“她冷冷地说”。能从上下文判断时删除标签，副词多换成动作。
4. **一问一答**：对话像采访。加入打断、答非所问、沉默和回避。
5. **潜台词缺失**：人物直接说出全部真实想法。让真实意图藏在话里或话外。
6. **节奏单一**：句子长度一致。紧张时缩短，试探时拉长，用停顿制造重音。
7. **方言与时代感**：用词是否符合人物身份与故事年代，避免现代网络用语误入。
''',
    },
  ),
  (
    '''
---
name: continuity-check
description: 检查设定和时间线的连续性：时间、地点、物品、伤势、天气、谁在场、谁知道什么，找出穿帮和前后不一致。用户提到穿帮、时间线乱、设定冲突、BUG、逻辑漏洞时使用。
metadata:
  display-name: 设定与时间线连续性检查
  author: SillyDraft
---

# 设定与时间线连续性检查

## 步骤
1. 用 list_lore 和 read_lore 读取世界设定、地点、物品与事件资料；注意 sourceStale 为 true 的条目依据已变化，不能当作当前事实。
2. 用 list_chapters / read_chapter 按顺序通读，建立简表：每个章节的时间、地点、在场人物、关键物品状态、人物已知信息。
3. 前后比对，找出：时间倒流或间隔不合理、人物同时出现在两地、物品凭空出现或消失、伤势与体力不连续、人物提前知道了还未得知的信息、与设定资料冲突的描写。
4. 每条问题标注严重程度：会让读者出戏 / 细心读者会发现 / 可忽略。

## 输出
- 按严重程度排序的问题列表，引用两处原文对照；
- 资料缺失的设定用 propose_lore 补充，确需修改正文的，作者同意后用 propose_chapter 修改。
''',
    <String, String>{},
  ),
  (
    '''
---
name: next-chapter-plan
description: 根据已写内容和资料规划接下来的一章：梳理当前局面，给出几种发展方向、情节安排和要回收或埋下的线索。用户问接下来怎么写、卡文了、没有思路、想要大纲或下一章规划时使用。
metadata:
  display-name: 下一章规划
  author: SillyDraft
---

# 下一章规划

## 步骤
1. 用 list_chapters 找到最近的几个章节并读取，用 list_lore 了解人物目标、未回收的伏笔和计划（certainty 为 plan 的资料尚未发生）。
2. 总结当前局面：主角想要什么、最大的阻碍、悬而未决的问题、读者此刻最期待什么。
3. 给出三个方向不同的下一章方案（例如推进主线 / 深挖人物 / 制造意外），每个方案包含：一句话梗概、三到五个情节节拍、本章要回收和新埋的线索、风险。
4. 指出推荐方案与理由，但由作者决定。

## 输出
- 当前局面摘要和三个方案；
- 作者选定后，先用 create_chapter 新建章节，再用 propose_chapter 指定返回的章节 ID 写入正文（instructions 写入所选节拍；多章须逐章等待写入成功再继续），或用 propose_lore 记录计划（certainty 为 plan）。
''',
    <String, String>{},
  ),
];
