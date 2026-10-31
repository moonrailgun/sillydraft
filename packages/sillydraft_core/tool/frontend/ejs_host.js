// Host bindings for ST-Prompt-Template d6f520d1's variable module.
// Only the selected swipe is stored by SillyDraft; reject other swipes.
export const settings = { autosave_enabled: false, with_context_disabled: false, debug_enabled: false };
export const chat = [];
const state = () => window.SillyDraft.state;
export const chat_metadata = { get variables() { return state().variables.chat; } };
export const extension_settings = { variables: { get global() { return state().variables.global; } } };
export const yaml = window.YAML;
const initialized = new WeakMap();
const persisted = new Map();
function stores() {
  const vars = state().variables;
  return [
    ['global', vars.global, { type: 'global' }],
    ['chat', vars.chat, { type: 'chat' }],
    ...Object.entries(vars.messages).map(([id, value]) => [`message:${id}`, value, { type: 'message', message_id: Number(id) }]),
  ];
}

export function refreshChat() {
  for (const [key, value] of stores()) if (!persisted.has(key)) persisted.set(key, JSON.stringify(value));
  for (let id = 0; id < state().messages.length; id++) {
    if (!persisted.has(`message:${id}`)) persisted.set(`message:${id}`, undefined);
  }
  chat.length = 0;
  state().messages.forEach((message, id) => {
    const swipe = message.swipe_id || 0;
    if (!initialized.has(message)) initialized.set(message, []);
    const variables = new Proxy([], {
      get(target, key) {
        if (/^\d+$/.test(String(key))) {
          if (Number(key) !== swipe) throw new Error('EjsTemplate: 尚不支持其他 swipe 的变量');
          return state().variables.messages[String(id)];
        }
        return Reflect.get(target, key);
      },
      set(target, key, value) {
        if (/^\d+$/.test(String(key))) {
          if (Number(key) !== swipe) throw new Error('EjsTemplate: 尚不支持其他 swipe 的变量');
          state().variables.messages[String(id)] = value;
          return true;
        }
        return Reflect.set(target, key, value);
      },
    });
    chat.push({
      mes: message.message, name: message.name,
      is_user: message.role === 'user', is_system: message.role === 'system',
      swipe_id: swipe, swipes: message.swipes || [message.message],
      variables, variables_initialized: initialized.get(message),
    });
  });
}

// Await each actual bridge acknowledgement. Failure remains visible and retryable.
export async function saveChatConditional() {
  const writes = stores().map(([key, value, option]) => [key, JSON.stringify(value), option]);
  for (const [key, json, option] of writes) {
    if (persisted.get(key) === json) continue;
    await window.SillyDraft.persistVariables(JSON.parse(json), option);
    persisted.set(key, json);
  }
}
