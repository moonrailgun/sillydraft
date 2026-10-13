import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('two devices pull, push, preserve concurrent edits and resolve only the observed remote revision', () async {
    final dir = await Directory.systemTemp.createTemp('sillydraft-sync-');
    final a = StoryRepository.open('${dir.path}/a.sqlite'),
        b = StoryRepository.open('${dir.path}/b.sqlite');
    final remote = MemoryRemote();
    addTearDown(() async {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    });
    ProjectSync device(StoryRepository repo, String name) => ProjectSync(
      repository: repo,
      backup: ProjectBackup(
        repository: repo,
        assets: AssetLibrary(
          repository: repo,
          directory: Directory('${dir.path}/$name-assets'),
        ),
        resources: ResourceLibrary(
          repository: repo,
          keyProvider: () async => List.filled(32, name == 'a' ? 1 : 2),
        ),
      ),
      transport: remote,
      passphrase: 'our shared backup passphrase',
    );
    final sa = device(a, 'a'), sb = device(b, 'b');
    final novel = await a.createNovel(title: '同步小说');

    final chapter = await a.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('初稿'),
    );
    expect((await sa.synchronize(novel.id)).action, SyncAction.uploaded);
    final imported = await sb.connect();
    expect(imported.id, novel.id);
    Future<void> edit(StoryRepository repo, String text) async {
      final s = await repo.getChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      );
      await repo.saveChapter(
        branchId: s.branchId,
        chapterId: s.id,
        expectedRevisionId: s.revisionId,
        content: ManuscriptContent.plainText(text),
      );
    }

    await edit(a, '甲设备修改');
    expect((await sa.synchronize(novel.id)).action, SyncAction.uploaded);
    expect((await sb.synchronize(novel.id)).action, SyncAction.downloaded);
    expect((await b.getStory(chapter.branchId)).text.trim(), '甲设备修改');
    await edit(a, '甲设备同时修改');
    await edit(b, '乙设备同时修改');
    await sa.synchronize(novel.id);
    final conflict = await sb.synchronize(novel.id);
    expect(conflict.action, SyncAction.conflict);
    expect(conflict.conflictNovelId, isNotNull);
    expect((await b.getStory(chapter.branchId)).text.trim(), '乙设备同时修改');
    final copy = await b.getNovel(conflict.conflictNovelId!);
    expect((await b.getStory(copy.activeBranchId)).text.trim(), '甲设备同时修改');
    expect((await sb.synchronize(novel.id)).conflictNovelId, copy.id);
    expect((await b.listNovels()).length, 2);
    await edit(a, '又一笔远端修改');
    await sa.synchronize(novel.id);
    await expectLater(
      sb.resolveWithLocal(novel.id, observedEtag: conflict.remoteEtag!),
      throwsA(isA<ProjectConflict>()),
    );
    final fresh = await sb.synchronize(novel.id);
    expect((await b.listNovels()).length, 3);
    expect(
      (await sb.resolveWithLocal(
        novel.id,
        observedEtag: fresh.remoteEtag!,
      )).action,
      SyncAction.uploaded,
    );
    expect((await sa.synchronize(novel.id)).action, SyncAction.downloaded);
    expect((await a.getStory(chapter.branchId)).text.trim(), '乙设备同时修改');
    await edit(a, '采用的远端结尾');
    await edit(b, '仍须保留的本机结尾');
    await sa.synchronize(novel.id);
    final nextConflict = await sb.synchronize(novel.id);
    final remoteChoice = await sb.resolveWithRemote(
      novel.id,
      observedEtag: nextConflict.remoteEtag!,
    );
    expect((await b.getStory(chapter.branchId)).text.trim(), '采用的远端结尾');
    final localCopy = await b.getNovel(remoteChoice.conflictNovelId!);
    expect(
      (await b.getStory(localCopy.activeBranchId)).text.trim(),
      '仍须保留的本机结尾',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('HTTP sync enforces conditional writes, requires strong ETags, and never follows authenticated redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Uint8List? value;
    String? etag;
    bool redirect = false, weak = false;
    final conditions = <String?>[];
    server.listen((r) async {
      expect(r.headers.value('authorization'), 'Bearer sync-test');
      if (redirect) {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'http://example.invalid/steal');
        await r.response.close();
        return;
      }
      if (r.method == 'GET') {
        if (value == null) {
          r.response.statusCode = 404;
        } else {
          r.response.headers.set('etag', weak ? 'W/$etag' : etag!);
          r.response.add(value!);
        }
      } else {
        final match = r.headers.value('if-match'),
            none = r.headers.value('if-none-match');
        conditions.add(match ?? none);
        if ((value == null && none == '*') || (etag != null && match == etag)) {
          final builder = BytesBuilder();
          await for (final chunk in r) {
            builder.add(chunk);
          }
          value = builder.takeBytes();
          etag = '"${sha256.convert(value!)}"';
          r.response.headers.set('etag', etag!);
          r.response.statusCode = 201;
        } else {
          r.response.statusCode = 412;
        }
      }
      await r.response.close();
    });
    final transport = HttpSnapshotTransport(
      url: Uri.parse('http://127.0.0.1:${server.port}/project.sillydraft'),
      authorization: 'Bearer sync-test',
    );
    addTearDown(transport.close);
    expect(await transport.read(), isNull);
    final first = await transport.write(
      Uint8List.fromList([1, 2, 3]),
      expectedEtag: null,
    );
    expect((await transport.read())!.etag, first);
    await expectLater(
      transport.write(Uint8List.fromList([4]), expectedEtag: '"old"'),
      throwsA(isA<ProjectConflict>()),
    );
    expect((await transport.read())!.bytes, [1, 2, 3]);
    expect(conditions, ['*', '"old"']);
    weak = true;
    await expectLater(transport.read(), throwsFormatException);
    weak = false;
    redirect = true;
    await expectLater(transport.read(), throwsFormatException);
  });
}

class MemoryRemote implements SnapshotTransport {
  RemoteSnapshot? current;
  @override
  Future<RemoteSnapshot?> read() async => current;
  @override
  Future<String> write(Uint8List bytes, {required String? expectedEtag}) async {
    if (current?.etag != expectedEtag) throw const ProjectConflict();
    final etag = '"${sha256.convert(bytes)}"';
    current = RemoteSnapshot(etag: etag, bytes: bytes);
    return etag;
  }

  @override
  void close() {}
}
