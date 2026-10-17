import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  for (final kind in ResourceKind.values) {
    testWidgets('large ${kind.name} previews build rows on demand', (
      tester,
    ) async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      final content = '${'长正文。' * 400}正文结尾';
      final book = {
        'entries': [
          for (var i = 0; i < 400; i++)
            {'id': i, 'comment': '条目 $i', 'content': content},
        ],
      };
      await services.repository.storeResource(
        id: 'large',
        kind: kind,
        name: '大资源',
        filename: 'large.json',
        sourceHash: 'fixture-hash-large',
        encryptedSource: [],
        data: switch (kind) {
          ResourceKind.preset => {
            'prompts': [
              for (var i = 0; i < 400; i++)
                {
                  'identifier': 'entry-$i',
                  'name': '条目 $i',
                  'role': 'system',
                  'content': content,
                },
            ],
            'prompt_order': [
              {
                'character_id': 100001,
                'order': [
                  for (var i = 0; i < 400; i++)
                    {'identifier': 'entry-$i', 'enabled': true},
                ],
              },
            ],
          },
          ResourceKind.character => {
            'spec': 'chara_card_v2',
            'data': {'name': '大资源', 'character_book': book},
          },
          ResourceKind.worldBook => book,
          ResourceKind.regex => {
            'scripts': [
              for (var i = 0; i < 400; i++)
                {
                  'scriptName': '条目 $i',
                  'findRegex': 'test',
                  'replaceString': content,
                },
            ],
          },
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(const ResourceDetailScreen(resourceId: 'large')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('条目 0'), findsOneWidget);
      expect(find.text('条目 399'), findsNothing);
      expect(
        find.textContaining(RegExp(r'^条目 \d+$')).evaluate().length,
        lessThan(20),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains(
                '正文结尾',
              ),
        ),
        findsNothing,
      );
      await tester.tap(find.text('条目 0'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正文结尾'), findsOneWidget);
      await tester.tap(find.text('条目 0'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('条目 399'),
        600,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      await tester.pumpAndSettle();
      expect(find.text('条目 399'), findsOneWidget);
      await tester.tap(find.text('条目 399'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正文结尾'), findsOneWidget);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final bottom = position.pixels;
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('条目 399'), findsNothing);
      position.jumpTo(bottom);
      await tester.pumpAndSettle();
      expect(find.textContaining('正文结尾'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a card\'s detail page previews it and shows its raw JSON', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    await services.repository.storeResource(
      id: 'card',
      kind: ResourceKind.character,
      name: '苏雾',
      filename: 'card.json',
      sourceHash: 'fixture-hash-0',
      encryptedSource: [],
      data: {
        'spec': 'chara_card_v2',
        'data': {
          'name': '苏雾',
          'description': '守塔人\r\n住在雾港',
          'first_mes': '钟声响起',
          'alternate_greetings': ['一封信'],
          'tags': ['悬疑'],
          'character_book': {
            'entries': [
              {
                'keys': ['灯塔'],
                'content': '灯塔在港口尽头',
                'comment': '灯塔',
                'enabled': true,
              },
            ],
          },
          'extensions': {
            'regex_scripts': [
              {
                'scriptName': '隐藏状态栏',
                'findRegex': '<status>.*</status>',
                'replaceString': '',
                'placement': [2],
                'markdownOnly': true,
              },
            ],
          },
        },
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const ResourceDetailScreen(resourceId: 'card')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('悬疑'), findsOneWidget);
    expect(find.text('设定'), findsOneWidget);
    expect(find.textContaining('住在雾港'), findsOneWidget);
    expect(find.text('备用开场 1'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('隐藏状态栏'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('角色书  启用 1 / 1'), findsOneWidget);
    expect(find.textContaining('关键词：灯塔'), findsOneWidget);
    expect(find.text('隐藏状态栏'), findsOneWidget);
    expect(find.text('AI 输出、仅显示'), findsOneWidget);

    await tester.ensureVisible(find.text('原始 JSON'));
    await tester.tap(find.text('原始 JSON'));
    await tester.pumpAndSettle();
    expect(find.text('设定'), findsNothing);
    // The root and `data` start open; deeper containers start folded.
    expect(find.textContaining('spec: '), findsOneWidget);
    expect(find.textContaining('description: '), findsOneWidget);
    await tester.ensureVisible(find.textContaining('character_book: '));
    await tester.tap(find.textContaining('character_book: '));
    await tester.pumpAndSettle();
    expect(find.textContaining('entries: '), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
