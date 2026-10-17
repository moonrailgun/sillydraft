import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/task_screen.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

ModelConnection remote() => ModelConnection(
  id: 'remote',
  name: '个人执行器',
  baseUrl: 'https://runner.example',
  model: 'writer',
  protocol: ModelProtocol.sillyDraftRunner,
);

class _Remote implements RemoteJobControl, ModelProvider {
  _Remote(this.config, this.complete);
  @override
  final ModelConnection config;
  final bool complete;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if (!complete) throw const ProviderException('remote_offline', '连接中断');
    yield const TextDelta('取回的正文候选');
    yield const GenerationFinished('stop');
  }

  @override
  Future<void> cancelRemote(String executionId) async {}
  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => ['writer'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
}

void main() {
  test('services select remote adapters and keep editor tools on a direct connection', () async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    await services.saveConnection(remote(), apiKey: 'remote-test-access-token');
    final text = await services.provider(remote());
    final image = await services.imageProvider(remote());
    addTearDown(text.close);
    addTearDown(image.close);
    expect(text, isA<RemoteModelProvider>());
    expect(image, isA<RemoteImageProvider>());
    expect(await services.connectionFor('editor'), isNull);
    final direct = ModelConnection(
      id: 'direct',
      name: '编辑模型',
      baseUrl: 'http://localhost:1/v1',
      model: 'editor',
    );
    await services.saveConnection(direct);
    expect((await services.connectionFor('editor'))!.id, direct.id);
    expect((await services.connectionFor('writing'))!.id, remote().id);
  });

  testWidgets(
    'editing a remote connection retains its protocol and secure token',
    (tester) async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await services.saveConnection(
        remote(),
        apiKey: 'remote-test-access-token',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            Builder(
              builder: (context) => AppScaffold(
                child: FButton(
                  onPress: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => ConnectionDialog(connection: remote()),
                  ),
                  child: const Text('配置'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('配置'));
      await tester.pumpAndSettle();
      expect(find.text('访问令牌'), findsOneWidget);
      expect(find.text('服务端模型配置 ID'), findsOneWidget);
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      expect(
        (await services.connections()).single.protocol,
        ModelProtocol.sillyDraftRunner,
      );
      expect(
        await services.secrets.read('model/remote'),
        'remote-test-access-token',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'task screen retrieves the original remote task without applying prose',
    (tester) async {
      var complete = false;
      final repo = StoryRepository.memory();
      final services = AppServices(
        repository: repo,
        secrets: MemorySecrets(),
        modelProviderFactory: (c) async => _Remote(c, complete),
      );
      addTearDown(services.close);
      final novel = await repo.createNovel(title: '恢复远程结果');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('作者原稿'),
      );
      final task = await services.writing.generate(
        branchId: chapter.branchId,
        chapterId: chapter.id,
        connection: remote(),
        brief: '续写',
      );
      expect((await services.runner.wait(task.id)).status, TaskStatus.failed);
      complete = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(TaskScreen(taskId: task.id)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('获取远程结果'));
      await tester.pumpAndSettle();
      expect(find.text('处理未写入的正文'), findsOneWidget);
      expect(
        (await repo.listTasks(branchId: chapter.branchId)).single.id,
        task.id,
      );
      expect(
        (await repo.getChapter(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '作者原稿',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
