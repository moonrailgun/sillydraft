import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/bookshelf/bookshelf_screen.dart';
import 'package:sillydraft/features/bookshelf/novel_start.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sillydraft/app/widgets.dart';

Future<AppServices> _launch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
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
  await tester.pumpWidget(SillyDraftApp(services: services));
  await tester.pumpAndSettle();
  return services;
}

/// Runs a start as if the file had been picked or dropped on the shelf.
Future<void> _drop(WidgetTester tester, String name, String content) async {
  final shelf = tester.element(find.byType(BookshelfScreen));
  final bytes = Uint8List.fromList(utf8.encode(content));
  // Not awaited: for a book it resolves only when the preview is closed.
  unawaited(startFromFile(shelf, name: name, read: () async => bytes));
  await tester.pumpAndSettle();
}

const _book = '''《雾港来信》
内容简介：一封信改变了港口。

第一章 码头
雾从港口升起。

第二章 灯塔
灯塔熄灭了。
''';

const _card =
    '''{"spec":"chara_card_v2","data":{"name":"苏雾","description":"守塔人",
"scenario":"雾港","first_mes":"{{user}}听见钟声","alternate_greetings":[]}}''';

void main() {
  testWidgets('an empty shelf offers every way to begin', (tester) async {
    await _launch(tester);
    expect(find.byKey(const Key('start-blank')), findsOneWidget);
    expect(find.byKey(const Key('start-card')), findsOneWidget);
    expect(find.byKey(const Key('start-import')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-novel')));
    await tester.pumpAndSettle();
    expect(find.text('开始一部作品'), findsOneWidget);
    expect(find.text('续写已有小说'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dropped book is previewed, imported, and ready to continue', (
    tester,
  ) async {
    final services = await _launch(tester);
    await _drop(tester, '雾港来信.txt', _book);
    expect(find.text('2 章 · 13 字'), findsOneWidget);
    expect(find.text('第二章 灯塔'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('import-title')),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '雾港来信',
    );
    await tester.tap(find.byKey(const Key('import-create')));
    await tester.pumpAndSettle();
    final novel = (await services.repository.listNovels()).single;
    expect(novel.synopsis, contains('一封信改变了港口'));
    // The workspace opens where the story stops.
    expect(
      find.descendant(
        of: find.byKey(const Key('resume-writing')),
        matching: find.text('继续写作 · 第二章 灯塔'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dropped card starts a story once, even if dropped twice', (
    tester,
  ) async {
    final services = await _launch(tester);
    await _drop(tester, 'suwu.json', _card);
    expect(find.text('以 苏雾 为起点'), findsOneWidget);
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    await _drop(tester, 'suwu.json', _card);
    expect(find.text('以 苏雾 为起点'), findsOneWidget);
    expect(
      await services.repository.listResources(kind: ResourceKind.character),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('files that cannot start a work say what can', (tester) async {
    await _launch(tester);
    await _drop(tester, 'preset.json', '{"temperature": 1}');
    expect(find.textContaining('这个 JSON 不是角色卡'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await _drop(tester, 'notes.docx', 'x');
    expect(find.textContaining('TXT、Markdown、EPUB'), findsOneWidget);
  });
}
