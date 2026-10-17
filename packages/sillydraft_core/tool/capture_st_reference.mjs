// Reference generation only. Runs isolated pure functions from pinned ST source;
// never executes card/preset content. Runtime app does not depend on JavaScript.
import fs from 'node:fs/promises';
import vm from 'node:vm';
import {createHash} from 'node:crypto';
const commit = '06bde939fb1e9c4c8d8641d810f0a916b5bce127';
const base = `https://raw.githubusercontent.com/SillyTavern/SillyTavern/${commit}/`;
const source = await (await fetch(base + 'public/scripts/openai.js')).text();
const start = source.indexOf('async function populationInjectionPrompts(');
if (start < 0) throw new Error('Pinned function not found');
const body = source.slice(start, source.indexOf('\n}\n', start) + 3);
const context = vm.createContext({
  extension_prompt_roles: {SYSTEM: 0, USER: 1, ASSISTANT: 2},
  extension_prompt_types: {IN_CHAT: 1},
  getExtensionPromptMaxDepth: () => 100,
  getExtensionPrompt: async () => '',
});
vm.runInContext(body, context, {timeout: 1000});
const injections = [
  {role: 'system', content: 'priority-100-system', injection_depth: 1, injection_order: 100},
  {role: 'user', content: 'priority-100-user', injection_depth: 1, injection_order: 100},
  {role: 'assistant', content: 'priority-100-assistant', injection_depth: 1, injection_order: 100},
  {role: 'system', content: 'priority-200', injection_depth: 1, injection_order: 200},
  {role: 'system', content: 'same-role', injection_depth: 1, injection_order: 100},
  {role: 'system', content: 'depth-zero', injection_depth: 0, injection_order: 100},
  {role: 'system', content: 'deep', injection_depth: 8, injection_order: 100},
];
const messages = [{role:'user',content:'brief'}, {role:'assistant',content:'accepted chapter'}];
const expected = await context.populationInjectionPrompts(structuredClone(injections), structuredClone(messages));
await fs.writeFile('test/fixtures/st/injection-reference.json', JSON.stringify({
  commit, functionSha256: createHash('sha256').update(body).digest('hex'),
  assumptions: ['No extension prompts', 'Input history newest first', 'Maximum injection depth 100'],
  injections, inputNewestFirst: messages, expected,
}, null, 2) + '\n');
console.log('Captured ST injection output:', expected.length, 'messages');

const instructSource = await (await fetch(base + 'public/scripts/instruct-mode.js')).text();
function extract(name) {
  const start = instructSource.indexOf(`export function ${name}(`);
  if (start < 0) throw new Error(`Pinned function missing: ${name}`);
  return instructSource.slice(start, instructSource.indexOf('\n}\n', start) + 3).replace('export ', '');
}
const formatters = ['formatInstructModeStoryString', 'formatInstructModeChat', 'formatInstructModePrompt', 'getInstructStoppingSequences'];
const formattingContext = vm.createContext({
  structuredClone, selected_group: false,
  names_behavior_types: {NONE: 'none', FORCE: 'force', ALWAYS: 'always'},
  force_output_sequence: {FIRST: 1, LAST: 2},
  extension_prompt_types: {IN_PROMPT: 0, IN_CHAT: 1},
  substituteParams: (text) => text,
  name1: '阿雨', name2: '旁白', onlyUnique: (value, index, array) => array.indexOf(value) === index,
  power_user: {context: {use_stop_strings: false}},
});
for (const name of formatters) vm.runInContext(extract(name), formattingContext, {timeout: 1000});
const instruct = JSON.parse(await fs.readFile('test/fixtures/st/instruct/ChatML.json', 'utf8'));
const ctx = JSON.parse(await fs.readFile('test/fixtures/st/context/Default.json', 'utf8'));
// The default template emits "Write a novel\n{{trim}}". ST's documented
// trim postprocessor removes the adjacent newline before formatting.
const renderedStory = 'Write a novel';
const formattedStory = formattingContext.formatInstructModeStoryString(renderedStory, {customContext: ctx, customInstruct: instruct});
const formattedUser = formattingContext.formatInstructModeChat('阿雨', 'brief', true, false, false, '阿雨', '旁白', 1, instruct);
const formattedTail = formattingContext.formatInstructModePrompt('旁白', false, '', '阿雨', '旁白', false, false, instruct);
// script.js `Generate` L5003-5009: before the tail, the last chat line loses
// one trailing newline (not on continue; in instruct mode only with wrap).
const lastLine = instruct.wrap ? formattedUser.replace(/\n?$/, '') : formattedUser;
await fs.writeFile('test/fixtures/st/text-format-reference.json', JSON.stringify({
  commit, assumptions: ['Default story template', 'trim postprocessor applied', 'Single character', 'No examples or macros in sequences', 'Last chat line trimmed as Generate does before the tail'],
  formattedStory, formattedUser, formattedTail,
  stopStrings: formattingContext.getInstructStoppingSequences({customInstruct: instruct, useStopStrings: false}),
  expected: formattedStory + ctx.chat_start + '\n' + lastLine + formattedTail,
}, null, 2) + '\n');
console.log('Captured ST text sequence formatting');

// reasoning_effort for a Custom (OpenAI-compatible) chat completion: the
// client's getReasoningEffort, then the server filter in chat-completions.js.
const constantsSource = await (await fetch(base + 'src/constants.js')).text();
const serverSource = await (await fetch(base + 'src/endpoints/backends/chat-completions.js')).text();
function literal(text, name) {
  const marker = `export const ${name} = `;
  const at = text.indexOf(marker);
  if (at < 0) throw new Error(`Pinned constant missing: ${name}`);
  const from = at + marker.length;
  const end = text.indexOf(text[from] === '[' ? '\n];' : '\n};', from);
  return vm.runInNewContext(`(${text.slice(from, end + 2)})`);
}
const effortStart = source.indexOf('function getReasoningEffort(');
if (effortStart < 0) throw new Error('Pinned function missing: getReasoningEffort');
const effortBody = source.slice(effortStart, source.indexOf('\n}\n', effortStart) + 3);
const filterStart = serverSource.indexOf('// A few of OpenAIs reasoning models support reasoning effort');
if (filterStart < 0) throw new Error('Pinned reasoning effort filter missing');
const filter = serverSource.slice(filterStart, serverSource.indexOf('\n\n', filterStart));
const models = literal(constantsSource, 'OPENAI_REASONING_EFFORT_MODELS');
const fixed = literal(constantsSource, 'OPENAI_FIXED_REASONING_EFFORT');
const effortContext = vm.createContext({
  chat_completion_sources: literal(source, 'chat_completion_sources'),
  reasoning_effort_types: literal(source, 'reasoning_effort_types'),
  model_list: [],
  CHAT_COMPLETION_SOURCES: literal(constantsSource, 'CHAT_COMPLETION_SOURCES'),
  OPENAI_REASONING_EFFORT_MODELS: models,
  OPENAI_FIXED_REASONING_EFFORT: fixed,
  OPENAI_REASONING_EFFORT_MAP: literal(constantsSource, 'OPENAI_REASONING_EFFORT_MAP'),
});
vm.runInContext(effortBody, effortContext, {timeout: 1000});
vm.runInContext(`function sentEffort(request) { const bodyParams = {};\n${filter}\nreturn bodyParams.reasoning_effort; }`, effortContext, {timeout: 1000});
const custom = effortContext.chat_completion_sources.CUSTOM;
const cases = ['gpt-5', 'gpt-5.3-chat-latest', 'gpt-4o', 'koboldcpp/llama', 'claude-sonnet-4-5'].flatMap(model =>
  Object.values(effortContext.reasoning_effort_types).map(effort => {
    const client = effortContext.getReasoningEffort({chat_completion_source: custom, reasoning_effort: effort}, model);
    const sent = effortContext.sentEffort({body: {chat_completion_source: custom, model, reasoning_effort: client}});
    return {model, effort, sent: sent ?? null};
  }));
await fs.writeFile('test/fixtures/st/reasoning-effort-reference.json', JSON.stringify({
  commit,
  functionSha256: createHash('sha256').update(effortBody).digest('hex'),
  filterSha256: createHash('sha256').update(filter).digest('hex'),
  assumptions: ['Custom chat completion source', 'No custom_include_body or custom_exclude_body'],
  models, fixed, cases,
}, null, 2) + '\n');
console.log('Captured ST reasoning effort:', models.length, 'models,', cases.length, 'cases');

// Settings a text completion preset carries (textgen-settings.js); the
// importer keeps the sampling ones as parameters.
const textgenSource = await (await fetch(base + 'public/scripts/textgen-settings.js')).text();
const settingNames = literal(textgenSource, 'setting_names');
await fs.writeFile('test/fixtures/st/textgen-settings-reference.json', JSON.stringify({
  commit, settingNames,
}, null, 2) + '\n');
console.log('Captured ST text completion settings:', settingNames.length);
