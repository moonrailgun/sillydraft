import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

final class _VariableReadGate extends QueryInterceptor {
  Future<void> Function()? afterRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String sql,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(sql, args);
    if (sql.startsWith('SELECT * FROM variable_revisions') &&
        afterRead != null) {
      final callback = afterRead!;
      afterRead = null;
      await callback();
    }
    return rows;
  }
}

void main() {
  late StoryRepository first;
  late StoryRepository second;
  late _VariableReadGate gate;
  late String branchId;
  late Chapter chapter;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp(
      'sillydraft-variable-patch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/library.sqlite');
    gate = _VariableReadGate();
    first = StoryRepository.connect(
      NativeDatabase.createInBackground(file).interceptWith(gate),
    );
    addTearDown(first.close);
    final novel = await first.createNovel(title: '变量');
    branchId = novel.activeBranchId;
    chapter = await first.createChapter(
      branchId: branchId,
      content: ManuscriptContent.plainText('正文'),
    );
    second = StoryRepository.open(file.path);
    addTearDown(second.close);
  });

  for (final patchLocal in [false, true]) {
    test(
      'patching ${patchLocal ? 'local' : 'global'} variables detects a concurrent write to the other table',
      () async {
        await first.setBranchVariables(
          branchId: branchId,
          chapterId: chapter.id,
          expectedVersion: 0,
          local: {'local': 'old'},
          global: {'global': 'old'},
        );
        gate.afterRead = () async {
          await second.setBranchVariables(
            branchId: branchId,
            chapterId: chapter.id,
            expectedVersion: 1,
            local: {'local': patchLocal ? 'old' : 'concurrent'},
            global: {'global': patchLocal ? 'concurrent' : 'old'},
          );
        };

        await expectLater(
          first.patchBranchVariables(
            branchId: branchId,
            chapterId: chapter.id,
            local: patchLocal ? {'local': 'patch'} : null,
            global: patchLocal ? null : {'global': 'patch'},
          ),
          throwsA(isA<VariableConflict>()),
        );
        final current = await first.getBranchVariables(branchId);
        expect(current.version, 2);
        expect(current.local, {'local': patchLocal ? 'old' : 'concurrent'});
        expect(current.global, {'global': patchLocal ? 'concurrent' : 'old'});
      },
    );
  }

  for (final mvu in [true, false]) {
    test(
      '${mvu ? 'MVU update' : 'HTML variable write'} detects concurrent changes to preserved local fields',
      () async {
        await first.setBranchVariables(
          branchId: branchId,
          chapterId: chapter.id,
          expectedVersion: 0,
          local: {
            'keep': 'old',
            ...MvuData(statData: {'score': 1}).toStored(),
          },
        );
        final backend = BranchChatBackend(
          repository: first,
          branchId: branchId,
          context: await first.displayContext(branchId),
        );
        gate.afterRead = () async {
          await second.setBranchVariables(
            branchId: branchId,
            chapterId: chapter.id,
            expectedVersion: 1,
            local: {
              'keep': 'concurrent',
              ...MvuData(statData: {'score': 2}).toStored(),
            },
          );
        };

        await expectLater(
          mvu
              ? MvuService(first).replaceAt(
                  branchId,
                  chapter.id,
                  MvuData(statData: {'score': 3}),
                )
              : backend.replaceVariables(
                  {'seen': true},
                  {'type': 'message', 'message_id': 0},
                  messageId: 0,
                ),
          throwsA(isA<VariableConflict>()),
        );
        final current = await first.getBranchVariables(branchId);
        expect(current.version, 2);
        expect(current.local['keep'], 'concurrent');
        expect(MvuData.fromStored(current.local)!.statData, {'score': 2});
        expect(current.local.containsKey('seen'), isFalse);
      },
    );
  }
}
