import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
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
