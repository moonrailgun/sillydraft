# 漫画工作流改版实施计划

> **给执行代理：** 必须使用子技能 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐项执行本计划。步骤用复选框（`- [ ]`）跟踪进度。

**目标：** 原创漫画变成“写一句话 → 画一页 → 阅读 → 接着画”。漫画放在正文的位置，分镜在右栏；只有本话正在运行的任务或没画成的最后一页会挡住下一页。

**架构：** 核心改动只作用于原创文档（`ComicDocument.isOriginal`）：在 `ComicService`、`comic_store`、`ComicExporter` 中放宽关卡；续画任务无论检查结果如何都只画它新增的那一页；增加角色定妆图，并自动作为每页的参考图。界面新增章节画布（`comic_canvas.dart`）和分镜面板（`comic_storyboard.dart`）；`comic_screen.dart` 缩减为小说改编面板；共用对话框移到 `comic_dialogs.dart`；`workspace_screen.dart` 为漫画作品接入这些组件。

**技术栈：** Flutter 3.47.7 / Dart 3.13.5、Riverpod、forui 0.27、经 `StoryRepository` 使用的 drift/SQLite、`package:test` 与 `flutter_test`。

**设计文档：** `docs/superpowers/specs/2026-11-08-comic-workflow-redesign-design.md`（2026-11-08 已确认）。数据、恢复与改编规则仍按 `2026-11-07-comic-support-design.md` 和 `2026-11-08-native-comic-design.md`。

## 全局约束

- 改编文档（`!isOriginal`）保留现有全部规则：忠实检查阻止绘制、`visualReview`、原文过期、导出检查。现有改编测试必须原样通过。
- 不改数据库 schema，不改备份格式，不新增依赖。
- 测试只用模拟供应商或本地协议服务器，不调用付费模型。
- 不暂存、不提交、不 stash、不建分支。其他会话也在编辑这个工作区：编辑文件前重新读取。只格式化自己改过的文件。
- 界面文案用中文，代码和注释用英文。使用本计划规定的文案；其余文案沿用现有语气。
- 所有容器保留 16 逻辑像素内边距，相邻元素之间保留可见间距（`docs/design-guidelines.md`）。
- 核心命令在 `packages/sillydraft_core` 下运行（`dart test …`、`dart analyze`）；界面命令在仓库根目录运行（`flutter test …`、`flutter analyze`）。

## 审阅重点

1. **已经卡住的原创漫画**（用户截图里的情况：页已画好，`visualReview: true`，检查记录里有问题）。升级后“画下一页”必须立即可用，不需要任何额外步骤。由任务 1 的测试 `legacy stuck original can continue` 覆盖。
2. **前面某页因“只保存”而过期时点“画下一页”。** 只画新页，不意外地付费重画前面的页。由任务 2 的 `compose draws only the new page` 覆盖。
3. **画定妆图时崩溃后恢复。** 已完成的定妆图不重画；状态未知的进行中定妆图明确报错，绝不悄悄重新下单。由任务 3 的 `sheet resume reuses finished child` 覆盖。
4. **漫画作品里混有不同类型的话**（只有小说正文、v1 改编的单格图片、v2 原创整页），每一话都正常显示、不抛异常。由任务 5 的 `canvas renders mixed chapter kinds` 覆盖。
5. **删除页后又有新写入时再撤销。** 撤销必须报冲突，绝不覆盖较新的版本。由任务 1 的 `undo delete after newer write conflicts` 覆盖。

---

### 任务 1：模型、存储、服务与导出中的原创漫画规则

**文件：**
- 修改：`packages/sillydraft_core/lib/src/model/comic.dart`（`complete`、新增辅助方法）
- 修改：`packages/sillydraft_core/lib/src/storage/comic_store.dart`（`comicSourcesCurrent`、`restoreComic`、`_invalidateDependentComicImages`）
- 修改：`packages/sillydraft_core/lib/src/agent/comic_service.dart`（`_originalInput`、`generateImages`）
- 修改：`packages/sillydraft_core/lib/src/transfer/comic_exporter.dart`
- 测试：`packages/sillydraft_core/test/native_comic_test.dart`、`native_comic_task_test.dart`、`comic_export_test.dart`

**接口：**
- 产出（`ComicDocument`）：
  - `bool get complete`：原创文档为 `pages.isNotEmpty` 且每页都有 `assetId`；改编文档保持现有规则。
  - `List<String> get stalePageIds`：有 `assetId` 但 `fingerprint != pageFingerprint(page)` 的页。
  - `String? get lastPageId`。
  - `ComicDocument withoutPage(String pageId)`：删除该页及其分镜，清空 `audit`；页不存在时抛 `FormatException('漫画页不存在')`。
  - `ComicDocument editPage(String pageId, List<Map<String, dynamic>> panels)`：原地替换该页的分镜（增、删、排序、编辑），保留其他页和本页的图片字段。只有 `fingerprint` 不变时才保留 `audit`；从不设置 `visualReview`；列表为空时抛错。
- 产出（存储）：原创文档的章节仍在分支中时，`comicSourcesCurrent` 返回 `true`。`restoreComic` 与 `_invalidateDependentComicImages` 不再给原创文档（本话或其他话）设置 `visualReview`。
- 产出（服务）：`_originalInput` 只要求此前及当前原创漫画的每一页都有 `assetId`，否则抛 `FormatException('第 n 页还没有画好，请先重试或删除这一页')`，n 是该话中从 1 开始的页码。`generateImages` 对原创文档不再要求 `checked`。
- 产出（导出）：对原创文档，`ComicExporter.export` 只在缺图时阻止（`缺少 n 张图片`），忽略 `checked`、`visualReview` 和过期指纹。

- [ ] **步骤 1：编写失败的测试**（`native_comic_test.dart`）：
  - `complete ignores review and stale fingerprint for originals`：一份原创文档，有一张已画页、`visualReview: true`，并改过一格。期望 `complete == true`、`stalePageIds == [pageId]`。带 `visualReview: true` 的改编文档仍为 `complete == false`。
  - `withoutPage removes the page and its panels`：两页。`withoutPage(first)` 后期望 `pages.length == 1`、第一页的分镜都不在、`audit == null`。
  - `editPage adds and reorders panels within one page`：给第 2 页加一格 `{id: 'new', …}` 并倒序。期望第 2 页 `panelIds` 为新顺序，第 1 页不变，第 2 页保留 `assetId`，`stalePageIds == [page2]`，没有设置 `visualReview`。
  - 修改 `reordering and removing prior episodes stale context…`：调整顺序后、删除章节后，原创文档的 `comicSourcesCurrent(...)` 都为 `isTrue`。保留对 `priorComics` 复制与重映射的断言。
  - `restore keeps originals unflagged`：保存页图片，再保存一次编辑，然后用 `restoreComic` 恢复第一个版本。所有页的 `visualReview != true`。
  - `undo delete after newer write conflicts`：保存 A，保存 `withoutPage` 得到 B，再保存一次编辑得到 C。`restoreComic(revisionId: A.id, expectedRevisionId: B.id)` 抛 `isA<ComicConflict>()`，当前版本仍是 C。
- [ ] **步骤 2：编写失败的测试**（`native_comic_task_test.dart` 与 `comic_export_test.dart`）：
  - `legacy stuck original can continue`：`compose()` 后改写当前版本，让第 1 页 `visualReview: true`、`audit.reviews[0].issues == ['人物衣服颜色前后不一致']`（通过 `ComicDocument.fromJson` 保存）。随后 `compose(head: …)` 完成，`pages.length == 2`。
  - `missing image names the page`：`compose(draw: false)` 后 `compose(head: …)` 抛 `FormatException`，消息包含 `第 1 页还没有画好`。
  - `comic_export_test.dart` 中的 `original export ignores stale pages and blocks missing images`：带过期已画页的原创漫画可以导出；有未画页的原创漫画抛错，消息包含 `缺少 1 张图片`。
- [ ] **步骤 3：运行并确认新测试失败。** 运行 `dart test test/native_comic_test.dart test/native_comic_task_test.dart test/comic_export_test.dart`。新用例失败，其余通过。
- [ ] **步骤 4：实现**以上接口。改编分支的行为必须完全不变。
- [ ] **步骤 5：运行漫画测试集。** 运行 `dart test test/native_comic_test.dart test/native_comic_task_test.dart test/comic_export_test.dart test/comic_store_test.dart test/comic_task_test.dart test/native_comic_agent_test.dart && dart analyze`。全部通过，analyze 无问题。

### 任务 2：续画只画新页，并报告所处步骤

**文件：**
- 修改：`packages/sillydraft_core/lib/src/tasks/comic_runner.dart`（`_comicOriginal`、`_comicImages`）
- 测试：`packages/sillydraft_core/test/native_comic_task_test.dart`

**接口：**
- 使用：任务 1 的关卡。
- 产出：
  - `_comicImages(task, cancel, connection, {String? target})`，target 默认为 `task.input['panelId']`。续画传入新页 id：`"page-${task.input['comicCreationId'] ?? task.retryOf ?? task.id}"`。
  - 对原创文档，只要设置了 `imageConnection`，续画就继续绘制；即使自动修订一轮后检查仍有问题也一样。问题保存在文档的 `audit` 里。
  - 原创文档的 `withImage(needsReview:)` 为 `false`。
  - 任务结果键 `comicStage` 依次为 `'plan'`、`'check'`、`'sheets'`（由任务 3 写入）、`'page'`。每个阶段开始前用 `repository.updateTask(id, status: TaskStatus.running, result: {'comicStage': …})` 写入。

- [ ] **步骤 1：编写失败的测试：**
  - `compose draws only the new page`：`compose()`；保存对第 1 页某格描述的修改（第 1 页变为过期）；再 `compose(head: …)`。期望 `images == 2`（不是 3），第 1 页仍过期，第 2 页已画。
  - `audit issues do not block drawing originals`：模拟模型对每次 `COMIC/original-audit` 都返回 `{"issues":["台词顺序不清"]}`。`compose()` 完成，`images == 1`，`head.document.auditIssues` 包含 `台词顺序不清`，`COMIC/original-plan` 请求恰好 2 次（修订一轮）。
  - `compose reports stages in order`：在模拟回调中查询运行中的任务，收集 `comicStage`。关闭定妆图时期望 `['plan', 'check', 'page']`。
- [ ] **步骤 2：运行并确认失败。** 运行 `dart test test/native_comic_task_test.dart`，三个新测试失败。
- [ ] **步骤 3：实现** `comic_runner.dart` 中的接口。
- [ ] **步骤 4：运行漫画测试集**（命令同任务 1 步骤 5），全部通过。

### 任务 3：角色定妆图与自动参考图

**文件：**
- 修改：`packages/sillydraft_core/lib/src/model/comic.dart`（v2 页新增键 `characters`）
- 修改：`packages/sillydraft_core/lib/src/agent/comic_service.dart`（`compose(..., bool characterSheets = false)`、`drawCharacterSheet`）
- 修改：`packages/sillydraft_core/lib/src/tasks/comic_runner.dart`（`original-plan` 阶段说明、定妆图阶段、参考图选取）
- 测试：`packages/sillydraft_core/test/native_comic_task_test.dart`、`native_comic_test.dart`

**接口：**
- 使用：`IllustrationService.planReferences`、`IllustrationService.generate(purpose: AssetPurpose.reference)`、`IllustrationService.referenceDescription`、`IllustrationService.ensureReference`（已设 `assetId` 时只保存资料）、`StoryRepository.saveLoreEntry`、`listLore(branchId, throughChapterId:, kind: LoreKind.character)`。
- 产出：
  - v2 页的可选键 `characters`：0–16 个不重复的非空字符串，每个不超过 100 字符；缺省视为空；不计入 `pageFingerprint`。
  - `original-plan` 输出新增 `"characters":[{"name":"…","prompt":"fixed appearance"}]`（主要人物在前，最多 16 个）。运行器把名字存到新页上。
  - 任务输入 `comicCharacterSheets: true` 由 `compose(characterSheets: true)` 设置。只有本话还没有页、且前面没有任何一话有原创漫画时才生效。
  - 定妆图阶段（`comicStage: 'sheets'`，进度写在结果 `comicSheets: {'done': i, 'total': k}`）。对规划中前 3 个、且可见资料里还没有图片的角色：
    1. 生成一个参考图子任务；等待之前先把子任务 id 记到结果 `comicSheetChildren[name]`。
    2. 设置 `reference.assetId`，调用 `ensureReference`，把 `images` 和 `referencePrompt` 存进资料条目。
    3. 恢复时：已完成且有 `assetId` 的子任务直接复用；仍为活动状态但没有在运行的子任务抛 `FormatException('角色定妆图状态未知，请在任务页核实后再继续')`；失败或已取消的子任务重新生成。
  - 第 3 个之后的角色，或之后各页新出现、还没有资料的角色，用 `saveLoreEntry` 建条目（类型 character，content 与 `referencePrompt` 为外观描述，certainty 为 inference，provenance 为 `{'type': 'visualReference'}`），不画图。
  - 绘制时每页的参考图：
    - `page['referenceAssetIds']` 非空时用它（手动覆盖）；
    - 否则按页内出场顺序，取每个角色可见资料条目的第一张图片；
    - 上一页仍作为 `previousSceneAssetId` 传入；沿用现有 `referenceLimit` 截断。
  - `Future<String> ComicService.drawCharacterSheet({required String branchId, required String chapterId, required String name, required ModelConnection connection})`：为后来出现的角色一键画定妆图。
    1. 按名字找到可见的角色资料条目；找不到时抛 `FormatException('找不到角色资料：$name')`。
    2. 用它的 `referencePrompt` 生成参考图子任务并等待完成。
    3. 经 `ensureReference` 保存图片，返回图片 id。不改动任何漫画。

- [ ] **步骤 1：编写失败的测试：**
  - `native_comic_test.dart` 中的 `page characters are validated and not fingerprinted`：17 个名字抛 `FormatException`；修改 `characters` 不改变 `pageFingerprint`。
  - `opening draws up to three sheets then the page`：规划模拟返回 4 个角色，`compose(characterSheets: true)`。然后：
    - `images == 4`（3 张定妆图 + 1 页），共有 4 个角色资料条目，其中 3 个有 `images`；
    - 页面请求的 `refs` 包含 3 张定妆图的 hash，在模拟连接的 `referenceLimit` 允许范围内（让 `ModelConnection` 支持参考图）；
    - 步骤顺序为 `['plan', 'check', 'sheets', 'page']`。
  - `later pages reuse sheets and never draw new ones`：第二次 `compose(head: …, characterSheets: true)`，新增一个角色。期望 `images == 5`，新角色有资料条目但没有图片。
  - `manual page references override automatic ones`：把第 2 页 `referenceAssetIds` 设为一张插图库图片并重画第 2 页。它的 `refs` 以这张图开头，且不含任何定妆图。
  - `sheet resume reuses finished child`：让第 2 张定妆图卡住，取消任务后 `runner.resume(task.id)`。第 1 张定妆图不会再请求（`images` 只按剩余工作增加）。
  - `drawCharacterSheet adds an image to a later character`：在上面第二次续画之后，`drawCharacterSheet(name: <新角色>)` 返回一个 id，该资料条目的 `images` 以它开头，图片计数加 1，漫画当前版本 id 不变。
- [ ] **步骤 2：运行并确认失败。** 运行 `dart test test/native_comic_task_test.dart test/native_comic_test.dart`，新测试失败。
- [ ] **步骤 3：实现**以上接口。
- [ ] **步骤 4：运行漫画测试集**，另加 `dart test test/visual_reference_test.dart test/lore_repository_test.dart`。全部通过，`dart analyze` 无问题。

### 任务 4：共用漫画对话框与三步式改编面板

**文件：**
- 新建：`lib/features/comics/comic_dialogs.dart`
- 修改：`lib/features/comics/comic_screen.dart`（删去所有原创分支，保留改编流程）
- 测试：`test/comic_flow_test.dart`

**接口：**
- 产出（从 `_ComicScreenState` 移出的顶层函数，除注明处外行为不变）：
  - `Future<void> showComicHistory(BuildContext, WidgetRef, {required String branchId, required String chapterId})`
  - `Future<void> showComicExport(BuildContext, WidgetRef, {required String branchId, required String chapterId})`。每个过期的原创页加一行提醒：`{话标题} 第 n 页：分镜已改，图未更新`。
  - `Future<void> showComicCandidate(BuildContext, WidgetRef, {required String taskId, required String chapterId, required ComicRevision? head})`
  - `Future<List<String>?> pickComicReferences(BuildContext, {required String branchId, required List<String> initial})`：返回新的列表，取消时返回 null。
- `ComicScreen`（仅改编）。顶部显示三步 `编排分镜 → 检查改编 → 绘制`，只有当前步骤有主按钮：
  - 没有文档：`生成分镜`；正文为空时为 `本章还没有正文 · 编辑正文`；
  - 未通过检查：`检查改编`，问题列表就地显示；
  - 已通过但缺图：`绘制（n 张图）`；
  - 已完成：`已完成 · 阅读`。
  - `MenuAction` 中放 `重新改编`、`来源与事实`、`本话历史版本`、`导出漫画`。保留现有分镜列表。
  - 去掉 `漫画任务 · {状态}` 卡片：
    - 活动任务显示一行步骤名和 `查看详情`；
    - 失败任务显示错误和 `查看详情`；
    - 已结束且本章有候选的任务显示 `有未写入的分镜 · 比较`（`showComicCandidate`）。

- [ ] **步骤 1：更新测试**（`comic_flow_test.dart`）：
  - 删除 `empty original starts with instruction and has no draft`（移到任务 5）。
  - 新增 `adaptation panel shows one primary action per step`：用现有夹具（已通过检查、无图片），能找到 `绘制（1 张图）`，找不到作为按钮的 `检查改编` 和 `生成分镜`。
  - 其他改编测试保留，只调整本任务改名的按钮文案。
- [ ] **步骤 2：运行并确认失败。** 运行 `flutter test test/comic_flow_test.dart`，新测试失败。
- [ ] **步骤 3：实现** `comic_dialogs.dart` 和精简后的 `ComicScreen`。
- [ ] **步骤 4：运行界面检查。** 运行 `flutter test test/comic_flow_test.dart && flutter analyze lib/features/comics`，全部通过。

### 任务 5：漫画画布

**文件：**
- 新建：`lib/features/comics/comic_canvas.dart`
- 修改：`lib/features/comics/comic_reader.dart`（原创漫画不再显示 `分镜尚未通过检查` / `依据已过期`）
- 测试：`test/comic_canvas_test.dart`（测试外壳照搬 `comic_flow_test.dart` 的 `launch`）

**接口：**
- 使用：任务 1–4；现有 `comicProvider`、`tasksProvider`、`ComicPageView`、`ComicPanelView`、`AssetImageView`、`ComicService.compose/suggestDirections/generateImages`、`services.connectionFor('analysis'|'image'|'imageNsfw')`、`toast` / `showFToast(suffixBuilder:)`。
- 产出：
  ```dart
  class ComicCanvas extends ConsumerStatefulWidget {
    const ComicCanvas({super.key, required this.branchId, required this.chapterId,
      this.selectedPageId, this.initialInstruction, this.onSelectPage,
      this.onEditStoryboard, this.onOpenChapter, this.onReadProse, this.onAdapt});
    final String branchId, chapterId;
    final String? selectedPageId, initialInstruction;
    final ValueChanged<String>? onSelectPage, onEditStoryboard;
    final void Function(String chapterId, String? instruction)? onOpenChapter;
    final VoidCallback? onReadProse, onAdapt;
  }
  ```
- 按章节状态显示（文案按设计文档）：
  - **标题行：** 话标题和 `MenuAction`：`本话历史版本`、`导出漫画`。
  - **没有漫画、有正文：** 卡片 `本话有小说正文，还没有漫画`，带 `阅读正文`（`onReadProse`）和 `改编为漫画`（`onAdapt`）。
  - **没有漫画、也没有正文：** 开篇区。
    - 标题 `第一页发生了什么？`；输入框 key 为 `comic-instruction`，提示 `例如：雨夜，一个女孩在末班地铁上收到未来自己的短信`。
    - 输入框初始内容为 `initialInstruction`。上一话是原创漫画、且它的当前版本有已完成的方向任务时，在输入框上方显示那三个方向卡片，点一下填入输入框。
    - `画风：{novel.style，没有时为 未设置} · 修改`（打开 `showNovelDialog`）。
    - 开关 key 为 `comic-character-sheets`，默认开，标签 `先画主要角色的定妆图`，说明 `最多 3 张，之后每页都按它画`。前面已有某一话是原创漫画时隐藏（任务 3 在这种情况下会忽略它）。
    - 模型一行 `模型：{analysis.name} · {image.name}`；缺连接时为 `还没有分析模型 · 去设置` 或 `还没有生图模型 · 去设置`（打开 `SettingsScreen()`，输入保留）。
    - 按钮 `开始画`，下方一行 `自动编排分镜、检查连贯，画成一整页。首次最多 4 张图。`（开关关闭时为 `…画成一整页。共 1 张图。`）。
  - **有页：** 按顺序排列，最大宽度 760，页间距 24。每页下方显示 `第 n 页`，以及标记 `AI 提示 n`（只在 `lastPageId` 那页、且 `auditIssues` 非空时）和 `分镜已改，图未更新 · 重画`（过期页）。
    - 宽屏：悬停或获得焦点时显示工具条，有 `重画`、`改分镜`（`onEditStoryboard`）和 `⋯`（`生图记录`、`删除此页`）。
    - 窄屏（< 900）：点页弹出同样操作的菜单。
    - 点页调用 `onSelectPage`，选中的页显示描边。
    - v1 改编文档用 `ComicPanelView` 显示。
    - 页下方，`page['characters']` 里每个可见角色资料条目还没有图片的名字各显示一个标记 `新角色：{name} · 画定妆图`。点击调用 `drawCharacterSheet`（任务 3），运行期间显示忙碌状态。资料用 `repository.listLore(branchId, throughChapterId: chapterId, kind: LoreKind.character)` 读取，随 `repositoryContentChangesProvider` 刷新。
  - **删除页：** 不弹确认。保存 `withoutPage` 后显示提示 `已删除第 n 页`，带 `撤销` 按钮：调用 `restoreComic(revisionId: before, expectedRevisionId: after)`，出错时用 `showError` 显示。
  - **本话有活动的漫画任务：** 在正在画的那一页位置显示进度块（续画在最后一页之后，重画在第 k 页原位）。
    - 步骤 `编排分镜`、`检查连贯`、`画角色定妆图（i/k）`（只在 `input['comicCharacterSheets'] == true` 时）、`画第 n 页`，由 `result['comicStage']` 和 `result['comicSheets']` 驱动。
    - 一行 `离开也会继续`，以及 `取消`（`runner.cancel`）。
  - **最后一页没有图、且没有活动任务：** 卡片 `第 n 页没画成`，显示最近一次失败的相关任务的 `error`，带 `重试`（`generateImages(panelId: pageId)`）、`删除此页` 和 `查看详情`（`TaskScreen`）。“接下来”区换成 `第 n 页处理好后可以继续画`。
  - **有候选**（已结束的相关任务的 `comicCandidates` 包含本话）：卡片 `第 n 页已画好，但期间本话有改动，没有写入`，带 `比较`（`showComicCandidate`）。
  - **“接下来”区：** 只在最后一话出现；本话是原创漫画（或漫画作品里的空话），没有活动任务，且最后一页已画。
    - 标题 `接下来` 和 `换一批`（`suggestDirections`）。每个版本自动请求一次方向（沿用现在的 `_directionAttempts` 逻辑）。
    - 三个方向卡片；点一个只填入输入框并高亮该卡片。
    - 输入框提示 `下一页发生什么？`；主按钮 `画下一页`；次按钮 `本话完结，开始第 {n+1} 话`（`createChapter` 后调用 `onOpenChapter(newId, 当前输入框内容)`）。
    - 一行 `点方向只会填进输入框，可以先改再画。每页 1 张图。`
  - **不是最后一话：** 按钮 `下一话`（`onOpenChapter(nextId, null)`）。
- 防重复点击：请求进行中按钮不可用（沿用现有 `_busy` / `_run`），核心的版本检查也会拒绝重复请求。

- [ ] **步骤 1：编写失败的界面测试**（`test/comic_canvas_test.dart`）：
  - `empty chapter shows opening area`：能找到 `第一页发生了什么？` 和 `开始画`，找不到 `检查连续性`、`生成漫画`、`编辑故事底稿`。没有连接时输入文字并点 `开始画`，显示 `还没有分析模型 · 去设置`，输入的文字保留。
  - `drawn last page shows next area and direction fills field`：一份已画的原创漫画，加一个已完成的方向任务（`createTask` + `updateTask(status: completed, result: {'directions': [...]})`）。点第一张卡片后，它的 event 文字出现在 `comic-instruction` 里，且没有新建任务。
  - `failed last page blocks with retry and delete`：原创漫画第 2 页没有图。能找到 `第 2 页没画成`、`重试`、`删除此页`、`第 2 页处理好后可以继续画`，找不到 `画下一页`。
  - `running task shows progress at the new page`：一个运行中的续画任务，`comicStage: 'sheets'`、`comicSheets: {'done': 1, 'total': 3}`。能找到 `画角色定妆图（1/3）` 和 `离开也会继续`。
  - `stale page and AI hint chips`：能找到 `分镜已改，图未更新 · 重画` 和 `AI 提示 1`。
  - `delete page then undo restores it`：页数 2 → 1 → 2。
  - `finishing a chapter carries text and directions`：在已画好的最后一话输入 `第二天早上`，点 `本话完结，开始第 2 话`。`onOpenChapter` 收到新话 id 和 `第二天早上`。用 `initialInstruction: '第二天早上'` 为新话构建的画布显示这段文字和上一话的三个方向卡片，且没有 `comic-character-sheets` 开关。
  - `new character chip`：页面 `characters: ['林夏']` 且资料条目没有图片时，能找到 `新角色：林夏 · 画定妆图`；条目有图片后不再显示。
  - `canvas renders mixed chapter kinds`：只有正文的一话显示 `本话有小说正文，还没有漫画`；带单格图片的 v1 `fixture(chapter)` 显示 `第 1 格`；没有异常。
  - `narrow canvas keeps 16 px padding and long dialogue wraps`：宽度 390。
- [ ] **步骤 2：运行并确认失败。** 运行 `flutter test test/comic_canvas_test.dart`；因 `comic_canvas.dart` 不存在而失败。
- [ ] **步骤 3：实现** `ComicCanvas` 和 `comic_reader.dart` 的文案调整。
- [ ] **步骤 4：运行界面检查。** 运行 `flutter test test/comic_canvas_test.dart test/comic_flow_test.dart && flutter analyze lib/features/comics`，全部通过。

### 任务 6：分镜面板

**文件：**
- 新建：`lib/features/comics/comic_storyboard.dart`
- 修改：`lib/features/comics/comic_editor.dart`（仅当 `editComicPanel` 需要不落盘的 `save` 回调时；它已经接收回调）
- 测试：`test/comic_storyboard_test.dart`

**接口：**
- 使用：`ComicDocument.editPage` 与 `lastPageId`（任务 1）、`pickComicReferences`（任务 4）、`editComicPanel`、`ComicService.generateImages(panelId:)`。
- 产出：`class ComicStoryboard extends ConsumerStatefulWidget { const ComicStoryboard({super.key, required this.branchId, required this.chapterId, this.pageId, this.embedded = false}); }`。`pageId` 为 null 时取 `lastPageId`。
- 行为：
  - **顶部：** `第 n 页分镜`；本页是最后一页且有检查问题时加标记 `AI 提示 n`，展开为问题列表。
  - **分镜卡片：** `第 k 格`、画面描述、文字行（类型、说话人、文字），以及作用于本地草稿的 `上移` / `下移` / `删除`。`添加一格` 和编辑卡片经 `editComicPanel`，其 `save` 只更新草稿。
  - **参考图：** 折叠区 `本页参考图`，显示当前页 `referenceAssetIds`（为空表示自动：`自动：角色定妆图 + 上一页`），用 `pickComicReferences` 修改。
  - **底部按钮：** 主按钮 `保存并重画本页（1 张图）`：保存 `editPage`（草稿未改时跳过），然后 `generateImages(panelId:)`；次按钮 `只保存` 只在草稿有改动时可用。
  - **本话有任务在运行：** 只读，显示 `正在画第 n 页，画完后可以编辑`。
  - **还没有页：** 显示 `画好第一页后在这里改分镜`。
  - **改编文档：** 面板改为显示 `ComicScreen`（由工作区决定，见任务 7）。

- [ ] **步骤 1：编写失败的界面测试：**
  - `editing is local until saved`：把第 2 格上移，断言没有新增漫画版本（`listComicRevisions` 数量不变）；点 `只保存` 后新增一个版本，页内分镜顺序改变。
  - `running task makes storyboard read-only`：能找到 `正在画第 1 页，画完后可以编辑`；`只保存` 不可用。
  - `add a panel to the selected page`：`添加一格` 并 `只保存` 后，第 1 页 `panelIds.length` 加一，第 2 页不变。
  - `references fold shows automatic default`：能找到 `自动：角色定妆图 + 上一页`。
- [ ] **步骤 2：运行并确认失败。** 运行 `flutter test test/comic_storyboard_test.dart`。
- [ ] **步骤 3：实现** `ComicStoryboard`。
- [ ] **步骤 4：运行界面检查。** 运行 `flutter test test/comic_storyboard_test.dart test/comic_canvas_test.dart && flutter analyze lib/features/comics`，全部通过。

### 任务 7：工作区接线、小说阅读器入口与文档

**文件：**
- 修改：`lib/features/editor/workspace_screen.dart`
- 修改：`lib/features/reader/reader_screen.dart`（章节标题行）
- 修改：`docs/user-guide.md`（“漫画创作与小说改编”一节）、`docs/product-spec.md`（如有漫画相关描述）
- 测试：`test/comic_flow_test.dart`、`test/comic_canvas_test.dart`

**接口：**
- 使用：`ComicCanvas`（任务 5）、`ComicStoryboard`（任务 6）、`ComicScreen`（任务 4）、`showComicHistory` / `showComicExport`（任务 4）。
- 产出，仅当 `story.novel.workFormat == WorkFormat.comic`：
  - 工作区状态 `String? _selectedPage`，切换章节时重置；以及 `String? _carryInstruction`，由 `onOpenChapter(id, instruction)` 设置，作为 `initialInstruction` 传入一次后清空。
  - **宽屏 `_page`：** 用 `ComicCanvas` 代替 `ReaderScreen`。`onSelectPage` 设置 `_selectedPage` 并打开漫画工具，`onEditStoryboard` 同样；`onOpenChapter` 设置 `_selected`；`onReadProse` 打开 `ReaderScreen(chapterId:)`；`onAdapt` 打开漫画工具并显示 `ComicScreen`。
  - **右栏工具：** 名称为 `分镜`。显示 `ComicStoryboard(pageId: _selectedPage)`；本话是改编漫画，或本话有正文但没有漫画时，显示 `ComicScreen`。
  - **窄屏：** 分区顺序为 `目录, 漫画, 资料, 助手, 插图`；索引通过按作品类型区分的列表映射，不再直接用 `WorkspaceSection.index`。`漫画` 分区显示 `ComicCanvas`；`onEditStoryboard` 全屏打开 `ComicStoryboard(embedded: false)`。
  - **目录：** 每话副标题为 `{n} 页` 或 `绘制中`（监听 `comicProvider` 与活动任务）。章节菜单增加 `本话历史版本`、`导出漫画`，去掉 `创作漫画`。
  - **顶栏：** `作品操作` 菜单增加 `导出漫画`。`阅读` 按钮仍打开 `ComicReader`。
- 小说作品：其余一切照旧。阅读器章节标题行在该章有漫画（`comicProvider` 有数据）时增加 `看漫画版`，打开 `ComicReader`。
- 文档：按新流程重写用户指南的漫画一节（开篇、绘制、“接下来”区、分镜面板、什么会挡住下一页、角色定妆图、删除与撤销、导出提醒、小说的 `看漫画版`）。删去原创漫画相关的 `检查连续性`、`生成漫画`、`确认画面衔接`。

- [ ] **步骤 1：编写失败的界面测试：**
  - `comic work shows canvas in the middle on wide screens`（宽度 1200）：能找到 `第一页发生了什么？`，没有 `ReaderScreen`；侧栏有 `分镜` 提示。
  - `narrow comic work opens canvas from the bottom bar`（宽度 390）：底栏标签依次为 `目录, 漫画, 资料, 助手, 插图`。
  - `novel reader offers comic version`：小说作品某章保存了改编漫画，能找到 `看漫画版`，点击后打开 `ComicReader`。
  - 把 `comic works open the storyboard with a story draft entry` 改成新的预期；如果已被第一个测试覆盖则删除。
- [ ] **步骤 2：运行并确认失败。** 运行 `flutter test test/comic_flow_test.dart test/comic_canvas_test.dart`。
- [ ] **步骤 3：实现**接线和文档。
- [ ] **步骤 4：运行根目录测试集。** 运行 `flutter test test/comic_flow_test.dart test/comic_canvas_test.dart test/comic_storyboard_test.dart test/beta_mode_test.dart test/sidecar_flow_test.dart test/task_screen_test.dart && flutter analyze`，全部通过。

### 任务 8：验证

- [ ] **步骤 1：全量分析与测试。** 在仓库根目录运行 `flutter analyze && flutter test`；在 `packages/sillydraft_core` 运行 `dart analyze && dart test`。逐条查看失败，修复本次改动造成的问题。
- [ ] **步骤 2：检查改动文件的格式。** 运行 `dart format --output=none --set-exit-if-changed <每个改动的文件>`，应无需修改。
- [ ] **步骤 3：整体审阅。** 由一个全新的审阅者阅读设计文档、本计划和改动（`git diff` 加新文件），以审阅重点 1–5 为检查清单。修复重要问题并补回归测试。
- [ ] **步骤 4：报告。** 报告运行了什么、结果如何。明确说明真实模型的出图质量、角色一致性和 macOS 原生交互没有验证。
