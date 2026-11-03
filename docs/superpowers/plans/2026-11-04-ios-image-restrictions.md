# iOS Image Restrictions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** iOS 不提供 NSFW 插画生成，并阻止旧任务及远程调用绕过。

**Architecture:** AppServices 注入平台策略，TaskControl 暴露运行时限制，冻结任务只能收紧策略。IllustrationService 在分类后拒绝 NSFW，执行器在调用生图前拒绝 NSFW/未分类快照。RemoteTaskControl 将限制传给声明支持的桌面，限制批准和重试。

**Tech Stack:** Flutter 3.47.7、Dart 3.13.5、现有任务/分类/远程协议，不加依赖。

**Spec:** docs/superpowers/specs/2026-11-04-ios-image-restrictions-design.md

## Global Constraints

- 中文文案，英文代码注释；不调用付费模型，不运行 TF 上传或提审。
- iOS 平台策略不由用户设置或导入备份控制；已有配置不删除。
- 普通插画继续，其他平台默认行为不变。

## Review Focus

- 旧快照没有分类，不能直接生图；测试直接任务及重试。
- 助手排队后重新冻结输入，不能丢失限制；测试远程助手。
- 桌面本身允许 NSFW，但手机任务必须保持禁止；测试冻结策略。
- 桌面旧版无能力声明，不能静默执行；测试能力检查。
- 手机确认桌面已有生图请求，必须检查每张图和新参考图；测试拒绝确认。

### Task 1: iOS generation policy

**Files:** lib/app/services.dart; lib/features/settings/settings_screen.dart; lib/features/illustrations/illustration_relations.dart; packages/sillydraft_core/lib/src/{agent,tasks,remote}/ affected files; test/image_routing_settings_test.dart; packages/sillydraft_core/test/{image_routing,remote_tasks}_test.dart; release/design/compatibility docs.

**Interfaces:** TaskControl.allowNsfwImages (bool, default true in core); frozen input allowNsfwImages=false; RemoteHello.imageContentPolicy (version 1). A false runtime/frozen policy always wins.

- [x] Write failing UI test: iOS saved NSFW role ignored, no selector, normal role available; other-platform tests preserved.
- [x] Write failing core tests: restricted mixed batch fails without image calls; true/missing classification tasks and retries fail; false classification succeeds; remote restricted tasks retain policy and reject unsafe confirmation.
- [x] Run focused tests and record missing behavior failures.
- [x] Implement policy propagation, fail-closed image execution and UI copy; add legacy remote capability refusal test.
- [x] Run focused tests, static analysis, full Flutter/core suites, format and diff checks. Capture actual settings rendering for layout inspection.
- [x] Review the change independently; fix persona classification, safe desktop confirmation and known NSFW reference gaps.

Delivery: commit and push this feature, then update the existing private backup including current source and checksums. Do not trigger iOS upload.
