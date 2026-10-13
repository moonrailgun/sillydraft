import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/agent/proposal_screen.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/features/reader/reader_document.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

Widget host(AppServices services, Widget page) => ProviderScope(
  overrides: [servicesProvider.overrideWithValue(services)],
  child: testHost(page),
);

void main() {
  test('list markers preserve canonical bookmark and search positions', () {
    final content = ManuscriptContent.fromDelta([
      {'insert': '第一项'},
      {
        'insert': '\n',
        'attributes': {'list': 'ordered'},
      },
      {'insert': '第二项'},
      {
        'insert': '\n',
        'attributes': {'list': 'ordered'},
      },
    ]);
    final shown = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 20,
      image: (_) => const SizedBox(),
    );
    final display = shown.span.toPlainText();
    expect(display, '1. 第一项\n2. 第二项\n');
    expect(
      shown.sourceOffset(display.indexOf('第二项')),
      content.text.indexOf('第二项'),
    );
    expect(
      shown.sourceOffset(shown.displayOffset(content.text.indexOf('第二项'))),
      content.text.indexOf('第二项'),
    );
  });

  testWidgets(
    'reader renders canonical headings, ordered and bullet lists, and quotes',
    (tester) async {
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
      final novel = await repo.createNovel(title: '格式阅读');
      final content = ManuscriptContent.fromDelta([
        {'insert': '标题'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': '第一项'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': '第二项'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': '无序项'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'},
        },
        {'insert': '引用'},
        {
          'insert': '\n',
          'attributes': {'blockquote': true},
        },
      ]);
      await repo.createChapter(
        branchId: novel.activeBranchId,
        content: content,
      );
      await tester.pumpWidget(
        host(services, ReaderScreen(branchId: novel.activeBranchId)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1. 第一项\n2. 第二项\n• 无序项\n│ 引用', findRichText: true),
        findsWidgets,
      );
      final rich = tester
          .widgetList<Text>(find.byType(Text))
          .where((w) => w.textSpan?.toPlainText().startsWith('标题') == true)
          .single;
      final heading = (rich.textSpan! as TextSpan).children!.first as TextSpan;
      expect(heading.style?.fontWeight, FontWeight.bold);
      expect(heading.style?.fontSize, greaterThan(20));
      expect(
        (await repo.getStory(novel.activeBranchId)).chapters.single.content,
        content,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'display rules reach candidate and reader while accepted and exported prose stays canonical',
    (tester) async {
      final repo = StoryRepository.memory();
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('sillydraft-display-'),
      ))!;
      final services = AppServices(
        repository: repo,
        secrets: MemorySecrets(),
        dataDirectory: dir,
      );
      addTearDown(() async {
        await services.close();
        await dir.delete(recursive: true);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
      final novel = await repo.createNovel(title: '显示正则');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('之前正文'),
      );
      final task = await repo.createTask(
        branchId: chapter.branchId,
        chapterId: chapter.id,
        baseRevisionId: chapter.revisionId,
        kind: TaskKind.writing,
        input: {
          'clock': '2026-01-01T00:00:00Z',
          'seed': 1,
          'macroValues': {'char': '阿雾'},
          'outputRegex': [
            {
              'findRegex': '/暗号/g',
              'replaceString': '{{char}}的来信',
              'placement': [2],
              'markdownOnly': true,
            },
          ],
        },
      );
      await repo.updateTask(task.id, status: TaskStatus.running);
      await repo.completeWritingTask(
        task.id,
        content: ManuscriptContent.plainText('暗号到了。'),
        rawText: '暗号到了。',
      );
      final proposal = (await repo.listProposals(chapter.branchId)).single;
      await tester.pumpWidget(
        host(services, ProposalScreen(proposalId: proposal.id)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('阿雾的来信到了。', findRichText: true), findsWidgets);
      await tester.tap(find.text('预览显示效果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暗号到了。', findRichText: true), findsWidgets);
      await tester.tap(find.text('预览显示效果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采纳到正文'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        host(services, ReaderScreen(branchId: chapter.branchId)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('阿雾的来信到了。', findRichText: true), findsWidgets);
      expect(
        (await repo.getChapter(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        )).content.text,
        '暗号到了。\n',
      );
      expect((await repo.getTask(task.id)).partialText, '暗号到了。');
      final exported = (await tester.runAsync(
        () => PublicationExporter(
          repository: repo,
          assets: services.assets!,
        ).export(branchId: chapter.branchId, format: PublicationFormat.text),
      ))!;
      expect(utf8.decode(exported.bytes), contains('暗号到了。'));
      expect(utf8.decode(exported.bytes), isNot(contains('阿雾的来信')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
