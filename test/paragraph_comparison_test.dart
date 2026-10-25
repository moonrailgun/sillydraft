import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/editor/paragraph_comparison.dart';

import 'support/host.dart';

void main() {
  Widget comparison({
    String before = '开头\n旧段\n结尾\n',
    String after = '开头\n新段\n结尾\n',
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => testHost(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: SingleChildScrollView(
        child: ParagraphComparison(
          beforeTitle: '历史版本',
          afterTitle: '当前正文',
          before: before,
          after: after,
        ),
      ),
    ),
    brightness: brightness,
  );

  testWidgets('folds unchanged text and copies only selected paragraphs', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(comparison());
    await tester.pumpAndSettle();
    expect(find.text('删除 · 历史版本'), findsOneWidget);
    expect(find.text('新增 · 当前正文'), findsOneWidget);
    expect(find.text('开头'), findsNothing);
    expect(find.text('旧段'), findsOneWidget);
    expect(find.text('新段'), findsOneWidget);
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '复制选中片段')).onPress,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('paragraph-select-2')));
    await tester.pump();
    await tester.tap(find.text('复制选中片段'));
    await tester.pumpAndSettle();
    expect(copied, '新段\n');
    await tester.tap(find.text('相同内容 · 1 段').first);
    await tester.pumpAndSettle();
    expect(find.text('开头'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paragraph-select-0')));
    await tester.pump();
    await tester.tap(find.text('复制选中片段'));
    await tester.pumpAndSettle();
    expect(copied, '开头\n新段\n');
    await tester.tap(find.text('相同内容 · 1 段').first);
    await tester.pumpAndSettle();
    expect(find.text('开头'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing either text clears the selection', (tester) async {
    await tester.pumpWidget(comparison());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paragraph-select-2')));
    await tester.pump();
    await tester.pumpWidget(comparison(after: '另一份正文\n'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '复制选中片段')).onPress,
      isNull,
    );
    expect(find.text('另一份正文'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paragraph-select-3')));
    await tester.pump();
    await tester.pumpWidget(comparison(before: '', after: '另一份正文\n'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '复制选中片段')).onPress,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout supports large text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(comparison(scale: 2, brightness: brightness));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('empty and identical text show no artificial changes', (
    tester,
  ) async {
    for (final text in ['', '相同正文\n']) {
      await tester.pumpWidget(comparison(before: text, after: text));
      await tester.pumpAndSettle();
      expect(find.text('正文文字相同'), findsOneWidget);
      expect(find.text('删除 · 历史版本'), findsNothing);
      expect(find.text('新增 · 当前正文'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
