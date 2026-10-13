import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// How a block of HTML found in manuscript text is shown.
///
/// [frontend] is a fenced code block holding a page or app, the kind
/// SillyTavern's 酒馆助手 (JS-Slash-Runner) renders in an iframe. It runs its
/// own scripts inside the sandbox and can call the bridge API.
///
/// [fragment] is raw HTML written straight into the text, such as the
/// `<div><details>` blocks regex scripts produce. SillyTavern shows those
/// through its markdown renderer with DOMPurify; here they are sanitized the
/// same way (no scripts, handlers or frames) and never get the API.
enum HtmlBlockKind { frontend, fragment }

/// A run of manuscript text to show as HTML instead of prose.
final class HtmlBlock {
  const HtmlBlock({
    required this.start,
    required this.end,
    required this.source,
    required this.kind,
    this.language = '',
  });

  /// Range in the text this block replaces, including the trailing newline
  /// of the last line when there is one.
  final int start, end;

  /// The HTML to render: the inside of the fence, or the raw run.
  final String source;
  final HtmlBlockKind kind;

  /// The fence's language tag, e.g. `html`.
  final String language;

  int get length => end - start;
}

/// Finds HTML blocks in text and prepares them for a sandboxed web view.
abstract final class HtmlBlocks {
  /// Largest text scanned for blocks; longer chapters show as prose.
  static const maxScanLength = 4 * 1024 * 1024;

  /// Languages whose fences always render, even for fragments.
  static const _frontendLanguages = {'html', 'htm', 'xhtml'};

  /// Tags that may open a raw HTML block at the start of a line. Inline
  /// emphasis (`<b>`, `<i>`) stays prose so that one bold line does not
  /// become a web view.
  static const _blockTags = {
    'div',
    'details',
    'summary',
    'table',
    'section',
    'article',
    'aside',
    'header',
    'footer',
    'nav',
    'main',
    'figure',
    'figcaption',
    'center',
    'font',
    'p',
    'ul',
    'ol',
    'dl',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'pre',
    'hr',
    'img',
    'style',
    'span',
    'button',
    'select',
    'textarea',
    'progress',
    'meter',
    'svg',
    'video',
    'audio',
    'iframe',
    'object',
    'embed',
    'form',
    'fieldset',
    'canvas',
    'picture',
    'template',
    'dialog',
    'marquee',
    'ruby',
    'br',
    'input',
    'label',
    'a',
  };
  static const _voidTags = {'hr', 'img', 'br', 'input', 'embed'};

  /// What 酒馆助手 treats as a front-end code block: any fenced code whose
  /// content contains a page marker, whatever its language tag.
  static bool looksLikeFrontend(String code) =>
      code.contains('html>') ||
      code.contains('<head>') ||
      code.contains('<body');

  static final _fenceOpen = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)');
  static final _tagOpen = RegExp(r'^[ \t]*<([a-zA-Z][a-zA-Z0-9-]*)(?=[\s/>])');

  /// Blocks in [text], ordered and non-overlapping.
  static List<HtmlBlock> find(String text) {
    if (text.length > maxScanLength) return const [];
    final blocks = <HtmlBlock>[];
    var lineStart = 0;
    while (lineStart < text.length) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = text.length;
      final line = text.substring(lineStart, lineEnd);
      final fence = _fenceOpen.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!,
            language = fence.group(2)!.toLowerCase();
        final close = RegExp(
          '^[ \\t]{0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
        );
        var cursor = lineEnd + 1,
            contentEnd = text.length,
            blockEnd = text.length;
        while (cursor <= text.length && cursor > 0) {
          var next = text.indexOf('\n', cursor);
          if (next < 0) next = text.length;
          if (close.hasMatch(text.substring(cursor, next))) {
            contentEnd = max(lineEnd + 1, cursor - 1);
            blockEnd = next < text.length ? next + 1 : next;
            break;
          }
          if (next >= text.length) break;
          cursor = next + 1;
        }
        final content = lineEnd + 1 >= contentEnd
            ? ''
            : text.substring(lineEnd + 1, contentEnd);
        if (_frontendLanguages.contains(language) ||
            looksLikeFrontend(content)) {
          blocks.add(
            HtmlBlock(
              start: lineStart,
              end: blockEnd,
              source: content,
              kind: HtmlBlockKind.frontend,
              language: language,
            ),
          );
        }
        lineStart = blockEnd;
        continue;
      }
      final tag = _tagOpen.firstMatch(line);
      if (tag != null && _blockTags.contains(tag.group(1)!.toLowerCase())) {
        final name = tag.group(1)!.toLowerCase();
        final tagStart = lineStart + tag.start + line.indexOf('<');
        final closeEnd = _voidTags.contains(name)
            ? _endOfTag(text, tagStart)
            : _matchingClose(text, tagStart, name);
        if (closeEnd != null) {
          var end = closeEnd;
          var tail = text.indexOf('\n', closeEnd);
          if (tail < 0) tail = text.length;
          if (text.substring(closeEnd, tail).trim().isEmpty) {
            end = tail < text.length ? tail + 1 : tail;
          }
          blocks.add(
            HtmlBlock(
              start: lineStart,
              end: end,
              source: text.substring(lineStart, end),
              kind: HtmlBlockKind.fragment,
            ),
          );
          lineStart = end;
          continue;
        }
      }
      lineStart = lineEnd + 1;
    }
    return _mergeFragments(text, blocks);
  }

  static int? _endOfTag(String text, int from) {
    final end = text.indexOf('>', from);
    return end < 0 ? null : end + 1;
  }

  /// Index just past the `</name>` that closes the tag opened at [from],
  /// counting nested tags of the same name.
  static int? _matchingClose(String text, int from, String name) {
    final pattern = RegExp(
      '<(/?)${RegExp.escape(name)}(?=[\\s/>])[^>]*>',
      caseSensitive: false,
    );
    var depth = 0;
    for (final match in pattern.allMatches(text, from)) {
      final closing = match.group(1) == '/';
      final selfClosing = !closing && match.group(0)!.endsWith('/>');
      if (closing) {
        depth--;
        if (depth == 0) return match.end;
      } else if (!selfClosing) {
        depth++;
      } else if (depth == 0) {
        return match.end;
      }
      if (match.end - from > maxScanLength) break;
    }
    return null;
  }

  /// Adjacent raw fragments with only whitespace between them render as one
  /// block so that a `<style>` keeps applying to the `<div>` after it.
  static List<HtmlBlock> _mergeFragments(String text, List<HtmlBlock> blocks) {
    final merged = <HtmlBlock>[];
    for (final block in blocks) {
      final last = merged.lastOrNull;
      if (last != null &&
          last.kind == HtmlBlockKind.fragment &&
          block.kind == HtmlBlockKind.fragment &&
          text.substring(last.end, block.start).trim().isEmpty) {
        merged[merged.length - 1] = HtmlBlock(
          start: last.start,
          end: block.end,
          source: text.substring(last.start, block.end),
          kind: HtmlBlockKind.fragment,
        );
      } else {
        merged.add(block);
      }
    }
    return merged;
  }

  static const _droppedTags = {
    'script',
    'iframe',
    'frame',
    'frameset',
    'object',
    'embed',
    'applet',
    'link',
    'meta',
    'base',
    'noscript',
  };
  static const _urlAttributes = {
    'href',
    'src',
    'action',
    'formaction',
    'poster',
    'background',
    'data',
    'srcset',
    'cite',
    'longdesc',
    'usemap',
  };

  /// Strips what DOMPurify would from raw HTML: scripts, frames, event
  /// handlers, script URLs and `srcdoc`. Styles stay, as in SillyTavern.
  static String sanitizeFragment(String source) {
    final fragment = html_parser.parseFragment(source);
    _clean(fragment);
    return fragment.outerHtml;
  }

  static void _clean(dom.Node node) {
    for (final child in node.nodes.toList()) {
      if (child is! dom.Element) continue;
      final tag = child.localName?.toLowerCase() ?? '';
      if (_droppedTags.contains(tag)) {
        child.remove();
        continue;
      }
      child.attributes.removeWhere((key, value) {
        final name = key.toString().toLowerCase();
        if (name.startsWith('on') || name == 'srcdoc') return true;
        if (_urlAttributes.contains(name) || name.endsWith(':href')) {
          final target = value
              .replaceAll(RegExp(r'[\s\x00-\x1f]'), '')
              .toLowerCase();
          if (target.startsWith('javascript:') ||
              target.startsWith('vbscript:') ||
              target.startsWith('file:')) {
            return true;
          }
          if (target.startsWith('data:') && !target.startsWith('data:image/')) {
            return true;
          }
        }
        if (name == 'style' &&
            RegExp(
              r'expression\s*\(|javascript:|behavior\s*:',
              caseSensitive: false,
            ).hasMatch(value)) {
          return true;
        }
        return false;
      });
      _clean(child);
    }
  }

  /// Rewrites `min-height: …vh` to the host viewport variable, as 酒馆助手
  /// does. Inside a frame sized to its content, `100vh` would otherwise grow
  /// the frame on every measurement.
  static String rewriteViewportUnits(String content) {
    if (!RegExp(
          r'min-height\s*:\s*[^;{}]*\d+(?:\.\d+)?vh',
          caseSensitive: false,
        ).hasMatch(content) &&
        !RegExp(
          r'\.style\.minHeight\s*=',
          caseSensitive: false,
        ).hasMatch(content) &&
        !RegExp(
          '''setProperty\\s*\\(\\s*["']min-height["']''',
          caseSensitive: false,
        ).hasMatch(content)) {
      return content;
    }
    String convert(String value) => value.replaceAllMapped(
      RegExp(r'(\d+(?:\.\d+)?)vh\b', caseSensitive: false),
      (m) {
        final number = double.tryParse(m.group(1)!);
        if (number == null) return m.group(0)!;
        const variable = 'var(--TH-viewport-height)';
        return number == 100
            ? variable
            : 'calc($variable * ${_trim(number / 100)})';
      },
    );
    var result = content.replaceAllMapped(
      RegExp(
        r'(min-height\s*:\s*)([^;{}]*?\d+(?:\.\d+)?vh)(?=\s*[;}])',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}${convert(m.group(2)!)}',
    );
    result = result.replaceAllMapped(
      RegExp('''(style\\s*=\\s*(["']))([^"']*?)(\\2)''', caseSensitive: false),
      (m) {
        final style = m.group(3)!;
        if (!RegExp(
          r'min-height\s*:\s*[^;]*vh',
          caseSensitive: false,
        ).hasMatch(style)) {
          return m.group(0)!;
        }
        final replaced = style.replaceAllMapped(
          RegExp(
            r'(min-height\s*:\s*)([^;]*?\d+(?:\.\d+)?vh)',
            caseSensitive: false,
          ),
          (s) => '${s.group(1)}${convert(s.group(2)!)}',
        );
        return '${m.group(1)}$replaced${m.group(4)}';
      },
    );
    result = result.replaceAllMapped(
      RegExp(
        '''(\\.style\\.minHeight\\s*=\\s*(["']))([^"']*?)(\\2)''',
        caseSensitive: false,
      ),
      (m) =>
          RegExp(
            r'\b\d+(?:\.\d+)?vh\b',
            caseSensitive: false,
          ).hasMatch(m.group(3)!)
          ? '${m.group(1)}${convert(m.group(3)!)}${m.group(4)}'
          : m.group(0)!,
    );
    result = result.replaceAllMapped(
      RegExp(
        '''(setProperty\\s*\\(\\s*(["'])min-height\\2\\s*,\\s*(["']))([^"']*?)(\\3\\s*\\))''',
        caseSensitive: false,
      ),
      (m) =>
          RegExp(
            r'\b\d+(?:\.\d+)?vh\b',
            caseSensitive: false,
          ).hasMatch(m.group(4)!)
          ? '${m.group(1)}${convert(m.group(4)!)}${m.group(5)}'
          : m.group(0)!,
    );
    return result;
  }

  static String _trim(double value) {
    final text = value.toStringAsFixed(4);
    return text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
  }

  /// Third-party libraries 酒馆助手 preloads for front-end blocks. Pages
  /// written for it expect `$` and `_` to exist and Font Awesome icons to
  /// show. Vue, jQuery UI and Tailwind are not preloaded.
  static const frontendScripts = [
    'https://testingcf.jsdelivr.net/npm/lodash@4/lodash.min.js',
    'https://testingcf.jsdelivr.net/npm/jquery@3/dist/jquery.min.js',
  ];
  static const frontendStyles = [
    'https://testingcf.jsdelivr.net/npm/@fortawesome/fontawesome-free@6/css/all.min.css',
  ];

  /// The content-security policy of a block. Only TLS network access, no
  /// plugins, no `<base>` rewriting, no form submission. Front-end blocks may
  /// run their own and remote scripts; fragments may run only the host's
  /// nonce-tagged runtime.
  static String policy(HtmlBlockKind kind, String nonce) => switch (kind) {
    HtmlBlockKind.frontend =>
      "default-src https: wss: data: blob: 'unsafe-inline' 'unsafe-eval'; "
          "object-src 'none'; base-uri 'none'; form-action 'none'",
    HtmlBlockKind.fragment =>
      "default-src https: data: blob: 'unsafe-inline'; "
          "script-src 'nonce-$nonce'; object-src 'none'; base-uri 'none'; "
          "form-action 'none'; frame-src 'none'; connect-src 'none'",
  };

  /// The full page loaded into the web view. Mirrors 酒馆助手's `srcdoc`:
  /// reset styles, the viewport variable, the runtime, then the content as
  /// the body. A block that is itself a complete document nests inside the
  /// body, which browsers accept, as SillyTavern relies on.
  static String document({
    required HtmlBlock block,
    required String runtime,
    required Map<String, dynamic> state,
    required String nonce,
    double viewportHeight = 800,
    bool libraries = true,
    String baseStyle = '',
  }) {
    final frontend = block.kind == HtmlBlockKind.frontend;
    final content = frontend
        ? rewriteViewportUnits(block.source)
        : sanitizeFragment(block.source);
    final stateJson = jsonEncode({...state, 'api': frontend})
        .replaceAll('</', r'<\/')
        .replaceAll('<!--', r'<\!--');
    final scripts = frontend && libraries
        ? frontendScripts
              .map((url) => '<script src="${_attribute(url)}"></script>')
              .join('\n')
        : '';
    final styles = frontend && libraries
        ? frontendStyles
              .map((url) => '<link rel="stylesheet" href="${_attribute(url)}">')
              .join('\n')
        : '';
    return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${_attribute(policy(block.kind, nonce))}">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
*,*::before,*::after{box-sizing:border-box;}
html,body{margin:0!important;padding:0;overflow:hidden!important;max-width:100%!important;}
html{--TH-viewport-height:${viewportHeight.round()}px;}
$baseStyle
</style>
<script nonce="$nonce">window.__SD_STATE=$stateJson;</script>
<script nonce="$nonce">$runtime</script>
$styles
$scripts
</head>
<body>
$content
</body>
</html>
''';
  }

  static String _attribute(String value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(value);

  /// A nonce for the runtime scripts of one document.
  static String nonce([Random? random]) {
    final r = random ?? Random.secure();
    return base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
  }
}
