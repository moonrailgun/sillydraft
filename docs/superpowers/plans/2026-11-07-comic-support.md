# 漫画创作与小说改编 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 在现有作品中完成可追溯的小说改编、原创漫画、分镜编辑、逐格生图、阅读和导出。

**Architecture:** 独立 ComicDocument 与不可变漫画 revisions，通过现有分支 head 保存。ComicService 创建冻结任务，TaskRunner 执行分批提取、分镜、独立审查与串行 illustration 子任务；界面只读写仓库、控制任务。

**Tech Stack:** Flutter 3.47.7 / Dart 3.13.5、现有 drift SQLite / Riverpod / Forui / archive，不新增依赖。

**Spec:** `docs/superpowers/specs/2026-11-07-comic-support-design.md`（用户已确认）

## Global Constraints

- 中文界面与文档，英文代码与注释；遵循现有间距和交互规范。
- 不改小说正文或 ST 兼容语义，保留来源版本与冲突保护。
- 测试只调用本地协议服务器，不调用付费模型；不控制用户电脑。
- 使用当前独立工作区执行；未获提交、推送或发布授权，不执行这些动作。
- 用完整源文分批提取，检查失败不生图；恢复不静默重复付费请求。

## Review Focus

- 含 emoji、长句、HTML 或正文附件的原文：不损坏坐标或静默漏掉内容（任务 1、2）。
- 同章资料包含结尾真相：逐步揭示，不能被参考图提示提前泄露（任务 2）。
- 作者编辑或取消时图片迟到：保存资源但不覆盖新分镜（任务 2）。
- 复制作品或从旧备份恢复：外部引用重映射、旧小说与新漫画完整（任务 1）。
- 长中文台词、无图/缺格、恶意 HTML：阅读完整、导出检查并转义（任务 3、4）。

## Task 1: 漫画模型、持久化与迁移

**Files:** 新增 `packages/sillydraft_core/lib/src/model/comic.dart`、`storage/comic_store.dart`、`test/comic_store_test.dart`；修改 `storage/database.dart`、`story_repository.dart`、`story_mappers.dart`、`branch_store.dart`、`manuscript_store.dart`、`project_store.dart`、`model/story.dart`、`transfer/project_snapshot.dart` 和核心导出。

**Interfaces:** `ComicDocument.fromJson/toJson` 校验源文、facts、panels 和 audit；`ComicRevision` 包含文档与版本。仓库 `getComic(branchId, chapterId)`、`saveComic(branchId:, chapterId:, document:, expectedRevisionId:)`、`listComicRevisions`。

- [x] 编写失败测试：文档源文覆盖 / 无效引用 / emoji 坐标；保存、并发冲突、分叉隔离、旧备份恢复与新备份复制。
- [x] 运行 `dart test test/comic_store_test.dart`，确认新接口尚不存在。
- [x] 实现严格文档与源文切分、不可变保存、分支 head、数据库 12 迁移、作品类型、snapshot v2 及 v1 迁移 / ID 重映射 / 关系验证。
- [x] 运行上述测试与 `database_version_test.dart project_backup_test.dart project_sync_test.dart`，全部通过。

## Task 2: 改编、审查与生图任务

**Files:** 新增 `agent/comic_service.dart`、`tasks/comic_runner.dart`、`test/comic_task_test.dart`；修改 `model/task.dart`、`tasks/task_runner.dart`、`app/services.dart` 和任务展示调用方。

**Interfaces:** `ComicService.adapt(branchId:, chapterIds:, connection:, style:)`、`check(branchId:, chapterId:, connection:)`、`generateImages(branchId:, chapterId:, connection:, promptConnection:)` 返回 `GenerationTask`；runner 保存阶段与候选，图像用原有 `IllustrationService`。

- [x] 本地模型 / 图像 stub 测试：原文→事实→分镜→独立检查；否定遗漏阻止生图；长文分批和边界检查；中断续跑与并发编辑。
- [x] 运行测试，确认任务尚不受支持。
- [x] 实现上下文冻结、来源排除显式处理、前情状态、结构与语义双检查、一轮自动修订、持久化阶段与重新改编候选。
- [x] 实现顺序子任务、接图版本保护、取消传播、恢复已完成 / 未知状态处理，保留旧资源。
- [x] 运行 `dart test test/comic_task_test.dart test/illustration_task_test.dart test/remote_tasks_test.dart`。

## Task 3: 漫画导出

**Files:** 新增 `transfer/comic_exporter.dart`、`test/comic_export_test.dart`；沿用 `publication_exporter.dart` 的资源边界。

**Interfaces:** `ComicExporter(repository:, assets:).export(branchId:, chapterIds:)` 返回包含离线 ZIP 字节的 `PublicationFile`，复用文件保存接口。

- [x] 测试完整阅读顺序、长中文对白、HTML 转义、无图 / 未检查拒绝、资源所属与 256 MB 上限。
- [x] 运行测试确认导出器不存在。
- [x] 实现离线单列 HTML、同作品资源收集、完整性校验。
- [x] 运行 `dart test test/comic_export_test.dart test/publication_export_test.dart`。

## Task 4: 漫画创作界面与入口

**Files:** 新增 `lib/features/comics/` 和 `test/comic_flow_test.dart`；修改 `features/bookshelf/novel_dialog.dart`、`novel_start.dart`、工作区 / 章节入口、任务详情、服务接线。

**Interfaces:** `ComicScreen(branchId:, chapterId:)` 使用前述仓库与服务；采用现有模型选择、AssetImage、图片挑选和 FileGateway。

- [x] 界面测试覆盖作品类型、工作区漫画入口、编辑 / 排序检查失效、来源对照、候选采用和长台词阅读。
- [x] 运行测试确认漫画入口不存在。
- [x] 实现原创故事底稿、连续章节改编、分镜编辑与来源 / 问题、一次确认生图 / 单格重画、历史 / 冲突恢复、阅读及导出。
- [x] 运行 `flutter test test/comic_flow_test.dart test/novel_start_test.dart test/workspace_sections_test.dart test/workspace_layout_test.dart`。

## Task 5: 回归、说明与独立代码审阅

**Files:** 更新 `docs/design-guidelines.md`、`docs/product-spec.md`、`docs/user-guide.md` 及受影响的测试 fixture。

- [x] 运行全仓格式检查、核心 `dart analyze && dart test`、`flutter analyze && flutter test`；检查 server 受影响契约。
- [x] 用执行计划技能要求的独立审阅检查整个工作区差异，重点检查 Review Focus。
- [x] 修复重要问题并运行覆盖测试；更新用户文档，明确模型检查和未做真实供应商 / 原生视觉验证的限制。
- [x] 保留可审查的未提交改动，报告实际验证结果。

最终验证：核心 832 项、Flutter 381 项、server 11 项测试通过；三个包的静态分析通过；格式检查 375 个文件、0 项变更。独立审阅提出的三项重要问题已修复，覆盖复制作品续跑、跨章图片依赖与迟到结果保护、对白原文顺序。使用本地模型桩，未验证真实模型成图或原生交互。
