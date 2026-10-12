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
const messages = [{role:'user',content:'brief'}, {role:'assistant',content:'accepted scene'}];
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
await fs.writeFile('test/fixtures/st/text-format-reference.json', JSON.stringify({
  commit, assumptions: ['Default story template', 'trim postprocessor applied', 'Single character', 'No examples or macros in sequences'],
  formattedStory, formattedUser, formattedTail,
  stopStrings: formattingContext.getInstructStoppingSequences({customInstruct: instruct, useStopStrings: false}),
  expected: formattedStory + ctx.chat_start + '\n' + formattedUser + formattedTail,
}, null, 2) + '\n');
console.log('Captured ST text sequence formatting');
