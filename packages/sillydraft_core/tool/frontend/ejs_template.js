// WebView API adapter for ST-Prompt-Template 1.17 / d6f520d1.
// The engine, variable operations, JSON helpers and lint come from that revision.
import ejs from '../prompt-template/src/3rdparty/ejs.js';
import * as variables from '../prompt-template/src/function/variables.ts';
import { jsonPatch, parseJSON, patchVariables } from '../prompt-template/src/function/json-patch.ts';
import { getSyntaxErrorInfo } from '../prompt-template/syntax.ts';
import { settings, refreshChat, chat } from './ejs_host.js';

const defaults = { ...settings };
const defines = {};
const unavailable = name => function () {
  throw new Error(`EjsTemplate.${name}: SillyDraft 网页视图尚不支持此宿主功能`);
};

function optionsFor(data, options = {}) {
  const result = { async: true, outputFunctionName: 'print', _with: true, localsName: 'locals', client: true, ...options };
  if (settings.with_context_disabled || result._with === false) {
    result._with = false;
    result.destructuredLocals ??= Object.keys(data);
  }
  return result;
}

async function evalTemplate(code, context = null, options = {}) {
  variables.STATE.isDryRun = false;
  context ??= await prepareContext();
  if (typeof code !== 'string' || !code.includes(`${options.openDelimiter ?? '<'}${options.delimiter ?? '%'}`)) return code;
  const func = ejs.compile(code, optionsFor(context, options));
  // The extension deliberately uses identity escaping and its variadic print engine.
  return await func.call(context, context, value => value, unavailable('include'));
}

async function compileTemplate(code, options = {}, thisData = {}) {
  if (options.sandbox) unavailable('compileTemplate.sandbox')();
  const opts = optionsFor(thisData, options.options);
  opts.client = true;
  opts.escape = undefined;
  opts.includer = undefined;
  // shortcut: compile in this isolated WebView; use a worker if large templates stall it.
  const func = ejs.compile(code, opts);
  return function (data = {}) {
    return func.call(this, data, options.escaper ?? (value => value), options.includer ?? unavailable('include'));
  };
}

function withChat(fn, context, args) {
  refreshChat();
  return fn.apply(context, args);
}

function bindDefines(context, value) {
  if (typeof value === 'function') return value.bind(context);
  if (Array.isArray(value)) return value.map(item => bindDefines(context, item));
  if (_.isPlainObject(value)) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, bindDefines(context, item)]));
  return value;
}

async function prepareContext(env = {}, end = -1) {
  refreshChat();
  variables.precacheVariables(end);
  const S = window.SillyDraft.state;
  const context = {
    _, $, z, toastr, console,
    get variables() { return variables.STATE.cacheVars; },
    get SillyTavern() { return window.SillyTavern.getContext(); },
    execute: cmd => window.triggerSlash(cmd),
    userName: S.name1, assistantName: S.name2, charName: S.name2,
    chatId: S.chat_id, characterId: 0,
    charAvatar: window.getCharAvatarPath(), userAvatar: window.getUserAvatarPath(),
    get lastUserMessageId() { return chat.findLastIndex(message => message.is_user); },
    get lastUserMessage() { return chat.findLast(message => message.is_user)?.mes ?? ''; },
    get lastCharMessageId() { return chat.findLastIndex(message => !message.is_user && !message.is_system); },
    get lastCharMessage() { return chat.findLast(message => !message.is_user && !message.is_system)?.mes ?? ''; },
    get lastMessageId() { return chat.length - 1; },
    jsonPatch, parseJSON,
    ...env,
  };
  for (const [name, fn] of Object.entries({
    setvar: variables.setVariable, getvar: variables.getVariable,
    incvar: variables.increaseVariable, decvar: variables.decreaseVariable,
    delvar: variables.removeVariable, insvar: variables.insertVariable,
    patchVariables, applyVarYamlAnnotate: variables.dumpYamlWithSchema,
    setVariableSchema: variables.setVariableSchema,
  })) context[name] = (...args) => withChat(fn, context, args);

  for (const [suffix, scope] of [['Local', 'local'], ['Global', 'global'], ['Message', 'message']]) {
    context[`set${suffix}Var`] = (key, value, options = {}) => context.setvar(key, value, { ...options, scope });
    context[`get${suffix}Var`] = (key, options = {}) => context.getvar(key, { ...options, scope });
    context[`inc${suffix}Var`] = (key, value = 1, options = {}) => context.incvar(key, value, { ...options, outscope: scope });
    context[`dec${suffix}Var`] = (key, value = 1, options = {}) => context.decvar(key, value, { ...options, outscope: scope });
    context[`insert${suffix}Var`] = (key, value, index, options = {}) => context.insvar(key, value, index, { ...options, scope });
    // Preserve d6f520d1's shorthand argument order; use delvar for explicit scopes.
    context[`del${suffix}Var`] = (key, options = {}) => context.delvar(key, { ...options, scope });
  }
  context.findVariables = (key, id = chat.length) => withChat(variables.findPreviousMessageVariables, context, [id, key]);
  context.evalTemplate = async (code, data = {}, options = {}) => window.substituteMacros(await evalTemplate(code, _.merge(context, data), options));
  context.define = (name, value, merge = false) => {
    const old = _.get(defines, name);
    if (merge && Array.isArray(value) && (old === undefined || Array.isArray(old))) value = _.concat(old ?? [], value);
    else if (merge && _.isPlainObject(value) && (old === undefined || _.isPlainObject(old))) value = _.mergeWith(old ?? {}, value, (_dst, src) => Array.isArray(src) ? src : undefined);
    _.set(defines, name, value);
    _.set(context, name, value);
    return old;
  };
  for (const name of [
    'getwi', 'getWorldInfo', 'getWorldInfoData', 'getWorldInfoActivatedData',
    'getEnabledWorldInfoEntries', 'selectActivatedEntries', 'activewi', 'activateWorldInfo',
    'activateWorldInfoByKeywords', 'getEnabledLoreBooks', 'getchr', 'getchar', 'getChara',
    'getCharaData', 'getCharData', 'getprp', 'getpreset', 'getPresetPrompt',
    'getqr', 'getQuickReply', 'getQuickReplyData', 'getChatMessage', 'getChatMessages',
    'matchChatMessages', 'activateRegex', 'injectPrompt', 'getPromptsInjected', 'hasPromptsInjected',
  ]) context[name] = unavailable(name);
  // These extension helpers use different signatures from TavernHelper's globals.
  _.merge(context, bindDefines(context, defines));
  // The prepare hook mutates a local context containing functions and cycles.
  await window.__sdDispatch('prompt_template_prepare', [context]);
  return context;
}

window.EjsTemplate = {
  evalTemplate, compileTemplate, prepareContext, getSyntaxErrorInfo,
  allVariables: (...args) => withChat(variables.precacheVariables, null, args),
  saveVariables: variables.checkAndSave,
  get defines() { return defines; },
  get initialVariables() { return variables.STATE.initialVariables; },
  parseJSON, jsonPatch,
  setFeatures(features) {
    for (const [key, value] of Object.entries(features)) {
      if (!Object.hasOwn(defaults, key)) unavailable(`setFeatures(${key})`)();
      if (typeof value !== 'boolean') throw new TypeError(`EjsTemplate.setFeatures: ${key} 必须是 boolean`);
    }
    Object.assign(settings, features);
  },
  getFeatures: () => ({ ...settings }),
  resetFeatures: () => Object.assign(settings, defaults),
  refreshWorldInfo: async () => unavailable('refreshWorldInfo')(),
  finalization: typeof FinalizationRegistry === 'function' ? new FinalizationRegistry(sandbox => {
    if (typeof sandbox?.destroyIframe === 'function') sandbox.destroyIframe();
  }) : null,
};
