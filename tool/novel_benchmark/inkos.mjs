import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const [checkout, fixturePath, storyId, outputPath, baseUrl] = process.argv.slice(2);
assert(baseUrl, 'Usage: inkos-checkout fixture.json story-id output-dir base-url');
const moduleAt = (path) => import(pathToFileURL(join(resolve(checkout), 'packages/core/dist', path)));
const { PipelineRunner } = await moduleAt('pipeline/runner.js');
const { StateManager } = await moduleAt('state/manager.js');
const { createLLMClient } = await moduleAt('llm/provider.js');
const { loadAvailableAgentSkills, resolveProfileSkillActivations } = await moduleAt('skills/index.js');
const { createBuiltInWorkProfileRegistry } = await moduleAt('harness/builtin-profiles.js');
const { chapterDocumentBody } = await moduleAt('utils/chapter-document.js');
const { createLogger, createStderrSink } = await moduleAt('utils/logger.js');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const story = fixture.stories.find(s => s.id === storyId);
assert(story?.chapters.length === 16);
const output = resolve(outputPath);
await mkdir(output, { recursive: true });
const snapshot = JSON.stringify(fixture);
const existing = await readFile(join(output, 'fixture.json'), 'utf8').catch(e => { if (e.code !== 'ENOENT') throw e; });
assert(!existing || snapshot === existing, 'Fixture changed; use a new run directory');
await writeFile(join(output, 'fixture.json'), snapshot);
const bible = [
  `书名：${story.title}\n题材：${story.genre}`, `文风：${story.style}`,
  `作者设定：${story.bible}`, '以下是未来创作计划，不能当作已发生的事实：',
  ...story.chapters.map((g, i) => `第${i + 1}章：${g}`),
].join('\n\n');
const config = { service: 'custom', provider: 'openai', configSource: 'studio',
  model: fixture.writer, apiKey: 'magpie', baseUrl, apiFormat: 'chat', stream: true,
  thinkingBudget: 0, temperature: 0.7 };
const pipeline = new PipelineRunner({ projectRoot: output, client: createLLMClient(config),
  model: fixture.writer, defaultLLMConfig: config, externalContext: bible,
  logger: createLogger({ tag: 'benchmark', sinks: [createStderrSink({ minLevel: 'info' })] }) });
const state = new StateManager(output);
const available = await loadAvailableAgentSkills({ projectRoot: output });
const activatedSkills = resolveProfileSkillActivations(available.skills, createBuiltInWorkProfileRegistry().require('longform-novel'));
assert(activatedSkills.length > 0, 'Native longform skills missing');
await pipeline.runWithAgentContext({ activatedSkills }, async () => {
  if (!await state.isCompleteBookDirectory(state.bookDir(story.id))) {
    const now = new Date().toISOString();
    await pipeline.initBook({ id: story.id, title: story.title, genre: story.genre,
      platform: 'other', status: 'outlining', targetChapters: 16,
      chapterWordCount: fixture.chapterCharacters, language: 'zh', createdAt: now, updatedAt: now },
      { externalContext: bible, authorIntent: bible });
  }
  let next = await state.getNextChapterNumber(story.id);
  for (; next <= 16; next++) {
    console.log(`${new Date().toISOString()} writing ${next}`);
    const [result] = await pipeline.writeChapters(story.id, 1, { startChapterNumber: next,
      wordCount: fixture.chapterCharacters,
      externalContext: `${bible}\n\n本次只写第${next}章：${story.chapters[next - 1]}\n目标 ${fixture.chapterCharacters} 汉字（不含标点），写成完整场景，不要用提纲概述替代正文，不提前写后续章。` });
    await writeFile(join(output, `${String(next).padStart(2, '0')}.json`), JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  }
});
const chapterDirectory = join(state.bookDir(story.id), 'chapters');
const chapterIndex = await state.loadChapterIndex(story.id);
for (const file of await readdir(chapterDirectory)) {
  const match = /^(\d+)_.*\.md$/.exec(file);
  if (!match) continue;
  const document = await readFile(join(chapterDirectory, file), 'utf8');
  const number = Number(match[1]);
  const chapter = chapterIndex.find(c => c.number === number);
  assert(chapter, `Missing chapter metadata: ${number}`);
  await writeFile(join(output, `${String(number).padStart(2, '0')}.txt`), chapterDocumentBody(document, number, chapter.title, 'zh'));
}
assert(chapterIndex.length === 16, 'Book incomplete');
