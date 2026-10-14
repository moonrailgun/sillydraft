# 章节编号与章节名分开管理 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 章节编号按目录顺序自动生成，`branch_chapters.title` 只存章节名，显示时拼成“第六章 名字”。

**Architecture:** 核心包新增 `chapter_title.dart` 负责解析、拼接和“保持显示不变”的编号规则；存储层在 `_chapterQuery` 里用窗口函数算编号，`Chapter.title` 变成拼好的显示标题，读取方不改。数据库 v9 与项目备份 schema 9 共用一个迁移函数。

**Tech Stack:** Dart 3.13.5 / Flutter 3.47.7，drift（SQLite 自定义 SQL），forui，Riverpod。

**Spec:** `docs/superpowers/specs/2026-10-14-chapter-numbering-design.md`

## Global Constraints

- 基线 Flutter 3.47.7 / Dart 3.13.5；代码与注释用英文，界面与文档用中文。
- 不提交（工作区与其他会话共享，提交会被重置）；每个任务以测试与 `dart analyze` / `flutter analyze` 通过结束。
- 格式检查：`dart format --output=none --set-exit-if-changed lib test integration_test test_driver tool packages/sillydraft_core/lib packages/sillydraft_core/test server/lib server/bin server/test`（仓库根目录）。
- 测试使用本地协议服务器或脚本化模型，不调用付费模型。
- 迁移与导入不改变任何已有章节的显示标题。

## Review Focus

1. 从 v7 或更早直接升级到 v9：v8 步骤已按当前 `schema` 重建表，v9 步骤不能再 `ALTER TABLE`（Task 3 有对应测试）。
2. 分叉分支复制章节时写入 `name` 而不是显示标题，否则会显示“第六章 第六章 名字”（Task 2 有对应测试）。
3. 全角数字与空格：“第１２章 夜雨”“第 3 章”能解析（Task 1 有对应测试）。
4. AI 起名期间作者改了名字：不覆盖（Task 4 有对应测试）。
5. 旧备份（schema 8）导入后显示不变；schema 9 备份往返一致（Task 3 有对应测试）。

---

### Task 1: 标题解析、拼接与编号规则（核心包）

**Files:**
- Create: `packages/sillydraft_core/lib/src/model/chapter_title.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`（导出）
- Test: `packages/sillydraft_core/test/chapter_title_test.dart`

**Interfaces:**
- Produces:
  - `enum ChapterNumerals { chinese, arabic }`
  - `String chineseNumber(int n)`
  - `String chapterTitle(int? number, String name, ChapterNumerals numerals)`
  - `({int? number, String name, ChapterNumerals? numerals}) splitChapterTitle(String title)`
  - `List<({bool numbered, String name})> numberChapterTitles(List<String> titles)`
  - `ChapterNumerals inferNumerals(Iterable<String> titles)`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('chinese numbers read the way chapter numbers are written', () {
    expect([for (final n in [1, 10, 12, 20, 104, 110, 1001]) chineseNumber(n)],
        ['一', '十', '十二', '二十', '一百零四', '一百一十', '一千零一']);
  });

  test('a heading splits into its number, numerals and name', () {
    expect(splitChapterTitle('第六章 反客为主的午休天台'),
        (number: 6, name: '反客为主的午休天台', numerals: ChapterNumerals.chinese));
    expect(splitChapterTitle('第12章：夜雨'),
        (number: 12, name: '夜雨', numerals: ChapterNumerals.arabic));
    expect(splitChapterTitle(' 第 3 章 · 归途 '),
        (number: 3, name: '归途', numerals: ChapterNumerals.arabic));
    expect(splitChapterTitle('第１２章 雨'),
        (number: 12, name: '雨', numerals: ChapterNumerals.arabic));
    expect(splitChapterTitle('第一百零四章'),
        (number: 104, name: '', numerals: ChapterNumerals.chinese));
    expect(splitChapterTitle('序章'), (number: null, name: '序章', numerals: null));
    expect(splitChapterTitle('卷一 · 第三章 归途'),
        (number: null, name: '卷一 · 第三章 归途', numerals: null));
  });

  test('display titles join the number and the name', () {
    expect(chapterTitle(6, '归途', ChapterNumerals.chinese), '第六章 归途');
    expect(chapterTitle(6, '归途', ChapterNumerals.arabic), '第6章 归途');
    expect(chapterTitle(1, '', ChapterNumerals.chinese), '第一章');
    expect(chapterTitle(null, '序章', ChapterNumerals.chinese), '序章');
    expect(chapterTitle(null, '', ChapterNumerals.chinese), '');
  });

  test('existing titles are numbered only where the display stays the same', () {
    List<(bool, String)> number(List<String> titles) => [
      for (final t in numberChapterTitles(titles)) (t.numbered, t.name),
    ];
    expect(number(['第一章', '第二章 灯塔']), [(true, ''), (true, '灯塔')]);
    expect(number(['序章', '第一章 码头']), [(false, '序章'), (true, '码头')]);
    expect(number(['第一卷 起雾 · 第一章 码头', '第二章 灯塔']),
        [(false, '第一卷 起雾 · 第一章 码头'), (false, '第二章 灯塔')]);
    // From a gap on, titles stay as written.
    expect(number(['第一章 a', '第三章 b', '第四章 c']),
        [(true, 'a'), (false, '第三章 b'), (false, '第四章 c')]);
    // An untitled chapter takes the next number.
    expect(number(['', '第二章 b']), [(true, ''), (true, 'b')]);
  });

  test('a book keeps the numerals most of its numbered titles use', () {
    expect(inferNumerals(['第1章', '第2章', '第三章']), ChapterNumerals.arabic);
    expect(inferNumerals(['第一章', '第2章', '第三章']), ChapterNumerals.chinese);
    expect(inferNumerals(['序章']), ChapterNumerals.chinese);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run（在 `packages/sillydraft_core`）: `dart test test/chapter_title_test.dart`
Expected: FAIL，`chineseNumber` 等未定义。

- [ ] **Step 3: Write minimal implementation**

`chineseNumber` 与中文数字解析从 `lib/features/reader/next_chapter.dart` 移来（Task 4 删除原处）。

```dart
/// How a novel writes its chapter numbers: 第六章 or 第6章.
enum ChapterNumerals { chinese, arabic }

const _digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const _values = {
  '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
};
const _units = {'十': 10, '百': 100, '千': 1000, '万': 10000};

/// [n] in Chinese numerals as chapter numbers are written: 十二, 一百零四.
String chineseNumber(int n) {
  if (n <= 0 || n >= 10000) return '$n';
  final out = StringBuffer();
  var zero = false;
  for (final (unit, name) in [(1000, '千'), (100, '百'), (10, '十'), (1, '')]) {
    final d = n ~/ unit % 10;
    if (d == 0) {
      zero = out.isNotEmpty;
      continue;
    }
    if (zero) out.write('零');
    zero = false;
    // 十二, not 一十二, when the tens lead.
    if (!(unit == 10 && d == 1 && out.isEmpty)) out.write(_digits[d]);
    out.write(name);
  }
  return '$out';
}

/// What a chapter is called: 第六章 归途, 第六章 when it has no name, or
/// only its name outside the numbering.
String chapterTitle(int? number, String name, ChapterNumerals numerals) {
  if (number == null) return name;
  final n = numerals == ChapterNumerals.arabic
      ? '$number'
      : chineseNumber(number);
  return name.isEmpty ? '第$n章' : '第$n章 $name';
}

final _heading = RegExp(
  r'^第\s*([0-9０-９]+|[零〇一二两三四五六七八九十百千万]+)\s*章',
);
final _separator = RegExp(r'^[\s:：·・\-—–、.．]+');

/// A whole heading taken apart: 第十二章：夜雨 is 12 named 夜雨. A heading
/// that does not open with 第N章 (序章, 卷一 · 第三章 归途) has no number
/// and is its own name.
({int? number, String name, ChapterNumerals? numerals}) splitChapterTitle(
  String title,
) {
  final text = title.trim();
  final match = _heading.firstMatch(text);
  if (match == null) return (number: null, name: text, numerals: null);
  final digits = match[1]!;
  final name = text.substring(match.end).replaceFirst(_separator, '').trim();
  final arabic = int.tryParse(
    String.fromCharCodes([
      // Full-width digits read as ASCII ones.
      for (final c in digits.runes) c >= 0xff10 && c <= 0xff19 ? c - 0xfee0 : c,
    ]),
  );
  if (arabic != null) {
    return (number: arabic, name: name, numerals: ChapterNumerals.arabic);
  }
  var total = 0, digit = 0;
  for (final c in digits.split('')) {
    if (_values[c] case final v?) {
      digit = v;
    } else {
      total += (digit == 0 ? 1 : digit) * _units[c]!;
      digit = 0;
    }
  }
  return (
    number: total + digit,
    name: name,
    numerals: ChapterNumerals.chinese,
  );
}
```

`numberChapterTitles` 与 `inferNumerals`：

```dart
/// Existing [titles], in order, as numbering and names that show exactly as
/// before: a title joins the numbering only where its 第N章 is the number
/// the order gives it, any other stays outside it as written. An untitled
/// chapter takes the next number, as 第N章 did for it before.
List<({bool numbered, String name})> numberChapterTitles(List<String> titles) {
  final result = <({bool numbered, String name})>[];
  var count = 0;
  for (final title in titles) {
    final split = splitChapterTitle(title);
    if (title.trim().isEmpty || split.number == count + 1) {
      count++;
      result.add((numbered: true, name: split.name));
    } else {
      result.add((numbered: false, name: title.trim()));
    }
  }
  return result;
}

/// The numerals most numbered [titles] use; Chinese when there are none.
ChapterNumerals inferNumerals(Iterable<String> titles) {
  var arabic = 0, chinese = 0;
  for (final title in titles) {
    switch (splitChapterTitle(title).numerals) {
      case ChapterNumerals.arabic:
        arabic++;
      case ChapterNumerals.chinese:
        chinese++;
      case null:
        break;
    }
  }
  return arabic > chinese ? ChapterNumerals.arabic : ChapterNumerals.chinese;
}
```

在 `packages/sillydraft_core/lib/sillydraft_core.dart` 的 model 导出旁加：

```dart
export 'src/model/chapter_title.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/chapter_title_test.dart` → PASS；`dart analyze` → No issues。

---

### Task 2: 存储与模型

**Files:**
- Modify: `packages/sillydraft_core/lib/src/model/story.dart`（`Novel`、`Chapter`）
- Modify: `packages/sillydraft_core/lib/src/storage/database.dart`（`schema` 中 `novels`、`branch_chapters`）
- Modify: `packages/sillydraft_core/lib/src/storage/story_mappers.dart`
- Modify: `packages/sillydraft_core/lib/src/storage/story_repository.dart`（`createNovel`、`updateNovel`、`getStory`、`_chapterQuery`）
- Modify: `packages/sillydraft_core/lib/src/storage/manuscript_store.dart`（`getChapter`、`createChapter`、`renameChapter`，新增 `setChapterNumbered`）
- Modify: `packages/sillydraft_core/lib/src/storage/branch_store.dart:63-68`（分叉复制）
- Modify: `packages/sillydraft_core/lib/src/storage/manuscript_import_store.dart`
- Test: `packages/sillydraft_core/test/story_repository_test.dart`、`packages/sillydraft_core/test/manuscript_import_test.dart`

**Interfaces:**
- Consumes: Task 1 全部函数。
- Produces:
  - `Chapter.name`（`String`）、`Chapter.number`（`int?`）、`Chapter.numerals`（`ChapterNumerals`）、`Chapter.numbered`（`bool get`）、`Chapter.title`（`String get`，显示标题）
  - `Novel.chapterNumerals`（`ChapterNumerals`），`copyWith(chapterNumerals:)`
  - `createNovel(..., ChapterNumerals chapterNumerals = ChapterNumerals.chinese)`
  - `createChapter({required String branchId, String? title, String name = '', bool numbered = true, ManuscriptContent? content})`
  - `renameChapter({required String branchId, required String chapterId, required String name})`
  - `setChapterNumbered({required String branchId, required String chapterId, required bool numbered})`

- [ ] **Step 1: Write the failing tests**

追加到 `story_repository_test.dart`（该文件 `setUp` 建好 `repository`，每个用例自建作品）：

```dart
  test('chapters are numbered by their order', () async {
    final novel = await repository.createNovel(title: '雾港来信');
    final branch = novel.activeBranchId;
    final a = await repository.createChapter(branchId: branch, name: '码头');
    final prologue = await repository.createChapter(
      branchId: branch,
      title: '序章',
    );
    final b = await repository.createChapter(branchId: branch);
    Future<List<String>> shown() async => [
      for (final c in (await repository.getStory(branch)).chapters) c.title,
    ];
    expect(await shown(), ['第一章 码头', '序章', '第二章']);
    expect(
      (await repository.getChapter(branchId: branch, chapterId: b.id)).number,
      2,
    );
    await repository.reorderChapters(
      branchId: branch,
      chapterIds: [b.id, prologue.id, a.id],
    );
    expect(await shown(), ['第一章', '序章', '第二章 码头']);
    await repository.setChapterNumbered(
      branchId: branch,
      chapterId: prologue.id,
      numbered: true,
    );
    expect(await shown(), ['第一章', '第二章 序章', '第三章 码头']);
    await repository.renameChapter(branchId: branch, chapterId: a.id, name: '灯塔');
    await repository.deleteChapter(branchId: branch, chapterId: b.id);
    expect(await shown(), ['第一章 序章', '第二章 灯塔']);
    await repository.updateNovel(
      (await repository.getNovel(novel.id)).copyWith(
        chapterNumerals: ChapterNumerals.arabic,
      ),
    );
    expect(await shown(), ['第1章 序章', '第2章 灯塔']);
  });

  test('a chapter joining the numbering drops the number in its name', () async {
    final novel = await repository.createNovel(title: '雾港来信');
    final branch = novel.activeBranchId;
    // As migration leaves a title past a gap in the old numbering.
    final c = await repository.createChapter(branchId: branch, title: '序章');
    await repository.renameChapter(branchId: branch, chapterId: c.id, name: '第三章 归途');
    expect(
      (await repository.getChapter(branchId: branch, chapterId: c.id)).title,
      '第三章 归途',
    );
    await repository.setChapterNumbered(branchId: branch, chapterId: c.id, numbered: true);
    expect(
      (await repository.getChapter(branchId: branch, chapterId: c.id)).title,
      '第一章 归途',
    );
  });

  test('a forked branch keeps names and numbering', () async {
    final novel = await repository.createNovel(title: '雾港来信');
    final branch = novel.activeBranchId;
    await repository.createChapter(branchId: branch, name: '码头');
    final second = await repository.createChapter(branchId: branch, title: '番外');
    final fork = await repository.forkBranch(
      branchId: branch,
      name: '支线',
      atChapterId: second.id,
    );
    expect(
      [for (final c in (await repository.getStory(fork.id)).chapters) c.title],
      ['第一章 码头', '番外'],
    );
  });
```

追加到 `manuscript_import_test.dart`（沿用该文件建仓库的方式，参照它第 175–181 行的用例）：

```dart
  test('imported headings keep how they read', () async {
    final book = ManuscriptImporter.parse(
      _utf8('第1章 码头\n雾。\n第2章 灯塔\n光。\n番外\n夜。\n'),
      filename: '雾港.txt',
    );
    final created = await repository.createNovelFromManuscript(book);
    final story = await repository.getStory(created.activeBranchId);
    expect([for (final c in story.chapters) c.title], ['第1章 码头', '第2章 灯塔', '番外']);
    expect(created.chapterNumerals, ChapterNumerals.arabic);
    expect(story.chapters.map((c) => c.name), ['码头', '灯塔', '番外']);
  });
```

（`番外` 在 `_txtHeading` 的无编号标题之列。）

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/story_repository_test.dart test/manuscript_import_test.dart`
Expected: 编译失败（`name:`、`setChapterNumbered`、`chapterNumerals` 未定义）。

- [ ] **Step 3: Implement**

`story.dart`：`Novel` 加字段与 `copyWith` 参数：

```dart
    this.chapterNumerals = ChapterNumerals.chinese,
  ...
  /// How the novel writes its chapter numbers.
  final ChapterNumerals chapterNumerals;
  ...
    ChapterNumerals? chapterNumerals,
  ...
    chapterNumerals: chapterNumerals ?? this.chapterNumerals,
```

`Chapter` 改为：

```dart
final class Chapter {
  const Chapter({
    required this.id,
    required this.branchId,
    required this.name,
    required this.position,
    required this.revisionId,
    required this.content,
    this.number,
    this.numerals = ChapterNumerals.chinese,
  });

  final String id;
  final String branchId;

  /// The chapter's own name, without its number; may be empty.
  final String name;

  /// Its place in the numbering, from 1; null for a chapter outside it.
  final int? number;
  final ChapterNumerals numerals;
  final int position;
  final String revisionId;
  final ManuscriptContent content;

  bool get numbered => number != null;

  /// What the chapter is called on screen, in exports and in prompts.
  String get title => chapterTitle(number, name, numerals);
}
```

`story.dart` 顶部加 `import 'chapter_title.dart';`。

`database.dart` 的 `schema`：`novels` 的 `archived` 行后加

```sql
      chapter_numerals TEXT NOT NULL DEFAULT 'chinese'
        CHECK(chapter_numerals IN ('chinese', 'arabic')),
```

`branch_chapters` 的 `revision_id` 行后加

```sql
      numbered INTEGER NOT NULL DEFAULT 1 CHECK(numbered IN (0, 1)),
```

`story_mappers.dart`：

```dart
  chapterNumerals: ChapterNumerals.values.byName(r['chapter_numerals'] as String),
```

加进 `_novel`；`_chapter` 改为：

```dart
Chapter _chapter(Map<String, Object?> r) => Chapter(
  id: r['chapter_id'] as String,
  branchId: r['branch_id'] as String,
  name: r['title'] as String,
  number: r['number'] as int?,
  numerals: ChapterNumerals.values.byName(r['chapter_numerals'] as String),
  position: r['position'] as int,
  revisionId: r['revision_id'] as String,
  content: ManuscriptContent.decode(r['content_json'] as String),
);
```

`story_repository.dart`：

```dart
  /// One branch's chapters with their content and place in the numbering;
  /// filter on the outside so the count still covers the whole branch.
  static const _chapterQuery = '''SELECT s.*, r.content_json,
      n.chapter_numerals,
      CASE WHEN s.numbered = 1 THEN sum(s.numbered)
        OVER (ORDER BY s.position, s.chapter_id) END AS number
    FROM branch_chapters s
    JOIN revisions r ON r.id = s.revision_id
    JOIN branches b ON b.id = s.branch_id
    JOIN novels n ON n.id = b.novel_id
    WHERE s.branch_id = ?''';
```

`getStory` 的查询改为 `'$_chapterQuery ORDER BY s.position, s.chapter_id'`，参数仍为 `[branchId]`。`createNovel` 加参数 `ChapterNumerals chapterNumerals = ChapterNumerals.chinese`，INSERT 增加 `chapter_numerals` 列与值 `chapterNumerals.name`。`updateNovel` 的 UPDATE 增加 `chapter_numerals = ?`，值 `novel.chapterNumerals.name`。

`manuscript_store.dart`：

```dart
  Future<Chapter> getChapter({
    required String branchId,
    required String chapterId,
  }) async => _chapter(
    await _one(
      'SELECT * FROM (${StoryRepository._chapterQuery}) WHERE chapter_id = ?',
      [branchId, chapterId],
      '章节',
    ),
  );

  /// Adds a chapter at the end of [branchId], numbered and called [name].
  /// A whole heading in [title] is split instead: 第三章 归途 is numbered
  /// (the order gives the number) and named 归途; 序章 stays outside the
  /// numbering.
  Future<Chapter> createChapter({
    required String branchId,
    String? title,
    String name = '',
    bool numbered = true,
    ManuscriptContent? content,
  }) => _write(() async {
    final split = title == null ? null : splitChapterTitle(title);
    final chapterName = split?.name ?? name.trim();
    final isNumbered = split == null ? numbered : split.number != null;
    ...（原有 revision 与 position 逻辑不变）
    await _execute(
      '''INSERT INTO branch_chapters
      (branch_id, chapter_id, title, numbered, position, revision_id)
      VALUES (?, ?, ?, ?, ?, ?)''',
      [branchId, id, chapterName, isNumbered ? 1 : 0, next['position'], revisionId],
    );
```

删掉 `createChapter` 里的 `_validateTitle(title)`。

```dart
  /// Renames a chapter; its number, if it has one, stays.
  Future<void> renameChapter({
    required String branchId,
    required String chapterId,
    required String name,
  }) => _write(() async {
    await getChapter(branchId: branchId, chapterId: chapterId);
    await _execute(
      'UPDATE branch_chapters SET title = ? WHERE branch_id = ? AND chapter_id = ?',
      [name.trim(), branchId, chapterId],
    );
    await _touchNovel((await getBranch(branchId)).novelId);
  });

  /// Puts a chapter in or out of the numbering. Joining it, a name that
  /// still opens with 第N章 loses that part, so it never reads 第二章 第三章.
  Future<void> setChapterNumbered({
    required String branchId,
    required String chapterId,
    required bool numbered,
  }) => _write(() async {
    final chapter = await getChapter(branchId: branchId, chapterId: chapterId);
    final name = numbered && splitChapterTitle(chapter.name).number != null
        ? splitChapterTitle(chapter.name).name
        : chapter.name;
    await _execute(
      '''UPDATE branch_chapters SET numbered = ?, title = ?
      WHERE branch_id = ? AND chapter_id = ?''',
      [numbered ? 1 : 0, name, branchId, chapterId],
    );
    await _touchNovel((await getBranch(branchId)).novelId);
  });
```

`branch_store.dart:63-68`：

```dart
        '''INSERT INTO branch_chapters
        (branch_id, chapter_id, title, numbered, position, revision_id)
        VALUES (?, ?, ?, ?, ?, ?)''',
        [
          id,
          chapter.id,
          chapter.name,
          chapter.numbered ? 1 : 0,
          chapter.position,
          chapter.revisionId,
        ],
```

`manuscript_import_store.dart`：在 `createNovel` 前算出

```dart
    final titles = [for (final c in book.chapters) _importTitle(c.title)];
    final numbering = numberChapterTitles(titles);
    final novel = await createNovel(
      ...,
      chapterNumerals: inferNumerals([
        for (final (i, t) in titles.indexed)
          if (numbering[i].numbered) t,
      ]),
    );
```

循环里用 `numbering[position]`：INSERT 增加 `numbered` 列，`title` 写 `numbering[position].name`，`numbered` 写 `numbering[position].numbered ? 1 : 0`。空标题由 `numberChapterTitles` 计入编号、名字为空，显示仍是“第N章”。`_importTitle` 去掉 `fallback` 参数：

```dart
String _importTitle(String title) {
  final trimmed = title.trim();
  return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
}
```

- [ ] **Step 4: Run tests**

Run: `dart test` （核心包全部）→ 新用例 PASS。已有用例中：
- `task_runner_test.dart:347` 的 `title: '第四章'` 现为该分支第一章，显示“第一章”：把期望改为 `'第一章 桌底下的契约'`（两处）。
- 其他因“第N章”被按顺序重编号而失败的断言，按新规则改期望；不改实现。

`dart analyze` → No issues。

---

### Task 3: 数据库 v9 与项目备份 schema 9

**Files:**
- Create: `packages/sillydraft_core/lib/src/migration/chapter_numbering.dart`
- Modify: `packages/sillydraft_core/lib/src/storage/database.dart`（`schemaVersion`、`onUpgrade`）
- Modify: `packages/sillydraft_core/lib/src/transfer/project_snapshot.dart`（接受 9，旧版套用迁移，`copy` 写 9）
- Modify: `packages/sillydraft_core/lib/src/storage/project_store.dart:126`（导出写 9）
- Test: `packages/sillydraft_core/test/chapter_database_migration_test.dart`、`packages/sillydraft_core/test/project_backup_test.dart`

**Interfaces:**
- Consumes: `numberChapterTitles`、`inferNumerals`（Task 1）；新列（Task 2）。
- Produces: `Map<String, List<Map<String, dynamic>>> numberChapterRows(Map<String, List<Map<String, dynamic>>> tables)`

- [ ] **Step 1: Write the failing tests**

在 `chapter_database_migration_test.dart` 里，参照它构造旧库的方式（第 182 行附近写原始 SQL 建表并插入），加一个 v8 库用例：用 v8 的 `branch_chapters`（无 `numbered`）与 `novels`（无 `chapter_numerals`）建表，插入同一分支的标题 `'第1章 码头'`、`'第2章 灯塔'`、`'番外'`、`'第4章 夜'`，`PRAGMA user_version = 8` 后用 `StoryRepository` 打开：

```dart
      final story = await repository.getStory('branch');
      expect([for (final c in story.chapters) c.title],
          ['第1章 码头', '第2章 灯塔', '番外', '第4章 夜']);
      expect([for (final c in story.chapters) c.numbered], [true, true, false, false]);
      expect(story.novel.chapterNumerals, ChapterNumerals.arabic);
```

该文件已有的 v7 及更早用例（第 38 行 `['第一章', '空白章']`）保持通过，即覆盖“从 7 直接升到 9”。

备份用例：取一个现有 schema 9 导出结果，把 `schema` 改成 8、删去两列、把标题改回整串，导入后显示一致：

```dart
    final exported = (await repository.exportProject(novel.id)).toJson();
    final tables = exported['tables'] as Map<String, dynamic>;
    for (final row in tables['branch_chapters'] as List) {
      final numbered = row.remove('numbered') == 1;
      if (numbered) row['title'] = '第一章 ${row['title']}'.trim();
    }
    for (final row in tables['novels'] as List) {
      row.remove('chapter_numerals');
    }
    final old = ProjectSnapshot.fromJson({...exported, 'schema': 8});
    expect(old.toJson()['schema'], 9);
    expect(old.tables['branch_chapters']!.single['numbered'], 1);
```

（`exportProject` 定义在 `project_store.dart:28`，参数照该签名；用例里作品只建一章 `name: '码头'`。）

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/chapter_database_migration_test.dart test/project_backup_test.dart`
Expected: v8 用例因缺列或标题未拆分失败；备份用例因 `schema: 8` 校验列不符失败。

- [ ] **Step 3: Implement**

`chapter_numbering.dart`：

```dart
import '../model/chapter_title.dart';

/// Schema 9 rows from schema 8 ones: each branch's titles become numbering
/// and names that show as before (see [numberChapterTitles]), and each
/// novel keeps the numerals its numbered titles used.
Map<String, List<Map<String, dynamic>>> numberChapterRows(
  Map<String, List<Map<String, dynamic>>> tables,
) {
  final result = {
    for (final e in tables.entries)
      e.key: [for (final row in e.value) Map<String, dynamic>.from(row)],
  };
  final novelOf = {
    for (final b in result['branches']!) b['id']: b['novel_id'],
  };
  final byBranch = <Object?, List<Map<String, dynamic>>>{};
  for (final row in result['branch_chapters']!) {
    byBranch.putIfAbsent(row['branch_id'], () => []).add(row);
  }
  final numbered = <Object?, List<String>>{};
  for (final rows in byBranch.values) {
    rows.sort((a, b) {
      final p = (a['position'] as int).compareTo(b['position'] as int);
      return p != 0 ? p : (a['chapter_id'] as String).compareTo(b['chapter_id'] as String);
    });
    final titles = [for (final r in rows) r['title'] as String];
    for (final (i, n) in numberChapterTitles(titles).indexed) {
      rows[i]['title'] = n.name;
      rows[i]['numbered'] = n.numbered ? 1 : 0;
      if (n.numbered) {
        numbered.putIfAbsent(novelOf[rows[i]['branch_id']], () => []).add(titles[i]);
      }
    }
  }
  for (final novel in result['novels']!) {
    novel['chapter_numerals'] = inferNumerals(numbered[novel['id']] ?? const []).name;
  }
  return result;
}
```

`database.dart`：`schemaVersion => 9`；`onUpgrade` 末尾加 `if (from < 9) await _numberChapters(from);`：

```dart
  /// v9: titles keep only the name; numbers come from the order.
  Future<void> _numberChapters(int from) => transaction(() async {
    // The v8 step rebuilt the tables from the current schema already.
    if (from == 8) {
      await customStatement(
        "ALTER TABLE novels ADD COLUMN chapter_numerals TEXT NOT NULL "
        "DEFAULT 'chinese' CHECK(chapter_numerals IN ('chinese', 'arabic'))",
      );
      await customStatement(
        'ALTER TABLE branch_chapters ADD COLUMN numbered INTEGER NOT NULL '
        'DEFAULT 1 CHECK(numbered IN (0, 1))',
      );
    }
    final tables = {
      for (final name in ['novels', 'branches', 'branch_chapters'])
        name: (await customSelect('SELECT * FROM $name').get())
            .map((row) => Map<String, dynamic>.from(row.data))
            .toList(),
    };
    final migrated = numberChapterRows(tables);
    for (final row in migrated['branch_chapters']!) {
      await customStatement(
        'UPDATE branch_chapters SET title = ?, numbered = ? '
        'WHERE branch_id = ? AND chapter_id = ?',
        [row['title'], row['numbered'], row['branch_id'], row['chapter_id']],
      );
    }
    for (final row in migrated['novels']!) {
      await customStatement(
        'UPDATE novels SET chapter_numerals = ? WHERE id = ?',
        [row['chapter_numerals'], row['id']],
      );
    }
  });
```

（从 v7 及更早升级时，v8 步骤用当前 `schema` 重建表并插入旧数据，新列取默认值，随后本步骤只做拆分。）

`project_snapshot.dart`：校验改为 `![6, 8, 9].contains(json['schema'])`；在 schema 6 → 8 的转换之后加：

```dart
    if (json['schema'] == 8) {
      json = {
        ...json,
        'schema': 9,
        'tables': numberChapterRows({
          for (final name in projectTables)
            name: ((json['tables'] as Map)[name] as List)
                .cast<Map<String, dynamic>>(),
        }),
      };
    }
```

`copy()` 与 `project_store.dart:126` 的 `'schema': 8` 改为 `9`。

- [ ] **Step 4: Run tests**

Run: `dart test` → 全部 PASS；`dart analyze` → No issues。

---

### Task 4: 生成与新建入口

**Files:**
- Modify: `packages/sillydraft_core/lib/src/agent/writing_service.dart:396-455`（`nameChapter`）
- Modify: `packages/sillydraft_core/lib/src/storage/card_start_store.dart:84-88`
- Modify: `lib/features/reader/next_chapter.dart`（删除 `chineseNumber`、`_chapterNumber`、`nextChapterTitle` 及其常量；`_continue` 改用名字）
- Modify: `lib/features/bookshelf/novel_dialog.dart:68`
- Test: `packages/sillydraft_core/test/task_runner_test.dart:347-380`、`test/story_directions_test.dart:415-432`

**Interfaces:**
- Consumes: `createChapter(name:)`、`renameChapter(name:)`、`Chapter.numbered/name/number/numerals`、`chapterTitle`、`chineseNumber`（核心包）。

- [ ] **Step 1: Update the tests first**

`task_runner_test.dart` 的起名用例：把 `title: '第四章'` 改为不传标题（`createChapter(branchId: branchId, content: …)`），期望改为 `'第一章 桌底下的契约'`（两处）。在“A chapter with a name keeps it”之后加一段“期间被改名不覆盖”：

```dart
    final other = await repository.createChapter(
      branchId: branchId,
      content: ManuscriptContent.plainText('雨停了。'),
    );
    script = (_, _) async* {
      await repository.renameChapter(
        branchId: branchId,
        chapterId: other.id,
        name: '作者起的名',
      );
      yield const TextDelta('雨后');
      yield const GenerationFinished('stop');
    };
    expect(
      await service.nameChapter(
        branchId: branchId,
        chapterId: other.id,
        connection: connection,
      ),
      isNull,
    );
    expect(
      (await repository.getChapter(branchId: branchId, chapterId: other.id)).name,
      '作者起的名',
    );
```

`story_directions_test.dart:415-432` 的 `nextChapterTitle` / `chineseNumber` 用例整段删除（已由 Task 1 的 `chapter_title_test.dart` 覆盖），同时删掉该文件里对 `nextChapterTitle`、`chineseNumber` 的 import（若有单独 `show`）。

- [ ] **Step 2: Run tests to verify they fail**

Run（核心包）: `dart test test/task_runner_test.dart`
Expected: 起名用例失败（`nameChapter` 仍按“只有编号”的正则判断）。

- [ ] **Step 3: Implement**

`writing_service.dart`：

```dart
  /// Names a numbered chapter that has no name yet, after its text:
  /// 第四章 becomes 第四章 桌底下的契约. Returns the new title, or null when
  /// the chapter has a name or no number, has no text yet, was named
  /// meanwhile, or the reply holds no usable name.
  Future<String?> nameChapter({
    required String branchId,
    required String chapterId,
    required ModelConnection connection,
  }) async {
    final chapter = await repository.getChapter(
      branchId: branchId,
      chapterId: chapterId,
    );
    final text = chapter.content.text.trim();
    if (text.isEmpty || !chapter.numbered || chapter.name.isNotEmpty) {
      return null;
    }
    ...（请求与流式读取不变）
    final name = _chapterName(reply.toString());
    if (name == null) return null;
    final current = await repository.getChapter(
      branchId: branchId,
      chapterId: chapterId,
    );
    if (current.name.isNotEmpty || !current.numbered) return null;
    await repository.renameChapter(
      branchId: branchId,
      chapterId: chapterId,
      name: name,
    );
    return chapterTitle(current.number, name, current.numerals);
  }
```

删除原 `numberOnly` 正则。

`card_start_store.dart`：`createChapter(branchId: novel.activeBranchId, content: …)`（去掉 `title: '第一章'`）。

`novel_dialog.dart:68`：`await repo.createChapter(branchId: result.activeBranchId);`

`next_chapter.dart`：删除 `_digits`、`_values`、`_units`、`chineseNumber`、`_chapterNumber`、`nextChapterTitle`；续写部分改为：

```dart
  final last = story.chapters.lastOrNull;
  final Chapter chapter;
  if (last != null && last.content.text.trim().isEmpty) {
    await repo.renameChapter(
      branchId: story.branch.id,
      chapterId: last.id,
      name: name,
    );
    chapter = await repo.getChapter(
      branchId: story.branch.id,
      chapterId: last.id,
    );
  } else {
    chapter = await repo.createChapter(branchId: story.branch.id, name: name);
  }
```

用 `grep -rn "chineseNumber\|nextChapterTitle" lib test` 确认再无引用（`lib` 里若有别处用 `chineseNumber`，改为从 `sillydraft_core` 导入）。

- [ ] **Step 4: Run tests**

Run: 核心包 `dart test`；根目录 `flutter test test/story_directions_test.dart` → PASS。`dart analyze`、`flutter analyze` → No issues。

---

### Task 5: 界面：新增、改名、计入编号、数字写法

**Files:**
- Modify: `lib/app/widgets.dart:671-731`（`askText` 加 `allowEmpty`）
- Modify: `lib/features/editor/workspace_screen.dart:154-170`（`_addChapter`）、`:445-458`（`_renameChapter`）、`:575-590`（章节菜单）
- Modify: `lib/features/bookshelf/novel_dialog.dart`（数字写法）
- Modify: `docs/user-guide.md`
- Test: `test/chapter_numbering_flow_test.dart`（新建）

**Interfaces:**
- Consumes: Task 2 的 `createChapter(name:)`、`renameChapter(name:)`、`setChapterNumbered`、`Novel.chapterNumerals`、`createNovel(chapterNumerals:)`。

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'support/finders.dart';

void main() {
  testWidgets('chapters number themselves and keep their own names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港来信');
    await repo.createChapter(branchId: novel.activeBranchId, title: '序章');
    await repo.createChapter(branchId: novel.activeBranchId, name: '码头');
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('雾港来信'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 码头'), findsWidgets);

    // A new chapter asks only for its name.
    await tester.tap(find.text('新增章节'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '灯塔');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // The editor opens on the new chapter; go back to the outline.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('第二章 灯塔'), findsWidgets);

    // The prologue joins the numbering; the rest move up one.
    await tester.tap(findAction('章节操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('计入编号'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 序章'), findsWidgets);
    expect(find.text('第三章 灯塔'), findsWidgets);

    // Renaming changes the name only.
    await tester.tap(findAction('章节操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名章节'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '熄灯');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('第三章 熄灯'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
```

（import 与 `test/workspace_sections_test.dart` 一致。“新增章节”按钮在目录底部，`workspace_screen.dart:621`。新增后 `_addChapter` 会 `_edit(chapter)` 推入编辑器页，所以要 `pageBack` 回到目录。）

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/chapter_numbering_flow_test.dart`
Expected: FAIL（新增对话框预填“第N章”、无“计入编号”菜单项）。

- [ ] **Step 3: Implement**

`widgets.dart`：`askText` 与 `_TextDialog` 增加 `bool allowEmpty = false`，`_submit` 改为：

```dart
  void _submit() {
    final text = controller.text.trim();
    if (text.isNotEmpty || widget.allowEmpty) Navigator.pop(context, text);
  }
```

`workspace_screen.dart`：

```dart
  Future<void> _addChapter(StorySnapshot story) async {
    final name = await askText(
      context,
      title: '新增章节',
      label: '章节名（可留空）',
      allowEmpty: true,
    );
    if (name == null || !mounted) return;
    try {
      final chapter = await ref
          .read(repositoryProvider)
          .createChapter(branchId: story.branch.id, name: name);
      ...（其余不变）
```

```dart
  Future<void> _renameChapter(StorySnapshot story, Chapter chapter) async {
    final name = await askText(
      context,
      title: '章节名称',
      initial: chapter.name,
      label: '章节名',
      allowEmpty: true,
    );
    if (name == null) return;
    try {
      await ref
          .read(repositoryProvider)
          .renameChapter(
            branchId: story.branch.id,
            chapterId: chapter.id,
            name: name,
          );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggleNumbered(StorySnapshot story, Chapter chapter) async {
    try {
      await ref
          .read(repositoryProvider)
          .setChapterNumbered(
            branchId: story.branch.id,
            chapterId: chapter.id,
            numbered: !chapter.numbered,
          );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
```

章节菜单在“重命名章节”之后加：

```dart
                menuEntry(
                  chapter.numbered ? '不计入编号' : '计入编号',
                  () => _toggleNumbered(story, chapter),
                  icon: FLucideIcons.hash,
                ),
```

`novel_dialog.dart`：

```dart
  late var _numerals =
      widget.novel?.chapterNumerals ?? ChapterNumerals.chinese;
```

“叙事视角”之后加：

```dart
          const SizedBox(height: 16),
          FSelect<ChapterNumerals>(
            label: const Text('章节编号'),
            items: const {
              '中文数字（第六章）': ChapterNumerals.chinese,
              '阿拉伯数字（第6章）': ChapterNumerals.arabic,
            },
            control: FSelectControl.lifted(
              value: _numerals,
              onChange: (v) => setState(() => _numerals = v ?? _numerals),
            ),
          ),
```

`createNovel(..., chapterNumerals: _numerals)`；`copyWith(..., chapterNumerals: _numerals)`。

`docs/user-guide.md` 章节相关段落补充（放在讲目录、新增章节的段落里，用现有行文风格）：

> 章节编号按目录顺序自动生成，名字单独填写，可以留空。新增章节时只填名字；重命名只改名字，编号不变；调整顺序或删除章节后编号自动重排。序章、楔子、番外等可在章节菜单里选“不计入编号”，它们只显示名字，也不占号。作品信息里可以把编号设成中文数字（第六章）或阿拉伯数字（第6章）。旧作品和导入的书保持原来的标题显示，编号能对上的章节自动计入编号。

- [ ] **Step 4: Run tests**

Run: `flutter test` → 全部 PASS（因“第N章”按顺序重编号而改变显示的旧断言，按新规则改期望）；`flutter analyze` → No issues；格式检查命令通过。
