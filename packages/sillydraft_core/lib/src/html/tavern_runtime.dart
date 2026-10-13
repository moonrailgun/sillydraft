/// The script injected into every HTML block before its own content.
///
/// It reproduces the parts of 酒馆助手 (JS-Slash-Runner) a front-end block
/// can see: chat messages and swipes, variables, events, slash commands,
/// macros, `toastr`, a minimal `SillyTavern.getContext()` and an MVU data
/// shim. Synchronous functions read a snapshot the host injected as
/// `window.__SD_STATE`; writes update that snapshot and then persist through
/// the `SillyDraftBridge` channel. Height changes go to `SillyDraftHeight`.
///
/// Nothing here depends on lodash or jQuery, which load from a CDN after it
/// and may be unavailable offline.
const tavernRuntimeJs = r'''
(function () {
  'use strict';
  var S = window.__SD_STATE || {};
  var api = !!S.api;

  // ---------------------------------------------------------------- bridge
  var seq = 0;
  var pending = new Map();
  function call(method, args) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      pending.set(id, { resolve: resolve, reject: reject });
      try {
        if (!window.SillyDraftBridge) throw new Error('SillyDraft 桥接不可用');
        window.SillyDraftBridge.postMessage(JSON.stringify({ id: id, method: method, args: args || [] }));
      } catch (e) {
        pending.delete(id);
        reject(e);
      }
    });
  }
  window.__sdResolve = function (id, ok, payload) {
    var p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (ok) p.resolve(payload);
    else p.reject(new Error(typeof payload === 'string' ? payload : JSON.stringify(payload)));
  };
  function quietly(promise) {
    return promise.catch(function (e) { try { console.error(e); } catch (_) {} });
  }

  // ---------------------------------------------------------------- height
  // The frame follows the page the way 酒馆助手 sizes its iframe: whenever
  // the body overflows, grow to `body.scrollHeight`, which converges for
  // pages that centre a box with `top: 50%` transforms. Growing alone can
  // never undo a transient tall state (a screen transition pushed off with
  // `translateY(100vh)`), because `body { height: 100% }` ties the body to
  // the frame; so after each DOM change the frame may also shrink once, to
  // the lowest visible content edge (clipped by scrolling ancestors, fixed
  // layers ignored). One shrink per change keeps `max-height: 90vh` boxes,
  // whose content edge scales with the frame, from collapsing.
  var lastHeight = -1;
  var scheduled = false;
  var epoch = 0;
  var shrunkEpoch = -1;
  var lastOverflow = -1;
  var lastOverflowAt = 0;
  function contentBottom() {
    var body = document.body;
    var bottom = 0;
    function visit(element, clip) {
      var style = getComputedStyle(element);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return;
      if (parseFloat(style.opacity) === 0 || style.position === 'fixed') return;
      var rect = element.getBoundingClientRect();
      var own = Math.min(rect.bottom, clip);
      if (rect.height > 0 && own > bottom) bottom = own;
      var childClip = clip;
      if (style.overflow !== 'visible' || style.overflowY !== 'visible' || style.overflowX !== 'visible' || style.contain === 'paint') {
        childClip = Math.min(clip, rect.bottom);
      }
      for (var i = 0; i < element.children.length; i++) visit(element.children[i], childClip);
    }
    for (var i = 0; i < body.children.length; i++) visit(body.children[i], Infinity);
    var bodyStyle = getComputedStyle(body);
    bottom += (parseFloat(bodyStyle.paddingBottom) || 0) + (parseFloat(bodyStyle.marginBottom) || 0);
    var minHeight = parseFloat(bodyStyle.minHeight);
    if (isFinite(minHeight) && minHeight > bottom) bottom = minHeight;
    return Math.ceil(bottom + (window.scrollY || 0));
  }
  function measure() {
    scheduled = false;
    try {
      if (!document.body) return;
      var frame = window.innerHeight;
      var overflow = document.body.scrollHeight;
      var height = frame;
      if (overflow > frame + 0.5) {
        // Grow only once the overflow has held still: an element animating
        // in from `translateY(100vh)` overflows by a full frame, and growing
        // on each animation frame would double the frame until it ends.
        var now = Date.now();
        if (Math.abs(overflow - lastOverflow) > 1) {
          lastOverflow = overflow;
          lastOverflowAt = now;
          setTimeout(postHeight, 150);
          return;
        }
        if (now - lastOverflowAt < 120) { setTimeout(postHeight, 150); return; }
        height = overflow;
      } else {
        var content = frame;
        try { content = contentBottom(); } catch (e) { quietly(call('log', ['error', 'measure: ' + e])); }
        if (content < frame - 8 && shrunkEpoch !== epoch) {
          height = content;
          shrunkEpoch = epoch;
        }
      }
      if (!isFinite(height) || height <= 0) return;
      if (Math.abs(height - lastHeight) < 1) return;
      if (!window.SillyDraftHeight) return;
      lastHeight = height;
      (window.__sdPosts = window.__sdPosts || []).push([Date.now(), height, frame, overflow]);
      if (window.__sdPosts.length > 50) window.__sdPosts.shift();
      window.SillyDraftHeight.postMessage(String(height));
    } catch (_) {}
  }
  // An occluded or off-screen web view never runs animation frames, so a
  // timer backs every scheduled measurement up; whichever fires first wins.
  function postHeight() {
    if (scheduled) return;
    scheduled = true;
    var done = false;
    function run() { if (done) return; done = true; measure(); }
    if (typeof window.requestAnimationFrame === 'function') window.requestAnimationFrame(run);
    setTimeout(run, 60);
  }
  function changed() { epoch++; postHeight(); }
  window.__sdSetViewport = function (px) {
    try { document.documentElement.style.setProperty('--TH-viewport-height', px + 'px'); } catch (_) {}
    changed();
  };
  window.__sdMeasure = function () { lastHeight = -1; changed(); };
  window.__sdContentHeight = function () { return contentBottom(); };
  function observe() {
    if (!document.body) return;
    changed();
    if (typeof ResizeObserver === 'function') {
      var observer = new ResizeObserver(function () { postHeight(); });
      observer.observe(document.body);
      for (var i = 0; i < document.body.children.length; i++) observer.observe(document.body.children[i]);
    }
    if (typeof MutationObserver === 'function') {
      new MutationObserver(function () { changed(); }).observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
    }
    // Fonts, images and scripted layout settle at their own pace; keep
    // checking, often at first and then slowly.
    var started = Date.now();
    var ticker = setInterval(function () {
      postHeight();
      if (Date.now() - started > 15000) {
        clearInterval(ticker);
        setInterval(postHeight, 2000);
      }
    }, 400);
    window.addEventListener('transitionend', changed, true);
    window.addEventListener('animationend', changed, true);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe);
  else observe();
  window.addEventListener('load', function () { lastHeight = -1; changed(); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { lastHeight = -1; changed(); });
  window.addEventListener('error', function (e) {
    quietly(call('log', ['error', String(e && e.message)]));
  });
  window.addEventListener('unhandledrejection', function (e) {
    quietly(call('log', ['error', String(e && e.reason)]));
  });

  if (!api) return;

  // ---------------------------------------------------------------- helpers
  function clone(value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); }
  function isObject(value) { return value !== null && typeof value === 'object'; }
  function splitPath(path) {
    if (Array.isArray(path)) return path.map(String);
    var parts = [];
    String(path).replace(/\[(\d+)\]|\[(["'])(.*?)\2\]|([^.[\]]+)/g, function (_, index, _q, quoted, plain) {
      parts.push(index !== undefined ? index : quoted !== undefined ? quoted : plain);
    });
    return parts;
  }
  function getPath(object, path, fallback) {
    var parts = splitPath(path), current = object;
    for (var i = 0; i < parts.length; i++) {
      if (!isObject(current) || !(parts[i] in current)) return fallback;
      current = current[parts[i]];
    }
    return current === undefined ? fallback : current;
  }
  function setPath(object, path, value) {
    var parts = splitPath(path), current = object;
    for (var i = 0; i < parts.length - 1; i++) {
      if (!isObject(current[parts[i]])) current[parts[i]] = /^\d+$/.test(parts[i + 1]) ? [] : {};
      current = current[parts[i]];
    }
    current[parts[parts.length - 1]] = value;
    return object;
  }
  function unsetPath(object, path) {
    var parts = splitPath(path), current = object;
    for (var i = 0; i < parts.length - 1; i++) {
      if (!isObject(current)) return false;
      current = current[parts[i]];
    }
    if (!isObject(current) || !(parts[parts.length - 1] in current)) return false;
    delete current[parts[parts.length - 1]];
    return true;
  }
  function merge(target, source, overwrite) {
    Object.keys(source).forEach(function (key) {
      if (isObject(source[key]) && !Array.isArray(source[key]) && isObject(target[key]) && !Array.isArray(target[key])) {
        merge(target[key], source[key], overwrite);
      } else if (overwrite || !(key in target)) {
        target[key] = clone(source[key]);
      }
    });
    return target;
  }
  function fail(message) { throw new Error(message); }

  // ---------------------------------------------------------------- messages
  S.messages = Array.isArray(S.messages) ? S.messages : [];
  function normalizeId(id) { return id < 0 ? S.messages.length + id : id; }
  function parseRange(range) {
    var text = substitudeMacros(String(range)).trim();
    var count = S.messages.length;
    function clamp(value) { value = value < 0 ? count + value : value; return Math.min(Math.max(value, 0), count - 1); }
    var single = /^(-?\d+)$/.exec(text);
    if (single) { var one = clamp(Number(single[1])); return { start: one, end: one }; }
    var pair = /^(-?\d+)-(-?\d+)$/.exec(text);
    if (!pair) return null;
    var a = clamp(Number(pair[1])), b = clamp(Number(pair[2]));
    return { start: Math.min(a, b), end: Math.max(a, b) };
  }
  function getChatMessages(range, option) {
    option = option || {};
    var role = option.role || 'all', hide = option.hide_state || 'all';
    var swipes = option.include_swipes === true || option.include_swipe === true;
    if (S.messages.length === 0) return [];
    var bounds = parseRange(range);
    if (!bounds) return [];
    var result = [];
    for (var i = bounds.start; i <= bounds.end; i++) {
      var m = S.messages[i];
      if (!m) continue;
      if (role !== 'all' && m.role !== role) continue;
      if (hide !== 'all' && (hide === 'hidden') !== !!m.is_hidden) continue;
      var list = Array.isArray(m.swipes) && m.swipes.length ? m.swipes : [m.message];
      var data = Array.isArray(m.swipes_data) ? m.swipes_data : [];
      var base = {
        message_id: i, name: m.name, role: m.role, is_hidden: !!m.is_hidden,
        swipe_id: m.swipe_id || 0,
        swipes: list.slice(),
        swipes_data: list.map(function (_, k) { return clone(data[k] || {}); }),
        swipes_info: list.map(function () { return {}; }),
      };
      if (!swipes) {
        base.message = m.message;
        base.data = clone(m.data || {});
        base.extra = clone(m.extra || {});
      }
      result.push(base);
    }
    return result;
  }
  function applyMessageChange(change) {
    var id = normalizeId(Number(change.message_id));
    var m = S.messages[id];
    if (!m) fail('楼层 ' + change.message_id + ' 不存在');
    if (Array.isArray(change.swipes)) m.swipes = change.swipes.slice();
    if (typeof change.swipe_id === 'number') {
      m.swipe_id = change.swipe_id;
      if (Array.isArray(m.swipes) && m.swipes[change.swipe_id] !== undefined && typeof change.message !== 'string') {
        m.message = m.swipes[change.swipe_id];
      }
    }
    if (typeof change.message === 'string') {
      m.message = change.message;
      if (Array.isArray(m.swipes)) m.swipes[m.swipe_id || 0] = change.message;
    }
    if (change.data !== undefined) { m.data = clone(change.data); S.variables.messages[String(id)] = clone(change.data); }
    if (typeof change.is_hidden === 'boolean') m.is_hidden = change.is_hidden;
    if (typeof change.name === 'string') m.name = change.name;
    return id;
  }
  async function setChatMessages(changes, option) {
    if (!Array.isArray(changes)) fail('setChatMessages 需要数组');
    var normalized = changes.map(function (change) {
      var copy = clone(change);
      copy.message_id = applyMessageChange(change);
      return copy;
    });
    await call('setChatMessages', [normalized, option || {}]);
  }
  async function setChatMessage(fields, message_id, option) {
    option = option || {};
    var change = typeof fields === 'string' ? { message: fields } : clone(fields || {});
    change.message_id = message_id;
    if (typeof option.swipe_id === 'number') change.swipe_id = option.swipe_id;
    await setChatMessages([change], { refresh: option.refresh === 'none' ? 'none' : 'affected' });
  }
  async function createChatMessages(messages, option) {
    if (!Array.isArray(messages)) fail('createChatMessages 需要数组');
    await call('createChatMessages', [clone(messages), option || {}]);
  }
  async function deleteChatMessages(ids, option) {
    await call('deleteChatMessages', [clone(ids), option || {}]);
  }
  async function rotateChatMessages() { fail('SillyDraft 不支持移动正文章节顺序'); }
  function getLastMessageId() { return S.messages.length - 1; }
  function getCurrentMessageId() { return S.message_id; }
  function getIframeName() { return S.iframe_name; }
  function getMessageId(name) {
    var m = /^TH-message--(\d+)--/.exec(String(name));
    if (!m) fail('不是前端界面的 iframe 名称：' + name);
    return Number(m[1]);
  }

  // ---------------------------------------------------------------- variables
  S.variables = isObject(S.variables) ? S.variables : {};
  S.variables.chat = isObject(S.variables.chat) ? S.variables.chat : {};
  S.variables.global = isObject(S.variables.global) ? S.variables.global : {};
  S.variables.messages = isObject(S.variables.messages) ? S.variables.messages : {};
  S.variables.other = isObject(S.variables.other) ? S.variables.other : {};
  function normalizeOption(option) {
    option = option || { type: 'chat' };
    if (typeof option === 'string') option = { type: option };
    var type = option.type || 'chat';
    if (type === 'message') {
      var id = option.message_id === undefined || option.message_id === 'latest' ? S.messages.length - 1 : normalizeId(Number(option.message_id));
      if (!(id >= 0 && id < S.messages.length)) fail('楼层 ' + option.message_id + ' 不存在');
      return { type: 'message', message_id: id };
    }
    if (type === 'script') return { type: 'script', script_id: option.script_id || 'frontend' };
    if (type === 'extension') return { type: 'extension', extension_id: String(option.extension_id || '') };
    return { type: type };
  }
  function store(option) {
    var o = normalizeOption(option);
    if (o.type === 'chat') return S.variables.chat;
    if (o.type === 'global') return S.variables.global;
    if (o.type === 'message') {
      var key = String(o.message_id);
      if (!isObject(S.variables.messages[key])) S.variables.messages[key] = {};
      return S.variables.messages[key];
    }
    var name = o.type + (o.script_id ? ':' + o.script_id : '') + (o.extension_id ? ':' + o.extension_id : '');
    if (!isObject(S.variables.other[name])) S.variables.other[name] = {};
    return S.variables.other[name];
  }
  function getVariables(option) { return clone(store(option)); }
  function replaceVariables(variables, option) {
    if (!isObject(variables)) fail('变量表必须是对象');
    var target = store(option);
    Object.keys(target).forEach(function (key) { delete target[key]; });
    Object.keys(variables).forEach(function (key) { target[key] = clone(variables[key]); });
    quietly(call('replaceVariables', [clone(target), normalizeOption(option)]));
  }
  function updateVariablesWith(updater, option) {
    var result = updater(getVariables(option));
    if (result && typeof result.then === 'function') {
      return result.then(function (value) { replaceVariables(value, option); return getVariables(option); });
    }
    replaceVariables(result, option);
    return getVariables(option);
  }
  function insertOrAssignVariables(variables, option) {
    return updateVariablesWith(function (current) { return merge(current, variables, true); }, option);
  }
  function insertVariables(variables, option) {
    return updateVariablesWith(function (current) { return merge(current, variables, false); }, option);
  }
  function deleteVariable(path, option) {
    var removed = false;
    var variables = updateVariablesWith(function (current) { removed = unsetPath(current, path); return current; }, option);
    return { variables: variables, delete_occurred: removed };
  }
  function getAllVariables() {
    var result = {};
    merge(result, S.variables.global, true);
    merge(result, S.variables.chat, true);
    var current = S.variables.messages[String(S.message_id)];
    if (isObject(current)) merge(result, current, true);
    return result;
  }
  function registerVariableSchema() {}

  // ---------------------------------------------------------------- macros
  function substitudeMacros(text) {
    return String(text)
      .replace(/\{\{\s*user\s*\}\}/gi, S.name1 || '')
      .replace(/\{\{\s*char\s*\}\}/gi, S.name2 || '')
      .replace(/\{\{\s*lastMessageId\s*\}\}/gi, String(S.messages.length - 1))
      .replace(/\{\{\s*getvar::([^}]*)\}\}/gi, function (_, key) { var v = S.variables.chat[key.trim()]; return v === undefined ? '' : typeof v === 'string' ? v : JSON.stringify(v); })
      .replace(/\{\{\s*getglobalvar::([^}]*)\}\}/gi, function (_, key) { var v = S.variables.global[key.trim()]; return v === undefined ? '' : typeof v === 'string' ? v : JSON.stringify(v); })
      .replace(/\{\{\s*newline\s*\}\}/gi, '\n')
      .replace(/\{\{\s*noop\s*\}\}/gi, '')
      .replace(/\n*\{\{\s*trim\s*\}\}\n*/gi, '');
  }

  // ---------------------------------------------------------------- events
  var listeners = new Map();
  function bucket(event) {
    if (!listeners.has(event)) listeners.set(event, []);
    return listeners.get(event);
  }
  function eventOn(event, listener) { bucket(event).push({ fn: listener, once: false }); return { stop: function () { eventRemoveListener(event, listener); } }; }
  function eventMakeLast(event, listener) { return eventOn(event, listener); }
  function eventMakeFirst(event, listener) { bucket(event).unshift({ fn: listener, once: false }); return { stop: function () { eventRemoveListener(event, listener); } }; }
  function eventOnce(event, listener) { bucket(event).push({ fn: listener, once: true }); return { stop: function () { eventRemoveListener(event, listener); } }; }
  function eventOnButton(name, listener) { return eventOn('button:' + name, listener); }
  function eventRemoveListener(event, listener) {
    if (!listeners.has(event)) return;
    listeners.set(event, listeners.get(event).filter(function (entry) { return entry.fn !== listener; }));
  }
  function eventRemoveAllListeners(event) { if (event === undefined) listeners.clear(); else listeners.delete(event); }
  function eventClearEvent(event) { listeners.delete(event); }
  function eventClearListener(listener) {
    listeners.forEach(function (entries, event) {
      listeners.set(event, entries.filter(function (entry) { return entry.fn !== listener; }));
    });
  }
  function eventClearAll() { listeners.clear(); }
  function dispatch(event, args) {
    var entries = (listeners.get(event) || []).slice();
    listeners.set(event, (listeners.get(event) || []).filter(function (entry) { return !entry.once; }));
    return Promise.all(entries.map(function (entry) {
      try { return Promise.resolve(entry.fn.apply(null, args)); } catch (e) { console.error(e); return Promise.resolve(); }
    }));
  }
  async function eventEmit(event) {
    var args = Array.prototype.slice.call(arguments, 1);
    dispatch(event, args);
    quietly(call('eventEmit', [String(event), clone(args)]));
  }
  async function eventEmitAndWait(event) {
    var args = Array.prototype.slice.call(arguments, 1);
    await dispatch(event, args);
    quietly(call('eventEmit', [String(event), clone(args)]));
  }
  function eventWaitOnce(event) {
    return new Promise(function (resolve) {
      eventOnce(event, function () { var a = Array.prototype.slice.call(arguments); resolve(a.length <= 1 ? a[0] : a); });
    });
  }
  function eventWaitOnceOnButton(name) { return eventWaitOnce('button:' + name); }
  window.__sdDispatch = function (event, args) { dispatch(event, Array.isArray(args) ? args : []); };
  var tavern_events = {
    APP_READY: 'app_ready', CHAT_CHANGED: 'chat_id_changed', MESSAGE_SWIPED: 'message_swiped',
    MESSAGE_SENT: 'message_sent', MESSAGE_RECEIVED: 'message_received', MESSAGE_EDITED: 'message_edited',
    MESSAGE_DELETED: 'message_deleted', MESSAGE_UPDATED: 'message_updated', MORE_MESSAGES_LOADED: 'more_messages_loaded',
    GENERATION_STARTED: 'generation_started', GENERATION_STOPPED: 'generation_stopped', GENERATION_ENDED: 'generation_ended',
    USER_MESSAGE_RENDERED: 'user_message_rendered', CHARACTER_MESSAGE_RENDERED: 'character_message_rendered',
    CHARACTER_FIRST_MESSAGE_SELECTED: 'character_first_message_selected', SETTINGS_UPDATED: 'settings_updated',
    WORLDINFO_UPDATED: 'worldinfo_updated', STREAM_TOKEN_RECEIVED: 'stream_token_received',
  };
  var iframe_events = {
    MESSAGE_IFRAME_RENDER_STARTED: 'message_iframe_render_started',
    MESSAGE_IFRAME_RENDER_ENDED: 'message_iframe_render_ended',
    GENERATION_REQUESTED: 'js_generation_requested', GENERATION_STARTED: 'js_generation_started',
    STREAM_TOKEN_RECEIVED_FULLY: 'js_stream_token_received_fully',
    STREAM_TOKEN_RECEIVED_INCREMENTALLY: 'js_stream_token_received_incrementally',
    GENERATION_ENDED: 'js_generation_ended',
  };

  // ---------------------------------------------------------------- globals
  var globals = new Map();
  var waiters = new Map();
  function initializeGlobal(name, value) {
    window[name] = value;
    globals.set(name, value);
    (waiters.get(name) || []).forEach(function (resolve) { resolve(value); });
    waiters.delete(name);
  }
  function waitGlobalInitialized(name) {
    if (globals.has(name)) return Promise.resolve(globals.get(name));
    return new Promise(function (resolve) {
      if (!waiters.has(name)) waiters.set(name, []);
      waiters.get(name).push(resolve);
    });
  }

  // ---------------------------------------------------------------- misc
  function toast(severity) {
    return function (message, title) { quietly(call('toast', [severity, String(message === undefined ? '' : message), title === undefined ? '' : String(title)])); };
  }
  var toastr = { success: toast('success'), info: toast('info'), warning: toast('warning'), error: toast('error'), clear: function () {}, remove: function () {}, options: {} };
  function errorCatched(fn) {
    return function () {
      try {
        var result = fn.apply(this, arguments);
        if (result && typeof result.catch === 'function') return result.catch(function (e) { toastr.error(String(e)); throw e; });
        return result;
      } catch (e) { toastr.error(String(e)); throw e; }
    };
  }
  function getCharData() { return clone(S.card || null); }
  function getCharAvatarPath() { return S.char_avatar || ''; }
  function getUserAvatarPath() { return S.user_avatar || ''; }
  async function triggerSlash(command) { return await call('triggerSlash', [String(command)]); }
  async function formatAsDisplayedMessage(text, option) { return await call('formatAsDisplayedMessage', [String(text), option || {}]); }
  function unsupportedGeneration() { return Promise.reject(new Error('SillyDraft 不支持从界面直接调用模型，请改用 /send 或 /trigger 发起写作请求。')); }
  function reloadIframe() { window.location.reload(); }
  function getScriptId() { fail('当前不在脚本库脚本中'); }
  function getButtonEvent(name) { return 'button:' + name; }
  function getScriptButtons() { return []; }
  function replaceScriptButtons() {}
  function appendInexistentScriptButtons() {}
  function getAllEnabledScriptButtons() { return {}; }
  function registerMacroLike() { return { unregister: function () {} }; }
  function unregisterMacroLike() {}

  // ---------------------------------------------------------------- MVU shim
  // MagVarUpdate's global `Mvu`. Reads and writes go to the in-page store
  // synchronously; parsing a message and reloading InitVar run in the host,
  // which applies MVU's update rules in Dart.
  function mvuOption(option) { return option || { type: 'message', message_id: S.message_id }; }
  function isVwd(value) { return Array.isArray(value) && value.length === 2 && typeof value[1] === 'string'; }
  function showValue(value) {
    var text = JSON.stringify(value === undefined ? null : value);
    return text.replace(/^[\\"'` ]*(.*?)[\\"'` ]*$/, '$1');
  }
  function mvuRecord(data, category) {
    if (!data) return {};
    if (category === 'display') return data.display_data || {};
    if (category === 'delta') return data.delta_data || {};
    return data.stat_data || {};
  }
  var Mvu = {
    events: {
      VARIABLE_INITIALIZED: 'mag_variable_initialized',
      VARIABLE_UPDATE_STARTED: 'mag_variable_update_started',
      COMMAND_PARSED: 'mag_command_parsed',
      VARIABLE_UPDATE_ENDED: 'mag_variable_update_ended',
      BEFORE_MESSAGE_UPDATE: 'mag_before_message_update',
      SINGLE_VARIABLE_UPDATED: 'mag_variable_updated',
      UPDATE_FAILED: 'mag_update_failed',
    },
    getMvuData: function (option) {
      var variables = getVariables(mvuOption(option));
      return merge({ stat_data: {}, display_data: {}, delta_data: {}, initialized_lorebooks: {}, schema: { type: 'object', properties: {} } }, variables, true);
    },
    replaceMvuData: async function (data, option) {
      var variables = getVariables(mvuOption(option));
      replaceVariables(merge(variables, data, true), mvuOption(option));
    },
    getCurrentMvuData: function () { return Mvu.getMvuData({ type: 'message', message_id: S.message_id }); },
    replaceCurrentMvuData: async function (data) { return Mvu.replaceMvuData(data, { type: 'message', message_id: S.message_id }); },
    parseMessage: async function (message, old_data) {
      if (!old_data) return undefined;
      var result = clone(old_data);
      await dispatch(Mvu.events.VARIABLE_UPDATE_STARTED, [result]);
      var updated = await call('mvuParseMessage', [String(message), clone(result)]);
      Object.keys(updated).forEach(function (key) { result[key] = updated[key]; });
      await dispatch(Mvu.events.VARIABLE_UPDATE_ENDED, [result, clone(old_data)]);
      return result;
    },
    reloadInitVar: async function (data) {
      if (!data) return false;
      var result = await call('mvuReloadInitVar', [clone(data)]);
      if (!result) return false;
      Object.keys(result).forEach(function (key) { data[key] = result[key]; });
      return true;
    },
    getMvuVariable: function (data, path, option) {
      option = option || {};
      var value = getPath(mvuRecord(data, option.category), path, option.default_value);
      return isVwd(value) ? value[0] : value;
    },
    setMvuVariable: async function (data, path, value, option) {
      option = option || {};
      if (!data || !data.stat_data || getPath(data.stat_data, path) === undefined) return false;
      var current = getPath(data.stat_data, path);
      var old;
      if (Array.isArray(current) && current.length === 2) {
        old = clone(current[0]);
        current[0] = value;
      } else {
        old = clone(current);
        setPath(data.stat_data, path, value);
      }
      var reason = option.reason ? '(' + option.reason + ')' : '';
      var display = showValue(old) + '->' + showValue(value) + ' ' + reason;
      if (!isObject(data.display_data)) data.display_data = {};
      if (!isObject(data.delta_data)) data.delta_data = {};
      setPath(data.display_data, path, display);
      setPath(data.delta_data, path, display);
      if (option.is_recursive) quietly(dispatch(Mvu.events.SINGLE_VARIABLE_UPDATED, [data.stat_data, path, old, value]));
      return true;
    },
    getRecordFromMvuData: function (data, category) { return mvuRecord(data, category); },
    isDuringExtraAnalysis: function () { return false; },
  };
  initializeGlobal('Mvu', Mvu);

  // ---------------------------------------------------------------- SillyTavern shim
  var SillyTavern = {
    getContext: function () {
      return {
        chat: S.messages.map(function (m) { return { name: m.name, is_user: m.role === 'user', is_system: !!m.is_hidden, mes: m.message, swipe_id: m.swipe_id || 0, swipes: (m.swipes || [m.message]).slice(), variables: [m.data || {}], extra: {} }; }),
        chatId: S.chat_id, name1: S.name1, name2: S.name2, characterId: 0, characters: [S.card || {}],
        chatMetadata: { variables: S.variables.chat },
        eventSource: { on: eventOn, once: eventOnce, emit: eventEmit, removeListener: eventRemoveListener, makeFirst: eventMakeFirst, makeLast: eventMakeLast },
        event_types: tavern_events, eventTypes: tavern_events,
        substituteParams: substitudeMacros, substituteParamsExtended: substitudeMacros,
        saveChat: async function () {}, saveSettingsDebounced: function () {}, saveMetadata: async function () {},
        extensionSettings: {}, powerUserSettings: {}, getRequestHeaders: function () { return {}; },
        callPopup: async function (text) { toastr.info(String(text)); return true; },
        callGenericPopup: async function (text) { toastr.info(String(text)); return true; },
      };
    },
  };

  var exported = {
    getChatMessages: getChatMessages, setChatMessages: setChatMessages, setChatMessage: setChatMessage,
    createChatMessages: createChatMessages, deleteChatMessages: deleteChatMessages, rotateChatMessages: rotateChatMessages,
    getLastMessageId: getLastMessageId, getCurrentMessageId: getCurrentMessageId, getIframeName: getIframeName, getMessageId: getMessageId,
    getVariables: getVariables, replaceVariables: replaceVariables, updateVariablesWith: updateVariablesWith,
    insertOrAssignVariables: insertOrAssignVariables, insertVariables: insertVariables, deleteVariable: deleteVariable,
    getAllVariables: getAllVariables, registerVariableSchema: registerVariableSchema,
    substitudeMacros: substitudeMacros, substituteMacros: substitudeMacros,
    eventOn: eventOn, eventMakeLast: eventMakeLast, eventMakeFirst: eventMakeFirst, eventOnce: eventOnce, eventOnButton: eventOnButton,
    eventRemoveListener: eventRemoveListener, eventRemoveAllListeners: eventRemoveAllListeners, eventClearEvent: eventClearEvent,
    eventClearListener: eventClearListener, eventClearAll: eventClearAll, eventEmit: eventEmit, eventEmitAndWait: eventEmitAndWait,
    eventWaitOnce: eventWaitOnce, eventWaitOnceOnButton: eventWaitOnceOnButton,
    initializeGlobal: initializeGlobal, waitGlobalInitialized: waitGlobalInitialized,
    errorCatched: errorCatched, getCharData: getCharData, getCharAvatarPath: getCharAvatarPath, getUserAvatarPath: getUserAvatarPath,
    triggerSlash: triggerSlash, formatAsDisplayedMessage: formatAsDisplayedMessage,
    generate: unsupportedGeneration, generateRaw: unsupportedGeneration,
    reloadIframe: reloadIframe, getScriptId: getScriptId, getButtonEvent: getButtonEvent, getScriptButtons: getScriptButtons,
    replaceScriptButtons: replaceScriptButtons, appendInexistentScriptButtons: appendInexistentScriptButtons,
    getAllEnabledScriptButtons: getAllEnabledScriptButtons, registerMacroLike: registerMacroLike, unregisterMacroLike: unregisterMacroLike,
    tavern_events: tavern_events, iframe_events: iframe_events,
  };
  Object.keys(exported).forEach(function (key) { window[key] = exported[key]; });
  window.TavernHelper = exported;
  window.SillyTavern = SillyTavern;
  window.toastr = toastr;
  window.Mvu = Mvu;
  window.SillyDraft = { version: S.version || '', state: S };

  var originalError = console.error;
  console.error = function () {
    var parts = Array.prototype.slice.call(arguments).map(function (a) { return a && a.stack ? String(a.stack) : String(a); });
    quietly(call('log', ['error', parts.join(' ')]));
    try { originalError.apply(console, arguments); } catch (_) {}
  };
  document.addEventListener('DOMContentLoaded', function () { dispatch(iframe_events.MESSAGE_IFRAME_RENDER_STARTED, [S.iframe_name]); });
  window.addEventListener('load', function () { dispatch(iframe_events.MESSAGE_IFRAME_RENDER_ENDED, [S.iframe_name]); });
})();
''';
