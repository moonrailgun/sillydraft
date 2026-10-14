import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/reader/reader_document.dart';
import 'package:sillydraft/features/reader/reader_markup.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/features/reader/reader_style.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

/// The parts of [text] whose characters all carry [flag].
List<String> marked(String text, int flag, {List<HtmlBlock> skip = const []}) {
  final markup = ProseMarkup.parse(
    text,
    skip: [for (final b in skip) (start: b.start, end: b.end)],
  );
  final runs = <String>[];
  var run = StringBuffer();
  for (var i = 0; i <= text.length; i++) {
    if (i < text.length && markup[i] & flag != 0) {
      run.write(text[i]);
    } else if (run.isNotEmpty) {
      runs.add('$run');
      run = StringBuffer();
    }
  }
  return runs;
}

/// Every text span under [span] with the style it inherits from its parents.
List<(String, TextStyle)> spans(InlineSpan span, [TextStyle? parent]) {
  final style = parent?.merge(span.style) ?? span.style ?? const TextStyle();
  return [
    if (span is TextSpan && span.text != null) (span.text!, style),
    if (span is TextSpan)
      for (final child in span.children ?? const <InlineSpan>[])
        ...spans(child, style),
  ];
}

TextStyle styleOf(List<(String, TextStyle)> all, String text) =>
    all.firstWhere((s) => s.$1.contains(text)).$2;

void main() {
  const quote = Color(0xffaa5500), italic = Color(0xff888888);

  test('dialogue in each of ST\'s quote pairs, closing on the same line', () {
    const text = '他说："走吧。"又道“停下”。「好」与『嗯』与«oui»与＂对＂\n“没有收尾\n下一行”';
    expect(marked(text, ProseMarkup.quote), [
      '"走吧。"',
      '“停下”',
      '「好」',
      '『嗯』',
      '«oui»',
      '＂对＂',
    ]);
  });

  test('quotes stay out of code and the attributes of tags', () {
    expect(marked('`"代码"` 与 "台词"', ProseMarkup.quote), ['"台词"']);
    expect(marked('```\n"围栏"\n```\n"外面"', ProseMarkup.quote), ['"外面"']);
    expect(marked('<span class="hint">说</span>"真的"', ProseMarkup.quote), [
      '"真的"',
    ]);
  });

  test('Markdown emphasis follows showdown with ST\'s options', () {
    const text =
        '*低头* **用力** ***都*** __划线__ _斜_ * 空格 * '
        'snake_case_name 2 * 3\n*跨行\n不算*';
    expect(marked(text, ProseMarkup.italic), ['低头', '都', '斜']);
    expect(marked(text, ProseMarkup.bold), ['用力', '都']);
    expect(marked(text, ProseMarkup.underline), ['划线']);
    expect(marked(text, ProseMarkup.hidden), [
      '*',
      '*',
      '**',
      '**',
      '***',
      '***',
      '__',
      '__',
      '_',
      '_',
    ]);
    // Nested the way showdown's passes nest them.
    expect(marked('**重 *轻* 重**', ProseMarkup.italic), ['轻']);
    expect(marked('**重 *轻* 重**', ProseMarkup.bold), ['重 *轻* 重']);
  });

  test('line-start indents are hidden outside code', () {
    const text = '　　话音落下。\n  他看穿了。\n用 `x` 和 y\n```\n  代码\n```';
    final markup = ProseMarkup.parse(text, trimIndent: true);
    final hidden = [
      for (var i = 0; i < text.length; i++)
        if (markup[i] & ProseMarkup.hidden != 0) i,
    ];
    expect(hidden, [0, 1, 8, 9]);
    // Without asking, nothing is trimmed.
    expect(marked(text, ProseMarkup.hidden), isEmpty);
  });

  test('an indent after a hidden tag still starts its line', () {
    const text = '<p>　　话音落下。</p>\n<!-- 注 --> 他看穿了。';
    final markup = ProseMarkup.parse(text, trimIndent: true);
    final shown = String.fromCharCodes([
      for (var i = 0; i < text.length; i++)
        if (markup[i] & ProseMarkup.hidden == 0) text.codeUnitAt(i),
    ]);
    expect(shown, '话音落下。\n他看穿了。');
  });

  test('the page indents every paragraph alike, whatever the source did', () {
    final content = ManuscriptContent.plainText(
      '也许是刚开学。\n　　话音落下。\n柚木凪偏了偏头。\n  他看穿了。',
    );
    ReaderDocument page({required bool indent}) => ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 20,
      indent: indent,
      image: (_) => const SizedBox(),
    );
    final flush = page(indent: false), indented = page(indent: true);
    expect(flush.span.toPlainText(), '也许是刚开学。\n话音落下。\n柚木凪偏了偏头。\n他看穿了。\n');
    // The indent is a placeholder, one character in the text.
    expect(
      indented.span.toPlainText(),
      '\uFFFC也许是刚开学。\n\uFFFC话音落下。\n\uFFFC柚木凪偏了偏头。\n\uFFFC他看穿了。\n',
    );
    final text = content.text;
    for (final doc in [flush, indented]) {
      final shown = doc.span.toPlainText();
      for (final word in ['话音', '他看穿']) {
        expect(doc.sourceOffset(shown.indexOf(word)), text.indexOf(word));
      }
    }
  });

  testWidgets('justified lines keep the indent of wrapping paragraphs', (
    tester,
  ) async {
    // Justify drops the width of a line's leading spaces, so an indent made
    // of spaces vanished from every paragraph that wraps.
    const long = '他的眼角瞬间泛起了一层生理性的红，那是一股极度的羞耻与被看穿后的恐惧所带来的本能反应。';
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(
        ManuscriptContent.plainText('“我没有！”\n$long'),
      ),
      fontSize: 20,
      indent: true,
      image: (_) => const SizedBox(),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 310,
            child: Text.rich(
              doc.span,
              textAlign: TextAlign.justify,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText),
    );
    final shown = doc.span.toPlainText();
    double x(String word) => paragraph
        .getOffsetForCaret(TextPosition(offset: shown.indexOf(word)), Rect.zero)
        .dx;
    expect(x('“我没有'), 40);
    expect(x('他的眼角'), 40);
  });

  test('tags are hidden as ST hides them, outside code and within a line', () {
    const text =
        '<game>四月</game>\n<!-- 注 -->a<b>粗</b>\n'
        '`<i>`、<主角>、a < b>c\nx<y\nz>';
    expect(marked(text, ProseMarkup.hidden), [
      '<game>',
      '</game>',
      '<!-- 注 -->',
      '<b>',
      '</b>',
    ]);
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(
        ManuscriptContent.plainText('<game>四月的阳光\n\n凪低笑着。</game>\n'),
      ),
      fontSize: 20,
      image: (_) => const SizedBox(),
    );
    expect(doc.span.toPlainText(), isNot(contains('game')));
    expect(doc.span.toPlainText(), startsWith('四月的阳光'));
  });

  test('HTML blocks are left alone', () {
    const text = '"前"\n```html\n<p>"里" *面*</p>\n```\n"后"';
    final blocks = HtmlBlocks.find(text);
    expect(blocks, hasLength(1));
    expect(marked(text, ProseMarkup.quote, skip: blocks), ['"前"', '"后"']);
    expect(marked(text, ProseMarkup.hidden, skip: blocks), isEmpty);
  });

  test('the page colours dialogue and fades italics, and offsets hold', () {
    final content = ManuscriptContent.fromDelta([
      {'insert': '他*低头*说：“*真的*吗？”'},
      {
        'insert': '旁白',
        'attributes': {'italic': true},
      },
      {'insert': '。\n'},
    ]);
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 20,
      image: (_) => const SizedBox(),
      quoteColor: quote,
      italicColor: italic,
    );
    final shown = doc.span.toPlainText();
    expect(shown, '他低头说：“真的吗？”旁白。\n');
    final all = spans(doc.span);
    expect(styleOf(all, '低头').color, italic);
    expect(styleOf(all, '低头').fontStyle, FontStyle.italic);
    expect(styleOf(all, '他').color, isNull);
    expect(styleOf(all, '“').color, quote);
    // Italics inside dialogue keep the dialogue colour, as in ST.
    expect(styleOf(all, '真的').color, quote);
    expect(styleOf(all, '真的').fontStyle, FontStyle.italic);
    expect(styleOf(all, '旁白').color, italic);
    // Hidden markers drop out of the offset map, so search and bookmarks
    // still land on the right characters.
    final text = content.text;
    for (final word in ['低头', '说', '真的', '吗', '旁白']) {
      expect(doc.sourceOffset(shown.indexOf(word)), text.indexOf(word));
    }
    expect(doc.displayOffset(text.indexOf('*低头')), shown.indexOf('低头'));

    final plain = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 20,
      image: (_) => const SizedBox(),
    );
    expect(plain.span.toPlainText(), shown);
    expect(spans(plain.span).map((s) => s.$2.color).toSet(), {null});
  });

  test('highlight settings default on and are kept', () {
    expect(ReaderStyle.fromJson({}).highlightQuotes, isTrue);
    expect(ReaderStyle.fromJson({}).dimItalics, isTrue);
    final off = const ReaderStyle().copyWith(
      highlightQuotes: false,
      dimItalics: false,
    );
    final back = ReaderStyle.fromJson(off.toJson());
    expect(back.highlightQuotes, isFalse);
    expect(back.dimItalics, isFalse);
    expect(back, off);
  });

  testWidgets('the reader settings switch dialogue highlighting off', (
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
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港来信');
    await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '第一章',
      content: ManuscriptContent.plainText('她*回头*说：“走吧。”'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ReaderScreen(branchId: novel.activeBranchId)),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    List<(String, TextStyle)> page() => spans(
      tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.textSpan?.toPlainText().contains('走吧') == true)
          .textSpan!,
    );

    expect(styleOf(page(), '走吧').color, ReaderTheme.paper.quote);
    expect(styleOf(page(), '回头').color, ReaderTheme.paper.italic);
    expect(page().map((s) => s.$1).join(), isNot(contains('*')));

    await tester.tap(findAction('排版与主题').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('对白高亮'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AppSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // Built ahead of the viewport is not on screen yet.
    await tester.ensureVisible(find.text('对白高亮'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('对白高亮'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(styleOf(page(), '走吧').color, isNull);
    expect(styleOf(page(), '回头').color, ReaderTheme.paper.italic);
    final saved = await repo.getSetting('reader');
    expect(saved?['highlightQuotes'], isFalse);
    expect(saved?['dimItalics'], isTrue);
    expect(tester.takeException(), isNull);
  });
}
