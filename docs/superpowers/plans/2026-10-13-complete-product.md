# SillyDraft Complete Product Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Implement the complete mobile and desktop novel-writing product described in the approved conversation and product specification.

**Architecture:** Flutter application with a pure Dart core package for models, SQLite repositories, ST compilation, provider protocols and recoverable workflows. Manuscript revisions, agent messages and lore are separate. A reusable runner exposes optional durable remote execution and synchronization without making local use require a server.

**Tech Stack:** Flutter stable, Dart, Riverpod, Drift/SQLite, Dio, Flutter Quill, platform file selection/sharing, secure storage, ZIP/EPUB.

**Spec:** `docs/product-spec.md` and `docs/st-preset-compatibility.md`.

## Global Constraints

- Work in the user-selected `/Users/moonrailgun/sillydraft` directory on the new `develop` branch.
- Android/iOS mobile-first; macOS/Windows/Linux desktop projects and adaptive interfaces.
- Agent conversation is never manuscript; only explicit acceptance commits a generated proposal.
- Version and branch isolation must be enforced by repository transactions, not only UI state.
- Preserve original ST data, report unsupported behavior, and pin comparison fixtures to ST commit `06bde939fb1e9c4c8d8641d810f0a916b5bce127`.
- Store secrets using platform secure storage and redact normal export/log output.
- Do not publish, create remote repositories, or use paid model services without the user providing the relevant authorization and configuration.
- Record verification limits honestly; do not mark the goal complete based only on unit tests or scaffolding.

## Review Focus

- Editing while generation runs: stale proposals must fail atomically without losing edits (Task 1, Task 4, Task 6).
- Forking before later revelations: future facts, relationships and macro values must not leak (Task 1, Task 3, Task 7).
- Broken/untrusted import archives: path traversal, excessive expansion and malformed JSON must preserve existing data (Task 2, Task 9).
- App/process/network interruption: persisted partial output is recoverable and retries do not silently duplicate acceptance or charges (Task 4, Task 8, Task 11).
- Narrow screens, Chinese composition and long manuscripts: navigation stays usable and edits survive lifecycle events (Task 5, Task 10, Task 12).

## Task 1: Persisted manuscript and branch foundation

**Files:** root Flutter platform scaffold; `packages/sillydraft_core/lib/src/model/`; `packages/sillydraft_core/lib/src/storage/`; `packages/sillydraft_core/test/story_repository_test.dart`.

**Interfaces:** `StoryRepository.open(String path)` / `.memory()`, `createNovel`, `createChapter`, `createScene`, `saveScene(expectedRevisionId)`, `forkBranch(atSceneId)`, `getStory(branchId)`, `createProposal`, `acceptProposal`, `close`. Typed novel/branch/chapter/scene/revision/proposal/lore/task records and `ManuscriptContent` persist JSON with schema versions.

- [x] Scaffold Flutter and pure Dart package, pin compatible dependency versions, and document the SDK command.
- [x] Write and run failing tests for reopen persistence, optimistic revision conflict, rejected proposal isolation, immutable fork history and scene ordering.
- [x] Implement transactional schema and typed records; run core tests to green, including rollback on conflict.
- [x] Commit the foundation and record exact test evidence.

## Task 2: Character cards and preset import/export

**Files:** `packages/sillydraft_core/lib/src/st/card_importer.dart`, `preset_importer.dart`, `world_book.dart`; corresponding tests and pinned fixtures.

**Interfaces:** `CardImporter.decode(Uint8List bytes, String filename)`, `PresetImporter.decode(Map<String,dynamic>)`, typed `CharacterCard`, `ImportedPreset`, diagnostics and raw-source export.

- [x] Write failing fixture tests for V1/V2/V3 JSON, PNG priority/metadata, CHARX assets, independent prompt packs, legacy presets and combined text templates.
- [x] Implement bounded parsing, retained fields, archive validation and diagnostic classifications.
- [x] Verify round trips, malformed inputs and ZIP traversal/expansion rejection before commit.

## Task 3: ST prompt compiler, macro and lore runtime

**Files:** core `src/st/prompt_compiler.dart`, `macro_engine.dart`, `template_engine.dart`, `regex_pipeline.dart`, `world_book_engine.dart`; fixture tests.

**Interfaces:** `PromptCompiler.compile(PresetInput input) -> CompiledPrompt` returns ordered messages/text, parameters, trace, diagnostic coverage and tentative variable state; input is an immutable branch snapshot.

- [x] Write failing ST fixture tests for 100001 selection, disabled prompts, injection grouping, overrides/original, templates, macro side effects and regex phases.
- [x] Implement distinct chat/text compilers and deterministic per-task evaluation; preserve stage semantics.
- [x] Test branch/time filtering, world-book recursion/budgets and unsupported dependency reporting; commit.

## Task 4: Providers, agent and recoverable tasks

**Files:** core `src/providers/`, `src/agent/`, `src/tasks/`; local HTTP/SSE integration tests.

**Interfaces:** `ModelProvider` text/tool/image capabilities; `TaskRunner.start/cancel/resume`; `WritingService.generate/rewrite/suggestBranches/analyze`; all tasks refer to persisted source revisions and preset versions.

- [x] Write failing tests using local protocol endpoints for fragmented streams, tool rounds, cancellation, errors and persisted partial results.
- [x] Implement provider adapters, scoped tools, prompt compilation, task records and proposal creation without automatic manuscript mutation.
- [x] Verify restart recovery, bounded retries, stale acceptance and deterministic artifact separation; commit.

## Task 5: Adaptive bookshelf, reader and editor

**Files:** Flutter `lib/app/`, `lib/features/bookshelf/`, `reader/`, `editor/`, `settings/`; widget/integration tests.

**Interfaces:** Riverpod repository/provider controllers consume core records; editor stores canonical Delta content, reader derives display; settings inject securely retrieved credentials.

- [x] Write workflow tests for novel creation, editing, save/reopen, reader independence, progress and mobile/desktop navigation.
- [x] Implement responsive shell, library, manuscript structure, Quill editor, reader preferences, bookmarks, search and model configuration.
- [x] Verify keyboard/IME behavior on available native device, accessibility and layout bounds; commit.

## Task 6: Agent workspace and proposal review

**Files:** Flutter `features/agent/`, proposal comparison widgets; core integration/controller tests.

- [x] Write failing flows for stream display, cancellation, selecting source text, diff acceptance/rejection and revision conflicts.
- [x] Wire real task runner, scoped conversations and artifact cards into creation workspace; add task recovery controls.
- [x] Verify deletion of agent conversations leaves manuscripts readable; commit.

## Task 7: Lore, relationships, maps and branch management

**Files:** core lore repository/services and Flutter `features/lore/`, `branches/`, `maps/`; domain and UI tests.

- [x] Write failing tests for CRUD/provenance, fact versus inference, extraction proposals, stale source analysis, past-position forks and relationship remapping.
- [x] Implement searchable dossiers, event/foreshadow timelines, interactive relationship graph, map pins/routes and branch tree/selection/comparison.
- [x] Verify selection of a plot candidate creates only the chosen branch facts and history; commit.

## Task 8: Illustration and asset lifecycle

**Files:** core asset/image services; Flutter `features/illustrations/`; provider/asset tests.

- [x] Write failing tests for image job completion/failure, source revision binding, safe local assets and retry job IDs.
- [x] Implement image generation/edit configuration, reference assets, gallery, covers, maps and manuscript insertion.
- [x] Verify image errors do not mutate prose and stale images remain traceable; commit.

## Task 9: Backup, publication formats and synchronization

**Files:** core `src/transfer/`; Flutter import/export/sync flows; archive and conflict tests.

- [x] Write failing real-file round trips for complete backup and TXT/Markdown/EPUB exports, excluding credentials.
- [x] Implement validation, atomic import, resource packaging and revision-aware remote synchronization with conflict copies.
- [x] Verify corrupted archives do not change existing projects and concurrent device edits remain recoverable; commit.

## Task 10: Native mobile and desktop integration

**Files:** platform projects, app shortcuts/menus, file gateway, theme/accessibility and lifecycle controllers.

- [x] Add tests for narrow/large layouts, shortcut actions, app lifecycle flushing and settings persistence.
- [x] Finish platform entitlements, keyboard/menu behavior, system import/share/save, desktop panel resizing and responsive navigation.
- [x] Build and run all locally available targets; retain clear validation status for other hosts; commit.

## Task 11: Optional remote task runner

**Files:** `server/` Dart executable, durable job store, API protocol and deployment documentation/tests.

- [x] Write failing HTTP integration tests for authenticated task submission, disconnect/reconnect, progress retrieval, cancellation and idempotency.
- [x] Implement runner using core providers/compiler/tasks, explicit connection configuration and persisted job snapshots.
- [x] Verify process restart, repeated delivery and client revision checks; commit.

## Task 12: Product audit and delivery

**Files:** end-to-end integration tests, build automation, CI, README and usage documentation.

- [x] Run full core and Flutter tests, analyzer, supported native builds and an actual end-to-end user journey.
- [x] Perform visual QA at phone and desktop widths with real app data; repair overflow, inaccessible controls and missing error states.
- [x] Request an independent whole-project review using a fresh reviewer, fix material findings with regression tests.
- [x] Audit every numbered product requirement and ST compatibility acceptance case against current evidence; record remaining gaps without narrowing scope.
- [x] Only mark the goal complete when all required work is implemented and verified to its actual scope.
