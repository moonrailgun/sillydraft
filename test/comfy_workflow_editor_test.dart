import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/features/settings/comfy_workflow_editor.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'comfyui_flow_test.dart' show workflow;
import 'support/host.dart';

void main() {
  testWidgets(
    'prompt choices exclude settings and allow custom fields in advanced mode',
    (tester) async {
      ComfyWorkflow? saved;
      final initial = ComfyWorkflow.fromJson({
        ...workflow,
        'nodes': <String, dynamic>{
          ...workflow['nodes'] as Map<String, dynamic>,
          '10': {
            'class_type': 'TextEncodeQwenImage21',
            'inputs': {'prompt': 'scene', 'negative_prompt': 'blur'},
          },
          '11': {
            'class_type': 'KSampler',
            'inputs': {'sampler_name': 'euler', 'scheduler': 'simple'},
          },
          '12': {
            'class_type': 'CustomText',
            'inputs': {'description': 'scene'},
          },
        },
      });
      await tester.pumpWidget(
        testHost(
          SingleChildScrollView(
            child: Form(
              child: ComfyWorkflowEditor(
                initialValue: initial,
                serverUrl: 'http://localhost:8188',
                listWorkflows: () async => [],
                readWorkflow: (_) async => initial.nodes,
                onChange: (value) => saved = value,
              ),
            ),
          ),
        ),
      );
      final prompt = find.byKey(const Key('comfy-prompt-input'));
      await tester.tap(prompt);
      await tester.pumpAndSettle();
      expect(
        find.text('4 · CheckpointLoaderSimple · ckpt_name').hitTestable(),
        findsNothing,
      );
      expect(find.text('11 · KSampler · sampler_name'), findsNothing);
      expect(find.text('11 · KSampler · scheduler'), findsNothing);
      expect(
        find.text('10 · TextEncodeQwenImage21 · negative_prompt'),
        findsNothing,
      );
      expect(find.text('12 · CustomText · description'), findsNothing);
      expect(find.text('6 · CLIPTextEncode · text'), findsWidgets);
      await tester.tap(find.text('10 · TextEncodeQwenImage21 · prompt').last);
      await tester.pumpAndSettle();
      expect(saved!.promptInput, '10.prompt');

      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(prompt);
      await tester.tap(prompt);
      await tester.pumpAndSettle();
      final custom = find.text('12 · CustomText · description').last;
      await tester.ensureVisible(custom);
      await tester.tap(custom);
      await tester.pumpAndSettle();
      expect(saved!.promptInput, '12.description');
      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.text('12 · CustomText · description'), findsOneWidget);
      expect(saved!.promptInput, '12.description');
    },
  );

  testWidgets('loads a named server workflow and keeps it on a failed read', (
    tester,
  ) async {
    final reads = <String>[];
    ComfyWorkflow? saved;
    await tester.pumpWidget(
      testHost(
        SingleChildScrollView(
          child: Form(
            child: ComfyWorkflowEditor(
              serverUrl: 'http://localhost:8188',
              listWorkflows: () async => ['插画 API.json', '画布.json'],
              readWorkflow: (name) async {
                reads.add(name);
                if (name == '画布.json') {
                  throw const FormatException('这是画布格式，请导出 API 格式');
                }
                return workflow['nodes'] as Map<String, dynamic>;
              },
              onChange: (value) => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('获取服务端工作流'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('comfy-server-workflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('插画 API.json').last);
    await tester.pumpAndSettle();
    expect(reads, ['插画 API.json']);
    final prompt = find.byKey(const Key('comfy-prompt-input'));
    await tester.ensureVisible(prompt);
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    await tester.tap(find.text('6 · CLIPTextEncode · text').last);
    await tester.pumpAndSettle();
    expect(saved!.promptInput, '6.text');
    expect(saved!.outputNode, '9');
    expect(saved!.filename, '插画 API.json');
    final previous = saved;
    await tester.ensureVisible(find.byKey(const Key('comfy-server-workflow')));
    await tester.tap(find.byKey(const Key('comfy-server-workflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('画布.json').last);
    await tester.pumpAndSettle();
    expect(find.text('这是画布格式，请导出 API 格式'), findsOneWidget);
    expect(saved, same(previous));
    expect(reads, ['插画 API.json', '画布.json']);
  });

  testWidgets(
    'explains an empty server list and ignores reads after disposal',
    (tester) async {
      final pending = Completer<List<String>>();
      var calls = 0;
      await tester.pumpWidget(
        testHost(
          Form(
            child: ComfyWorkflowEditor(
              serverUrl: 'http://localhost:8188',
              listWorkflows: () =>
                  calls++ == 0 ? Future.value([]) : pending.future,
              readWorkflow: (_) async => throw StateError('No file selected'),
              onChange: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('获取服务端工作流'));
      await tester.pumpAndSettle();
      expect(find.textContaining('workflows 目录中没有 JSON 工作流'), findsOneWidget);
      await tester.tap(find.text('获取服务端工作流'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(['late.json']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing servers keeps the draft and ignores the old response', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    Widget editor(String url) => testHost(
      SingleChildScrollView(
        child: Form(
          child: ComfyWorkflowEditor(
            serverUrl: url,
            listWorkflows: () => pending.future,
            readWorkflow: (_) async => throw StateError('No file selected'),
            onChange: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(editor('http://localhost:8188'));
    expect(
      find.byKey(const Key('comfy-workflow-json')).hitTestable(),
      findsNothing,
    );
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('comfy-workflow-json')),
      'unfinished workflow',
    );
    await tester.tap(find.text('获取服务端工作流'));
    await tester.pump();
    await tester.pumpWidget(editor('http://localhost:18188'));
    pending.complete(['old-server.json']);
    await tester.pumpAndSettle();
    expect(find.text('unfinished workflow'), findsOneWidget);
    expect(find.byKey(const Key('comfy-server-workflow')), findsNothing);
    expect(find.text('获取服务端工作流'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reference inputs are chosen in order and can be removed', (
    tester,
  ) async {
    ComfyWorkflow? saved;
    final initial = ComfyWorkflow.fromJson({
      ...workflow,
      'nodes': <String, dynamic>{
        ...workflow['nodes'] as Map<String, dynamic>,
        '10': {
          'class_type': 'LoadImage',
          'inputs': {'image': 'a.png'},
        },
        '11': {
          'class_type': 'LoadImage',
          'inputs': {'image': 'b.png'},
        },
      },
    });
    await tester.pumpWidget(
      testHost(
        SingleChildScrollView(
          child: Form(
            child: ComfyWorkflowEditor(
              initialValue: initial,
              edit: true,
              serverUrl: 'http://localhost:8188',
              listWorkflows: () async => [],
              readWorkflow: (_) async => initial.nodes,
              onChange: (value) => saved = value,
            ),
          ),
        ),
      ),
    );
    Future<void> add(String label) async {
      final select = find.byKey(const Key('comfy-edit-image-input'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await add('10 · LoadImage · image');
    await add('11 · LoadImage · image');
    expect(saved!.imageInputs, ['10.image', '11.image']);
    await tester.tap(find.bySemanticsLabel('移除参考图输入').first);
    await tester.pumpAndSettle();
    expect(saved!.imageInputs, ['11.image']);
    // The edit workflow keeps its own model: no model input to bind.
    expect(saved!.modelInput, isEmpty);
    await tester.ensureVisible(find.text('高级设置'));
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('模型输入（可选）'), findsNothing);
  });
}
