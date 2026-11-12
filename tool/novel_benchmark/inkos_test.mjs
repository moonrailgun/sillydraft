import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// An initialized work must export unchanged without reinitializing or inference.
const checkout = resolve(process.argv[2]);
const { StateManager } = await import(pathToFileURL(join(checkout, 'packages/core/dist/state/manager.js')));
const here = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(here, 'fixtures.json');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const story = fixture.stories[0];
const root = await mkdtemp(join(tmpdir(), 'inkos-benchmark-resume-'));
try {
  const state = new StateManager(root);
  const bookDir = state.bookDir(story.id);
  const now = '2026-11-05T00:00:00.000Z';
  await state.saveBookConfig(story.id, { id: story.id, title: story.title,
    genre: story.genre, platform: 'other', status: 'active', targetChapters: 16,
    chapterWordCount: 2000, language: 'zh', createdAt: now, updatedAt: now });
  const originals = new Map();
  for (const file of ['story/outline/story_frame.md', 'story/outline/volume_map.md',
    'story/book_rules.md', 'story/current_state.md', 'story/pending_hooks.md']) {
    const path = join(bookDir, file);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, '保留已有设定。\n');
    originals.set(path, '保留已有设定。\n');
  }
  await mkdir(join(bookDir, 'chapters'), { recursive: true });
  const index = [];
  for (let number = 1; number <= 16; number++) {
    index.push({ number, title: '旧章', wordCount: 5, createdAt: now, updatedAt: now,
      observations: [], provenance: 'generated' });
    const path = join(bookDir, 'chapters', `${String(number).padStart(4, '0')}_旧章.md`);
    const content = `# 第${number}章 旧章\n\n原有正文${number}。\n`;
    await writeFile(path, content);
    originals.set(path, content);
  }
  await writeFile(join(bookDir, 'chapters/index.json'), JSON.stringify(index));
  for (const path of [join(bookDir, 'book.json'), join(bookDir, 'chapters/index.json'),
    join(root, 'works', story.id, 'work.json')]) {
    originals.set(path, await readFile(path, 'utf8'));
  }
  const result = spawnSync(process.execPath, [join(here, 'inkos.mjs'), checkout,
    fixturePath, story.id, root, 'http://127.0.0.1:1/v1'], { encoding: 'utf8', timeout: 15000 });
  assert.equal(result.status, 0, result.stderr);
  for (const [path, content] of originals) assert.equal(await readFile(path, 'utf8'), content);
  for (let number = 1; number <= 16; number++) {
    assert.equal(await readFile(join(root, `${String(number).padStart(2, '0')}.txt`), 'utf8'), `原有正文${number}。\n`);
  }
  console.log('PASS: initialized work resumes without rewriting source or model calls');
} finally {
  await rm(root, { recursive: true, force: true });
}
