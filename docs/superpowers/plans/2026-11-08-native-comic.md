# Native Comic Implementation Plan

Spec: `docs/superpowers/specs/2026-11-08-native-comic-design.md` (approved).

Goal: original comics start from an instruction, persist storyboards and complete page images, continue through three directions, and expose real assistant tools.

Global constraints: preserve legacy adaptation and source validation; use existing durable tasks/revisions/image providers; no prose generation for originals; no new dependencies; no paid calls; preserve unrelated dirty work. Work in this existing isolated worktree. No commits/push authorized.

## Task 1: Versioned original documents and page persistence
Files: core model/comic.dart, storage/comic_store.dart, transfer/project_snapshot.dart, storage/project_store.dart; native_comic_test.dart.
Interfaces: origin=original/adaptation, optional original source revision, priorComics with nullable heads for empty episodes, pages with ordered panel IDs, asset/task/fingerprint and review state. Shared render items expose pages or legacy panels.
Steps: write original persistence, invalid source, page edit and copy tests; observe failure; implement strict v2 model and repository validation/remapping; run core comic store/export tests.
Expected: original needs no prose revision; legacy evidence remains strict; edits invalidate whole pages; backup copy preserves original references.

## Task 2: Original planning, directions and page generation
Files: agent/comic_service.dart, tasks/comic_runner.dart, native_comic_task_test.dart; illustration integration only as needed.
Interfaces: create/continue via compose(draw optional), directions, existing check/images; freeze comic heads and order; append page per request; persisted calls and image child tasks.
Steps: local provider tests for empty manuscript start, exactly three directions, selected continuation, stale heads and cancellation; implement using existing comic call and illustration pipeline; run all comic task tests.
Expected: no prose generation, one image per page with dialogue prompt, no image call on storyboard only, stale tasks retain candidates.

## Task 3: Assistant tools
Files: agent/editor_agent.dart, tasks/agent_runner.dart, agent/builtin_skills.dart; native comic agent tests.
Interfaces: frozen comic scope/head; read_comic, plan_comic, edit_comic, draw_comic, continue_comic, adapt_comic; durable child tasks and own-head refresh.
Steps: tests verify offered tools and real saved results with empty prose; implement service-backed tools; run relevant agent tests.
Expected: original excludes prose tools; storyboard does not require image connection; novel retains adaptation.

## Task 4: Creation, workspace, reader and export
Files: bookshelf/novel_dialog.dart, editor/workspace_screen.dart, features/comics/*, transfer/comic_exporter.dart; comic_flow and export tests.
Interfaces: original opening composer, automatic directions once per completed head, custom continuation, page reader with accessibility transcript, legacy panel display.
Steps: widget/export tests; wire existing settings/connections/tasks and fork behavior; hide original source/fidelity controls; update user/product/design docs; run targeted widget and export tests.
Expected: original no draft UI; complete images have no duplicate text; legacy text remains visible; missing configuration preserves input.

## Task 5: Verification and final review
Run root/core analyze, root/core tests and repository format check; inspect every result. Fresh reviewer checks scope and failure modes. Fix important findings with regression tests. No commits or external publishing.
Expected: current verification evidence and explicit native/real-provider limits.

## Review Focus
Malformed original/adaptation source claims; cross-work ownership; edited/reordered/restored heads; repeated image calls after recovery; branch/future context leakage; invalidating whole pages including lettering; legacy export; assistant head freeze and deduplication.
