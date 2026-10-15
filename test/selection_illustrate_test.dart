import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

class _ReplyProvider implements ModelProvider {
  _ReplyProvider(this.config, this.script);
  @override
  final ModelConnection config;

  /// Replies used in turn, one per request, before the plain answer.
  final List<List<ProviderEvent>> script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if (script.isNotEmpty) {
      yield* Stream.fromIterable(script.removeAt(0));
      return;
    }
    yield const TextDelta('好的');
    yield const GenerationFinished('stop');
  }

  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
}

final _both = ModelConnection(
  id: 'm',
  name: '文本与生图',
  baseUrl: 'http://localhost:1/v1',
  model: 'm',
);

Future<(AppServices, Chapter)> _book({
  bool configured = true,
  List<List<ProviderEvent>>? script,
}) async {
  script ??= [];
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async => _ReplyProvider(c, script!),
  );
  if (configured) await services.saveConnection(_both);
  final novel = await services.repository.createNovel(title: '雾港');
  final chapter = await services.repository.createChapter(
    branchId: novel.activeBranchId,
    title: '渡口',
    content: ManuscriptContent.plainText('雨中的渡口，她撑着红伞🌂走过石桥/回头看了一眼。' * 6),
  );
  return (services, chapter);
}

Future<void> _pump(
  WidgetTester tester,
  AppServices services,
  Widget home,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(home),
    ),
  );
  // Unmount before services close, so the reader's drafts flush in time.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

/// Drags the mouse across the first three lines of the chapter text.
Future<void> _select(WidgetTester tester) async {
  final text = tester.getRect(
    find.textContaining('雨中的渡口', findRichText: true).last,
  );
  final mouse = await tester.startGesture(
    text.topLeft + const Offset(1, 10),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await mouse.moveTo(text.topLeft + Offset(text.width / 2, 100));
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
}

CupertinoTextSelectionToolbarButton _drawButton(WidgetTester tester) =>
    tester.widget(
      find.ancestor(
        of: find.text('生图'),
        matching: find.byType(CupertinoTextSelectionToolbarButton),
      ),
    );

void main() {
  testWidgets('selecting with the mouse offers 生图 and highlights whole lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (services, chapter) = await _book();
    addTearDown(services.close);
    (Chapter, String)? drawn;
    await _pump(
      tester,
      services,
      ReaderScreen(
        branchId: chapter.branchId,
        onIllustrate: (c, text) => drawn = (c, text),
      ),
    );
    await tester.pumpAndSettle();
    await _select(tester);

    // The test app runs in English; the platform's own items stay.
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('生图'), findsOneWidget);

    // Every highlighted line is one full line tall, and lines meet.
    final painter = tester
        .renderObjectList<RenderCustomPaint>(find.byType(CustomPaint))
        .firstWhere(
          (r) => r.painter.runtimeType.toString() == '_LineSelectionPainter',
        );
    final rects = <Rect>[];
    expect(
      painter,
      paints..everything((method, args) {
        if (method == #drawRect && (args[1] as Paint).color.a > 0) {
          rects.add(args[0] as Rect);
        }
        return true;
      }),
    );
    final lines = {for (final r in rects) r.top: r}.values.toList()
      ..sort((a, b) => a.top.compareTo(b.top));
    expect(lines.length, greaterThan(1));
    for (final r in rects) {
      expect(r.height, moreOrLessEquals(lines.first.height));
    }
    for (var i = 1; i < lines.length; i++) {
      expect(lines[i].top, moreOrLessEquals(lines[i - 1].bottom));
    }

    // The menu is a bubble above the selection, not over it.
    final selectedTop = painter.localToGlobal(lines.first.topLeft).dy;
    expect(
      tester.getRect(find.byType(CupertinoTextSelectionToolbarButton).first),
      isA<Rect>().having((r) => r.bottom, 'bottom', lessThan(selectedTop)),
    );

    await tester.tap(find.text('生图'));
    await tester.pumpAndSettle();
    expect(drawn?.$1.id, chapter.id);
    expect(drawn?.$2, startsWith('雨中的渡口'));
    expect(find.text('生图'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the menu bubble follows the page, not the system', (
    tester,
  ) async {
    final (services, chapter) = await _book();
    addTearDown(services.close);
    await _pump(
      tester,
      services,
      ReaderScreen(branchId: chapter.branchId, onIllustrate: (_, _) {}),
    );
    await tester.pumpAndSettle();
    double bubble() => tester
        .widget<ColoredBox>(
          find.descendant(
            of: find.byType(CupertinoTextSelectionToolbar),
            matching: find.byType(ColoredBox),
          ),
        )
        .color
        .computeLuminance();

    await _select(tester);
    expect(bubble(), greaterThan(.5));

    await tester.tap(findAction('夜间'));
    await tester.pumpAndSettle();
    await _select(tester);
    expect(bubble(), lessThan(.1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('生图 is greyed out until an image engine is configured', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (services, chapter) = await _book(configured: false);
    addTearDown(services.close);
    await services.saveConnection(
      ModelConnection(
        id: 't',
        name: '只有文本',
        baseUrl: 'http://localhost:1/v1',
        model: 't',
        kind: ModelKind.text,
      ),
    );
    await _pump(
      tester,
      services,
      ReaderScreen(branchId: chapter.branchId, onIllustrate: (_, _) {}),
    );
    await tester.pumpAndSettle();
    await _select(tester);
    expect(_drawButton(tester).onPressed, isNull);

    await services.saveConnection(_both);
    await tester.pumpAndSettle();
    await _select(tester);
    expect(_drawButton(tester).onPressed, isNotNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the assistant sends a selection with its chapter and shows '
      'the drawn image', (tester) async {
    final (services, chapter) = await _book();
    addTearDown(services.close);
    final repo = services.repository;
    await _pump(
      tester,
      services,
      AppScaffold(
        child: AgentPanel(
          branchId: chapter.branchId,
          request: AgentRequest('为这段正文生成一张插图：她撑着红伞', chapterId: chapter.id),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final conversation =
        (await repo.listConversations(chapter.branchId)).single['id'] as String;
    final user = (await repo.getAgentMessages(conversation))
        .firstWhere((m) => m.role == 'user');
    expect(user.content, '为这段正文生成一张插图：她撑着红伞');
    expect(user.raw['attachment'], containsPair('chapterId', chapter.id));
    expect(find.text('附：渡口'), findsOneWidget);

    await repo.appendAgentMessage(
      conversation,
      role: 'tool',
      content: jsonEncode({
        'taskId': 't',
        'status': 'completed',
        'assetId': 'a1',
      }),
      metadata: {'tool_call_id': 'c', 'tool_name': 'generate_image'},
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('agent-image-a1')), findsOneWidget);
  });

  testWidgets('the assistant draws only after the author confirms', (
    tester,
  ) async {
    List<ProviderEvent> draw(String prompt) => [
      ToolCallReady(prompt, 'generate_image', {'prompt': prompt, 'name': '渡口'}),
      const GenerationFinished('tool_calls'),
    ];
    final (services, chapter) = await _book(
      script: [draw('雨夜渡口'), draw('红伞少女')],
    );
    addTearDown(services.close);
    Future<int> drawings() async => (await services.repository.listTasks())
        .where((t) => t.kind == TaskKind.illustration)
        .length;
    Finder inCard(Finder f) => find.descendant(
      of: find.byKey(const Key('agent-image-confirmation')),
      matching: f,
    );
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await _pump(
      tester,
      services,
      AppScaffold(
        child: AgentPanel(
          branchId: chapter.branchId,
          request: AgentRequest('画一张', chapterId: chapter.id),
        ),
      ),
    );
    await settle();
    expect(inCard(find.textContaining('雨夜渡口')), findsOneWidget);
    expect(inCard(find.text('文本与生图 · m')), findsOneWidget);
    expect(await drawings(), 0);

    await tester.tap(inCard(find.text('取消')));
    await settle();
    expect(await drawings(), 0);
    expect(find.text('已取消生图'), findsOneWidget);
    expect(inCard(find.textContaining('红伞少女')), findsOneWidget);

    await tester.tap(inCard(find.text('确认生成')));
    await settle();
    expect(await drawings(), 1);
    expect(find.byKey(const Key('agent-image-confirmation')), findsNothing);
  });

  test('a ComfyUI engine shows its workflow file, the model only if bound', () {
    ModelConnection comfy({String modelInput = ''}) => ModelConnection(
      id: 'c',
      name: 'ComfyUI',
      baseUrl: 'http://127.0.0.1:18188',
      model: 'krea.safetensors',
      protocol: ModelProtocol.comfyUI,
      comfyWorkflow: ComfyWorkflow(
        nodes: {
          '1': {
            'class_type': 'CLIPTextEncode',
            'inputs': {'text': ''},
          },
          '2': {
            'class_type': 'UNETLoader',
            'inputs': {'unet_name': 'krea.safetensors'},
          },
          '3': {
            'class_type': 'SaveImage',
            'inputs': {
              'images': ['2', 0],
            },
          },
        },
        promptInput: '1.text',
        outputNode: '3',
        modelInput: modelInput,
        filename: 'Krea2 Turbo.json',
      ),
    );
    expect(imageEngineLabel(comfy()), 'ComfyUI · Krea2 Turbo.json');
    expect(
      imageEngineLabel(comfy(modelInput: '2.unet_name')),
      'ComfyUI · Krea2 Turbo.json · krea.safetensors',
    );
  });

  testWidgets('the confirmation card shows the reference images chosen', (
    tester,
  ) async {
    final script = <List<ProviderEvent>>[];
    final (services, chapter) = await _book(script: script);
    addTearDown(services.close);
    final portrait = await services.repository.storeAsset(
      branchId: chapter.branchId,
      name: '林岚',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 1,
        height: 1,
        byteLength: 1,
      ),
      purpose: AssetPurpose.reference,
    );
    script.add([
      ToolCallReady('r', 'generate_image', {
        'prompt': '林岚',
        'name': '林岚',
        'references': [portrait.id],
      }),
      const GenerationFinished('tool_calls'),
    ]);
    await _pump(
      tester,
      services,
      AppScaffold(
        child: AgentPanel(
          branchId: chapter.branchId,
          request: AgentRequest('画林岚', chapterId: chapter.id),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(Key('agent-image-reference-${portrait.id}')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  });
}
