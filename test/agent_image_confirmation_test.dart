import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  for (final batch in [false, true]) {
    for (final width in [390.0, 900.0]) {
      testWidgets(
        '${batch ? 'batch' : 'single'} image details fold without hiding actions at width $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = width == 390
              ? 1.3
              : 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final repo = StoryRepository.memory();
          final services = AppServices(
            repository: repo,
            secrets: MemorySecrets(),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await services.close();
          });
          final novel = await repo.createNovel(title: '密信显字');
          final conversation = await repo.createConversation(
            branchId: novel.activeBranchId,
          );
          await repo.appendAgentMessage(
            conversation,
            role: 'user',
            content: '生成本章插图',
          );
          final task = await repo.createTask(
            branchId: novel.activeBranchId,
            kind: TaskKind.agent,
            input: {
              'conversationId': conversation,
              'image': {
                'connection': ModelConnection(
                  id: 'image',
                  name: '测试引擎',
                  baseUrl: 'http://localhost:1',
                  model: 'fixture',
                ).raw,
              },
            },
          );
          final prompt =
              'Create a cinematic illustration in an old bookshop. ' * 30;
          final preview = {
            'connection': ModelConnection(
              id: 'normal',
              name: '普通引擎',
              baseUrl: 'http://localhost:1',
              model: 'normal-image',
            ).raw,
            'nsfw': false,
            'name': '第七章·密信显字',
            'prompt': prompt,
            'negativePrompt': 'blurred text',
            'illustrationAnchor': {'quote': '他打开了密信。'},
          };
          final pending = {
            'id': 'confirmation-1',
            'newReferences': [
              for (final kind in ['character', 'location'])
                {
                  'name': kind == 'character' ? '神谷透' : '古贺书房',
                  'kind': kind,
                  'prompt': 'A detailed reference of the $kind. ' * 20,
                },
            ],
            if (batch)
              'images': [
                preview,
                {
                  ...preview,
                  'connection': ModelConnection(
                    id: 'nsfw',
                    name: '成人引擎',
                    baseUrl: 'http://localhost:1',
                    model: 'nsfw-image',
                  ).raw,
                  'nsfw': true,
                },
              ]
            else
              ...preview,
          };
          await repo.updateTask(
            task.id,
            status: TaskStatus.running,
            result: {'imageConfirmation': pending},
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [servicesProvider.overrideWithValue(services)],
              child: testHost(
                AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
                brightness: width == 390 ? Brightness.light : Brightness.dark,
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text(prompt).hitTestable(), findsNothing);
          expect(
            find
                .text('${batch ? '1. ' : ''}普通 · 普通引擎 · normal-image')
                .hitTestable(),
            findsOneWidget,
          );
          if (batch) {
            expect(
              find.text('2. NSFW · 成人引擎 · nsfw-image').hitTestable(),
              findsOneWidget,
            );
          }
          expect(
            find.textContaining('先生成 2 张参考图').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('取消').hitTestable(), findsOneWidget);
          expect(find.text('确认生成').hitTestable(), findsOneWidget);

          final details = find.text('提示词与参考图');
          await tester.tap(details);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('神谷透 · 人物参考图'));
          await tester.pumpAndSettle();
          expect(find.text('神谷透 · 人物参考图').hitTestable(), findsOneWidget);
          await tester.ensureVisible(find.text('blurred text').last);
          await tester.pumpAndSettle();
          expect(find.text('blurred text').last.hitTestable(), findsOneWidget);
          expect(find.text(prompt), findsNWidgets(batch ? 2 : 1));
          expect(find.text('他打开了密信。'), findsNWidgets(batch ? 2 : 1));

          await tester.ensureVisible(details);
          await tester.pumpAndSettle();
          await tester.tap(details);
          await tester.pumpAndSettle();
          expect(find.text(prompt).hitTestable(), findsNothing);
          expect(find.text('取消').hitTestable(), findsOneWidget);
          expect(find.text('确认生成').hitTestable(), findsOneWidget);
          expect(
            (await repo.getTask(task.id)).result['imageConfirmation'],
            pending,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
