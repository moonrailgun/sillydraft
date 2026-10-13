import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/theme.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/lore/variables_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

Future<AppServices> _services() async {
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
  );
  await services.repository.storeResource(
    id: 'card',
    kind: ResourceKind.character,
    name: '道渊',
    filename: 'card.json',
    sourceHash: 'fixture',
    encryptedSource: [],
    data: {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '道渊',
        'description': '修仙世界',
        'first_mes': "开场。\n_.set('主角.生命', 100, 90);//开局受伤",
        'character_book': {
          'name': '道渊世界书',
          'entries': [
            {
              'id': 1,
              'keys': <String>[],
              'comment': '[initvar] 初始',
              'enabled': false,
              'content': '主角:\n  生命: 100\n  境界: 凡人\n',
            },
          ],
        },
      },
    },
  );
  return services;
}

Widget _host(AppServices services, Widget page) => ProviderScope(
  overrides: [servicesProvider.overrideWithValue(services)],
  child: MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => FTheme(
      data: appTheme(Brightness.light),
      child: FToaster(child: child!),
    ),
    home: page,
  ),
);

/// Lets a toast go so it does not cover the buttons below.
Future<void> _settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the variable manager shows MVU state, edits and reprocesses', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = await _services();
    addTearDown(services.close);
    final repo = services.repository;
    final novel = await repo.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    );
    final branchId = novel.activeBranchId;
    expect(
      (await MvuService(repo).storedAt(branchId))!.statData['主角']['生命'],
      90,
    );

    await tester.pumpWidget(
      _host(services, VariablesScreen(branchId: branchId)),
    );
    await tester.pumpAndSettle();
    expect(find.text('变量管理器'), findsOneWidget);
    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mvu-status')), findsOneWidget);
    expect(find.textContaining('已初始化（道渊世界书）'), findsOneWidget);
    expect(find.textContaining('100->90 (开局受伤)'), findsWidgets);

    // Hand-edit the chat scope: the record is stored as plain JSON.
    final editor = find.byKey(const Key('variables-chat'));
    final text = tester
        .widget<EditableText>(
          find.descendant(of: editor, matching: find.byType(EditableText)),
        )
        .controller
        .text;
    await tester.enterText(
      editor,
      text.replaceFirst('"境界": "凡人"', '"境界": "筑基"'),
    );
    await tester.ensureVisible(find.byKey(const Key('save-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-chat')));
    await tester.pumpAndSettle();
    expect(
      (await MvuService(repo).storedAt(branchId))!.statData['主角']['境界'],
      '筑基',
    );
    await _settleToast(tester);

    // Invalid JSON is reported, not saved.
    await tester.enterText(editor, '{');
    await tester.ensureVisible(find.byKey(const Key('save-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-chat')));
    await tester.pumpAndSettle();
    expect(find.textContaining('JSON 无效'), findsOneWidget);
    expect(
      (await MvuService(repo).storedAt(branchId))!.statData['主角']['境界'],
      '筑基',
    );

    // Reprocessing replays the opening's command from InitVar.
    await tester.ensureVisible(find.byKey(const Key('mvu-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mvu-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新处理变量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新处理'));
    await tester.pumpAndSettle();
    final replayed = (await MvuService(repo).storedAt(branchId))!;
    expect(replayed.statData['主角']['境界'], '凡人');
    expect(replayed.statData['主角']['生命'], 90);
    await _settleToast(tester);

    // The message tab lists chapters with their own editors.
    await tester.tap(find.text('消息楼层'));
    await tester.pumpAndSettle();
    final chapter = (await repo.getStory(branchId)).chapters.single;
    expect(find.byKey(Key('chapter-card-${chapter.id}')), findsOneWidget);
    expect(find.byKey(Key('reprocess-${chapter.id}')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
