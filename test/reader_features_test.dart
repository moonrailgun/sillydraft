import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/reader/reader_document.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/features/reader/reader_style.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

/// A two-chapter book: a long first chapter and a short second one.
Future<(AppServices, Novel)> _open(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
  Map<String, Object>? style,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
  );
  addTearDown(services.close);
  final repo = services.repository;
  final novel = await repo.createNovel(title: '雾港来信');
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '第一章 码头',
    content: ManuscriptContent.plainText(
      List.generate(60, (i) => '第 $i 段：雾从港口升起，灯塔的光一下一下扫过海面。').join('\n'),
    ),
  );
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '第二章 灯塔',
    content: ManuscriptContent.plainText('灯塔熄灭了。'),
  );
  if (style != null) await repo.setSetting('reader', style);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(
        ReaderScreen(branchId: novel.activeBranchId),
        brightness: mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  return (services, novel);
}

Color _background(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(const Key('reader-page'))).color;

ScrollController _scroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
    .controller!;

String _shownTitle(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .firstWhere((t) => t != null && t.startsWith('第') && t.contains('章 '))!;

Future<void> _tapAt(WidgetTester tester, double x) async {
  await tester.tapAt(Offset(390 * x, 420));
  await tester.pumpAndSettle();
}

void main() {
  test('system mode resolves the two saved backgrounds independently', () {
    final style = ReaderStyle.fromJson({
      'themeMode': 'system',
      'lightTheme': 'sepia',
      'darkTheme': 'black',
    });
    expect(style.effectiveTheme(Brightness.light), ReaderTheme.sepia);
    expect(style.effectiveTheme(Brightness.dark), ReaderTheme.black);
    final restored = ReaderStyle.fromJson(style.toJson());
    expect(restored.effectiveTheme(Brightness.light), ReaderTheme.sepia);
    expect(restored.effectiveTheme(Brightness.dark), ReaderTheme.black);
  });

  test('explicit reader modes ignore system brightness', () {
    for (final brightness in Brightness.values) {
      expect(
        ReaderStyle.fromJson({'themeMode': 'light', 'lightTheme': 'green'})
            .effectiveTheme(brightness),
        ReaderTheme.green,
      );
      expect(
        ReaderStyle.fromJson({'themeMode': 'dark', 'darkTheme': 'black'})
            .effectiveTheme(brightness),
        ReaderTheme.black,
      );
    }
  });

  test('legacy backgrounds retain their mode and chosen palette', () {
    for (final theme in ReaderTheme.values) {
      for (final autoNight in [true, false]) {
        final style = ReaderStyle.fromJson({
          'theme': theme.name,
          'autoNight': autoNight,
        });
        final saved = style.toJson();
        expect(
          saved['themeMode'],
          theme.dark ? 'dark' : (autoNight ? 'system' : 'light'),
        );
        expect(saved[theme.dark ? 'darkTheme' : 'lightTheme'], theme.name);
        expect(ReaderStyle.fromJson(saved), style);
      }
    }
  });

  test('invalid background choices fall back to the matching brightness', () {
    final style = ReaderStyle.fromJson({
      'themeMode': 'unknown',
      'lightTheme': 'black',
      'darkTheme': 'green',
    });
    expect(style.toJson()['themeMode'], 'system');
    expect(style.effectiveTheme(Brightness.light), ReaderTheme.paper);
    expect(style.effectiveTheme(Brightness.dark), ReaderTheme.night);
  });

  test('stored reader settings are read back, clamped, and old ones kept', () {
    final style = ReaderStyle.fromJson({
      'fontSize': 99,
      'lineHeight': 1.5,
      'theme': 'sepia',
      'font': 'kai',
    });
    expect(style.fontSize, ReaderStyle.fontRange.max);
    expect(style.lineHeight, 1.5);
    expect(style.lightTheme, ReaderTheme.sepia);
    expect(style.font, ReaderFont.kai);
    expect(style.indent, isTrue);
    expect(style.hideHtml, isFalse);
    expect(style.hideImages, isFalse);
    expect(ReaderStyle.fromJson(style.toJson()), style);
  });

  test('visibility settings stay independent when saved', () {
    for (final hideHtml in [false, true]) {
      for (final hideImages in [false, true]) {
        final style = const ReaderStyle().copyWith(
          hideHtml: hideHtml,
          hideImages: hideImages,
        );
        expect(ReaderStyle.fromJson(style.toJson()), style);
      }
    }
  });

  test('indent and paragraph spacing keep bookmark offsets exact', () {
    final content = ManuscriptContent.plainText('雾起。\n\n　　灯灭。\n潮来。');
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 20,
      paragraphSpacing: 1,
      indent: true,
      image: (_) => const SizedBox(),
    );
    final shown = doc.span.toPlainText();
    // Indented once each, by the page's placeholder; the source's own
    // indent is not shown.
    expect(shown, startsWith('\uFFFC雾起。'));
    expect(shown, contains('\n\uFFFC灯灭。'));
    expect(shown, isNot(contains('　')));
    expect(doc.sourceOffset(shown.indexOf('潮来')), content.text.indexOf('潮来'));
    expect(doc.sourceOffset(shown.indexOf('灯灭')), content.text.indexOf('灯灭'));
  });

  testWidgets('settings change the page as they are made and are kept', (
    tester,
  ) async {
    final (services, _) = await _open(tester);
    expect(_background(tester), ReaderTheme.paper.background);
    await tester.tap(findAction('排版与主题').first);
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reader-font-larger')));
    await tester.tap(find.text('黑体'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('reader-theme-green')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-theme-green')));
    await tester.pumpAndSettle();
    expect(_background(tester), ReaderTheme.green.background);
    final body = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.textSpan != null && t.style?.fontSize != null)
        .first;
    expect(body.style!.fontSize, 21);
    await tester.scrollUntilVisible(
      find.text('两端对齐'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AppSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('两端对齐'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final saved = await services.repository.getSetting('reader');
    expect(saved?['fontSize'], 21);
    expect(saved?['font'], 'sans');
    expect(saved?['lightTheme'], 'green');
    expect(saved?['justify'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tapping anywhere shows or hides the bars without turning pages',
    (tester) async {
      await _open(tester);
      final scroll = _scroll(tester);
      expect(findAction('阅读设置').hitTestable(), findsOneWidget);

      await _tapAt(tester, .9);
      expect(scroll.offset, 0);
      expect(findAction('阅读设置').hitTestable(), findsNothing);
      await _tapAt(tester, .1);
      expect(scroll.offset, 0);
      expect(findAction('阅读设置').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection takes the page colour, not the app theme', (
    tester,
  ) async {
    // A light page in a dark app: the app's selection colour is near white.
    await _open(tester, mode: ThemeMode.dark, style: {'autoNight': false});
    final page = find.byKey(const Key('reader-page'));
    final text = find.descendant(of: page, matching: find.byType(RichText));
    expect(
      DefaultSelectionStyle.of(tester.element(text.first)).selectionColor,
      ReaderTheme.paper.selection,
    );
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(of: page, matching: find.byType(CustomPaint)),
        )
        .map((p) => p.painter)
        .firstWhere((p) => '${p.runtimeType}' == '_LineSelectionPainter');
    expect((painter as dynamic).color, ReaderTheme.paper.selection);
  });

  testWidgets('keyboard pages across chapters', (tester) async {
    await _open(tester);
    final scroll = _scroll(tester);
    // Page to the end of the long chapter, then on into the next.
    for (var i = 0; i < 20 && _shownTitle(tester) == '第一章 码头'; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
    }
    expect(_shownTitle(tester), '第二章 灯塔');
    // Back from the top of a chapter lands at the end of the previous one.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(_shownTitle(tester), '第一章 码头');
    expect(scroll.offset, scroll.position.maxScrollExtent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard pages forward and back', (tester) async {
    await _open(tester);
    final scroll = _scroll(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final after = scroll.offset;
    expect(after, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(scroll.offset, lessThan(after));
  });

  testWidgets('contents show chapters once and jump', (tester) async {
    await _open(tester);
    await tester.tap(findAction('目录'));
    await tester.pumpAndSettle();
    expect(find.text('共 2 章'), findsOneWidget);
    // One row per chapter.
    expect(
      find.descendant(of: find.byType(AppSheet), matching: find.text('第一章 码头')),
      findsOneWidget,
    );
    await tester.tap(find.text('第二章 灯塔').last);
    await tester.pumpAndSettle();
    expect(_shownTitle(tester), '第二章 灯塔');
  });

  testWidgets('settings keep independent backgrounds and all three modes', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final (services, _) = await _open(tester);
    await tester.tap(findAction('排版与主题'));
    await tester.pumpAndSettle();

    Future<void> choose(String key) async {
      final target = find.byKey(Key(key));
      await tester.scrollUntilVisible(
        target,
        key.startsWith('reader-mode-') ? -120 : 120,
        scrollable: find.descendant(
          of: find.byType(AppSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    await choose('reader-theme-sepia');
    expect(_background(tester), ReaderTheme.sepia.background);
    await choose('reader-theme-black');
    expect(_background(tester), ReaderTheme.sepia.background);
    await choose('reader-mode-dark');
    expect(_background(tester), ReaderTheme.black.background);
    await choose('reader-theme-green');
    expect(_background(tester), ReaderTheme.black.background);
    await choose('reader-mode-light');
    expect(_background(tester), ReaderTheme.green.background);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await choose('reader-mode-system');
    expect(_background(tester), ReaderTheme.black.background);
    await tester.pump(const Duration(seconds: 1));
    final saved = await services.repository.getSetting('reader');
    expect(saved?['themeMode'], 'system');
    expect(saved?['lightTheme'], 'green');
    expect(saved?['darkTheme'], 'black');

    // Reopening reads the reader's current values rather than sheet defaults.
    Navigator.of(tester.element(find.byType(AppSheet))).pop();
    await tester.pumpAndSettle();
    await _tapAt(tester, .5);
    await tester.tap(findAction('排版与主题'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoicePill>(find.byKey(const Key('reader-mode-system')))
          .selected,
      isTrue,
    );
    for (final theme in ['green', 'black']) {
      await tester.scrollUntilVisible(
        find.byKey(Key('reader-theme-$theme')),
        120,
        scrollable: find.descendant(
          of: find.byType(AppSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FTappable>(find.byKey(Key('reader-theme-$theme')))
            .selected,
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system brightness updates the page and the toolbar cycles three modes',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      // The app stays light throughout; system mode follows the OS instead.
      final (services, _) = await _open(
        tester,
        style: {'dim': .4, 'lightTheme': 'green', 'darkTheme': 'black'},
      );
      expect(_background(tester), ReaderTheme.black.background);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is ColoredBox && w.color == Colors.black.withValues(alpha: .4),
        ),
        findsOneWidget,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(_background(tester), ReaderTheme.green.background);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(_background(tester), ReaderTheme.black.background);

      await tester.tap(findAction('跟随系统'));
      await tester.pumpAndSettle();
      expect(findAction('亮色'), findsOneWidget);
      expect(_background(tester), ReaderTheme.green.background);
      await tester.tap(findAction('亮色'));
      await tester.pumpAndSettle();
      expect(findAction('暗色'), findsOneWidget);
      expect(_background(tester), ReaderTheme.black.background);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(_background(tester), ReaderTheme.black.background);
      await tester.tap(findAction('暗色'));
      await tester.pumpAndSettle();
      expect(findAction('跟随系统'), findsOneWidget);
      expect(_background(tester), ReaderTheme.green.background);
      await tester.pump(const Duration(seconds: 1));
      final saved = await services.repository.getSetting('reader');
      expect(saved?['themeMode'], 'system');
      expect(saved?['lightTheme'], 'green');
      expect(saved?['darkTheme'], 'black');
    },
  );

  testWidgets('auto-scroll moves the page and a tap stops it', (tester) async {
    await _open(tester, style: {'autoScrollSpeed': 100});
    final scroll = _scroll(tester);
    await tester.tap(findAction('自动滚动'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('reader-autoscroll')), findsOneWidget);
    expect(scroll.offset, closeTo(200, 30));
    await tester.tap(findAction('停止自动滚动'));
    await tester.pumpAndSettle();
    final stopped = scroll.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.offset, stopped);
    expect(find.byKey(const Key('reader-autoscroll')), findsNothing);
  });

  testWidgets('progress counts the whole book', (tester) async {
    await _open(tester);
    expect(find.text('全书 0.0%'), findsOneWidget);
    await tester.tap(findAction('下一章'));
    await tester.pumpAndSettle();
    // The short last chapter fits on screen, so the book is finished.
    expect(find.text('全书 100.0%'), findsOneWidget);
  });
}
