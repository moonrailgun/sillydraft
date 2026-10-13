import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

const _page = '''<html>
<head>
<style>body { min-height: 100vh; margin: 0; }</style>
</head>
<body>
<div id="info-card">道渊</div>
<script>
  async function go() {
    const msgs = await getChatMessages(0, { include_swipe: true });
    setChatMessage(msgs[0].swipes[1], 0, { swipe_id: 1 });
  }
</script>
</body>
</html>''';

void main() {
  group('HtmlBlocks.find', () {
    test('fenced html page becomes one front-end block with its newline', () {
      final text = '开场白前言\n```html\n$_page\n```\n正文继续\n';
      final blocks = HtmlBlocks.find(text);
      expect(blocks, hasLength(1));
      final block = blocks.single;
      expect(block.kind, HtmlBlockKind.frontend);
      expect(block.language, 'html');
      expect(block.source, _page);
      expect(text.substring(block.start, block.end), '```html\n$_page\n```\n');
      expect(text.substring(block.end), '正文继续\n');
    });

    test(
      'any fence whose content holds a page marker renders, as 酒馆助手 does',
      () {
        expect(
          HtmlBlocks.find('```\n<body><p>hi</p></body>\n```').single.kind,
          HtmlBlockKind.frontend,
        );
        expect(HtmlBlocks.find('```js\nconst a = "<div>";\n```'), isEmpty);
        expect(
          HtmlBlocks.find('```html\n<div class="x">片段</div>\n```')
              .single
              .source,
          '<div class="x">片段</div>',
        );
      },
    );

    test('an unclosed fence extends to the end of the text', () {
      final text = '```html\n<p>未关闭';
      final block = HtmlBlocks.find(text).single;
      expect(block.end, text.length);
      expect(block.source, '<p>未关闭');
    });

    test('raw block-level HTML at line start is a sanitized fragment', () {
      const text =
          '前文。\n<style>.a{color:red}</style>\n\n<div style="width: 80%">\n'
          '  <details class="mvu"><summary>变量更新</summary>内容</details>\n'
          '</div>\n后文。\n';
      final blocks = HtmlBlocks.find(text);
      expect(blocks, hasLength(1));
      final block = blocks.single;
      expect(block.kind, HtmlBlockKind.fragment);
      expect(text.substring(0, block.start), '前文。\n');
      expect(text.substring(block.end), '后文。\n');
      expect(block.source, startsWith('<style>'));
      expect(block.source, endsWith('</div>\n'));
    });

    test('inline tags, unclosed tags and Chinese brackets stay prose', () {
      expect(HtmlBlocks.find('<b>强调</b>的一行\n'), isEmpty);
      expect(HtmlBlocks.find('<div>没有结束\n还在写\n'), isEmpty);
      expect(HtmlBlocks.find('<小说>标题\n'), isEmpty);
      expect(HtmlBlocks.find('a < b 并且 c > d\n'), isEmpty);
    });

    test('nested same-name tags close at the matching depth', () {
      const text = '<div><div>内</div></div>\n<div>第二块</div>\n尾\n';
      final blocks = HtmlBlocks.find(text);
      expect(blocks, hasLength(1));
      expect(text.substring(blocks.single.end), '尾\n');
    });

    test('void tags such as images form a block on their own', () {
      final block = HtmlBlocks.find('<img src="https://x/y.png">\n').single;
      expect(block.source, '<img src="https://x/y.png">\n');
    });
  });

  group('HtmlBlocks.sanitizeFragment', () {
    test('drops scripts, frames, handlers and script URLs but keeps style', () {
      final cleaned = HtmlBlocks.sanitizeFragment(
        '<div style="color:red" onclick="steal()">'
        '<script>alert(1)</script><iframe src="https://x"></iframe>'
        '<a href="javascript:evil()">a</a><a href="https://ok">b</a>'
        '<img src="data:text/html,x"><img src="data:image/png;base64,AA==">'
        '<object data="x"></object></div>',
      );
      expect(cleaned, isNot(contains('<script')));
      expect(cleaned, isNot(contains('<iframe')));
      expect(cleaned, isNot(contains('<object')));
      expect(cleaned, isNot(contains('onclick')));
      expect(cleaned, isNot(contains('javascript:')));
      expect(cleaned, isNot(contains('data:text/html')));
      expect(cleaned, contains('data:image/png'));
      expect(cleaned, contains('href="https://ok"'));
      expect(cleaned, contains('style="color:red"'));
    });
  });

  group('HtmlBlocks.rewriteViewportUnits', () {
    test('rewrites min-height vh in css, inline styles and scripts', () {
      const source =
          '<style>body{min-height:100vh;height:100vh}</style>'
          '<div style="min-height: 50vh"></div>'
          '<script>el.style.minHeight = "100vh";'
          "el.style.setProperty('min-height', '25vh')</script>";
      final out = HtmlBlocks.rewriteViewportUnits(source);
      expect(out, contains('min-height:var(--TH-viewport-height)'));
      expect(out, contains('height:100vh}'));
      expect(
        out,
        contains('min-height: calc(var(--TH-viewport-height) * 0.5)'),
      );
      expect(out, contains('el.style.minHeight = "var(--TH-viewport-height)"'));
      expect(out, contains("'calc(var(--TH-viewport-height) * 0.25)'"));
    });

    test('leaves content without min-height untouched', () {
      const source = '<div style="height: 100vh"></div>';
      expect(HtmlBlocks.rewriteViewportUnits(source), source);
    });
  });
}
