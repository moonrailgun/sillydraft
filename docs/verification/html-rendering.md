# HTML 界面渲染验证（酒馆助手兼容）

对照对象：[JS-Slash-Runner（酒馆助手）](https://github.com/N0VI028/JS-Slash-Runner/tree/a0f3a180344cff38a4b3e75041d5a94380b877d6) 固定提交 `a0f3a180344cff38a4b3e75041d5a94380b877d6` 的 `src/panel/render/iframe.ts`、`src/iframe/adjust_iframe_height.js`、`src/iframe/predefine.js`、`src/iframe/third_party_message.html`、`src/third_party_object.ts`、`package.json`、`src/util/is_frontend.ts`、`src/function/chat_message.ts` 以及 `@types/function/*.d.ts` 的接口声明。本页记录 SillyDraft 内置实现与其对应关系、沙箱边界和已验证范围；未列出的接口视为不支持。

## 渲染规则

| 酒馆助手 | SillyDraft |
| --- | --- |
| 消息中的 `<pre>` 代码块，内容含 `html>`、`<head>` 或 `<body` 时替换为 iframe | `HtmlBlocks.find`：围栏代码块（任意语言）内容含同样标记，或语言标为 `html`/`htm`/`xhtml`，成为“前端块”；与 showdown 相同，以围栏开头的行即闭合围栏，同一行余下的文字（如正则替换后紧跟的 `<game>`）仍是正文；未闭合围栏延伸到正文末尾 |
| 其余 HTML 由 ST 的 markdown + DOMPurify 显示 | 行首的块级标签（`div`、`details`、`table`、`style`、`span` 等）到匹配闭合标签成为“片段块”，相邻片段合并；用 `package:html` 解析后删除 `script`/`iframe`/`object`/`embed`/`link`/`meta`/`base`、`on*` 属性、`srcdoc` 和 `javascript:`/非图片 `data:` 地址 |
| ST 默认不编码标签（`encode_tags` 关闭），DOMPurify 删除未知元素、保留其文字 | 正文中的标签和注释（`<game>`、`</game>`、`<!-- -->`）隐藏，文字照常显示；代码中的标签、`<主角>`、`a < b` 这类非标签保留。行内 `<b>`/`<i>` 只隐藏、不加粗斜体，`<br>` 不换行 |
| `srcdoc` 包裹：重置样式、`--TH-viewport-height`、`min-height: …vh` 改写、预加载公共依赖 | `HtmlBlocks.document`：同样的重置样式和视口变量，`min-height` 改写逻辑逐条移植；公共依赖见下表。`document.open/write/close` 替换页面后恢复宿主样式、视口变量、输入框、事件和高度观察，保留未完成的桥接请求 |
| `ResizeObserver` 测量 `body.scrollHeight` 设置 iframe 高度 | 页面内按 `body.scrollHeight` 增长或收缩（与酒馆助手一致，普通折叠和收缩动画持续跟随实际高度）；仅当内容高度受框架约束时，每次 DOM 变化后允许收缩一次到可见内容底边（按 overflow 裁剪、忽略 fixed 层），避免 `body{height:100%}` 把框架锁在动画瞬间的高度，也避免视口比例面板反复缩小；`ResizeObserver`/`MutationObserver`/过渡结束/定时复测触发，经 `SillyDraftHeight` 通道回传（24–20000px） |
| 渲染深度、折叠代码块、流式渲染设置 | 不提供；设置中只有整体开关“渲染正文中的 HTML 界面”，阅读器可切换“显示原正文” |

## 接口对应

### 公共依赖

前端块在卡片脚本执行前获得以下依赖。普通 HTML 片段和 `libraries: false` 的文档不加载它们。

| 全局对象／样式 | 版本与加载方式 |
| --- | --- |
| `_`、`$` / `jQuery`、Font Awesome | jsdelivr，分别固定大版本 4、3、6，沿用酒馆助手约定 |
| jQuery UI / Touch Punch | 1.14.2 / 0.2.3，jsdelivr；Touch Punch 只在检测到触摸时启用 |
| `Vue` / `VueRouter` | 3.5.43 / 5.4.0，jsdelivr，global production 构建 |
| `showdown` | 2.1.0，jsdelivr |
| `z` / `YAML` | 完整 Zod 4.4.3（含 `z.z`）/ YAML 2.9.1，随应用打包 |
| Tailwind | 官方 `@tailwindcss/browser` 4.1.12，随应用打包，DOM 重写后重新观察动态类名 |
| `EjsTemplate` | ST-Prompt-Template 1.17 的引擎及适配层，见下一节 |

Vue 使用酒馆助手相同的 runtime-only 构建，供已编译组件使用，不提供浏览器内模板编译器；三个 `__VUE_*` 标志按 `predefine.js` 设置。酒馆助手的 Vue / VueRouter CDN 地址未锁版本，这里按固定提交 `package.json` 的版本范围下限锁定。原生 WebView 没有 ST 父页面，父页面提供的 Zod / YAML 直接内置注入；Zod 错误仍为默认英文，不随宿主语言切换。CDN 依赖需要联网；EjsTemplate 虽已打包，变量操作仍依赖 CDN lodash。

生成文件在 `packages/sillydraft_core/lib/src/html/vendor/`。在核心包目录运行 `node tool/bundle_frontend_libraries.mjs`，按固定版本下载、打包并保留许可；普通 Flutter 构建不需要 npm。

### 内置 EjsTemplate

依据 [ST-Prompt-Template 1.17 / d6f520d149aba146305b0b781ddd691d449c28d2](https://github.com/zonde306/ST-Prompt-Template/tree/d6f520d149aba146305b0b781ddd691d449c28d2) 的 `src/modules/exports.ts`、`src/function/ejs.ts`、`src/function/variables.ts`、`src/function/json-patch.ts`。复用扩展修改过的 EJS 3.1.9 引擎、变量、JSON 和语法检查源码，宿主适配在 `tool/frontend/`；扩展 AGPL-3.0 许可随包保留为 `EJS-TEMPLATE-LICENSE.txt`。

支持 `evalTemplate(code, context, options)`、`compileTemplate(code, {options, escaper, includer}, thisData)`、`prepareContext(env, end)`、`getSyntaxErrorInfo`、`allVariables`、`saveVariables`、`defines`、`initialVariables`、`parseJSON`、`jsonPatch` 及三个布尔设置 `autosave_enabled`、`with_context_disabled`、`debug_enabled`。EJS 支持异步、循环、自定义分隔符和多参数 `print`，`<%=` 沿用扩展的原样输出。上下文提供变量读写、增减、数组操作、Zod schema、`define`、嵌套模板和 `prompt_template_prepare` 事件。

变量合并顺序为 global → initial → local/chat → message；持久化映射到现有宿主变量桥接，只保存变更的作用域，并等待宿主确认。默认 `autosave_enabled: false`，调用 `saveVariables(true)` 才强制保存，失败会拒绝且可重试。`defines`、initial 和设置只在当前 WebView 存活期间保留；消息只支持选中的 swipe，访问其他 swipe 报错。保留固定版本的变量语义，包括 `allVariables(-1)` 的继承顺序和删除简写的参数顺序；需要指定作用域删除时使用 `delvar(key, undefined, {scope})`。

边界：这里只接入网页前端主动调用的 EJS，**模型提示词和世界书中的 EJS 不会自动执行**。未接入扩展的世界书扫描、quick reply、提示词注入、sandbox、faker 和完整 ST 环境；相关已声明宿主方法及不支持的 feature 设置明确抛错。模板在隔离 WebView 内编译，未使用扩展的 Worker，大模板可能阻塞该页面。`compileTemplate` 可提供自定义 includer，默认的世界书 include 不支持。`prepareContext` 的角色、预设、消息查询助手签名不同于酒馆助手接口，因此不拿同名全局函数冒充；页面仍可直接调用下表中支持的酒馆助手全局接口。

### 消息与宿主接口

每一章是一条消息（`message_id` 为章节序号，角色为 `assistant`），第一章的 `swipes` 是角色卡各开场经宏替换后的文本，`swipe_id` 来自作品的开场选择。

| 接口 | 实现 |
| --- | --- |
| `getChatMessages(range, {role, hide_state, include_swipes})` | 同步，来自注入快照；兼容旧参数名 `include_swipe`；结果总带 `swipes`/`swipe_id`（与酒馆助手一致） |
| `setChatMessages([...])`、`setChatMessage(fields, id, {swipe_id})` | 改写对应章节正文（新版本，原因 `html-block`）；第一章 `swipe_id` 切换开场并记录到写作档案；`data` 写入该章变量 |
| `createChatMessages` | 在最后一章末尾新建章节；不支持 `insert_before` |
| `deleteChatMessages`、`rotateChatMessages` | 拒绝并提示用 `/cut N \| /trigger` 改写 |
| `getLastMessageId`、`getCurrentMessageId`、`getIframeName`、`getMessageId` | 同步；名称格式 `TH-message--楼层--序号` |
| `getVariables`/`replaceVariables`/`updateVariablesWith`/`insertOrAssignVariables`/`insertVariables`/`deleteVariable`/`getAllVariables` | `chat` 与 `message` 对应分支在该章的版本化变量，`global` 对应全局变量，`character`/`preset`/`script`/`extension` 存入作品设置；非字符串值按 JSON 存取 |
| `substitudeMacros` | 页面内处理 `{{user}}`、`{{char}}`、`{{lastMessageId}}`、`{{getvar}}`、`{{getglobalvar}}`、`{{newline}}`、`{{noop}}`、`{{trim}}` |
| `eventOn`/`eventOnce`/`eventMakeFirst`/`eventMakeLast`/`eventOnButton`/`eventRemove*`/`eventClear*`/`eventEmit`/`eventEmitAndWait`/`eventWaitOnce` | 页面内事件表；`eventEmit` 经宿主转发给同一页面的其他界面，每个监听每次只触发一次（发送方自己的监听不会再收到一遍，同酒馆助手共用 `eventSource` 的行为）。宿主不产生 ST 生成/消息事件 |
| `initializeGlobal`/`waitGlobalInitialized` | 单个界面内有效，不跨界面共享对象 |
| `triggerSlash` | 见下表 |
| `toastr.*` | 提示条；`alert`/`confirm`/`prompt` 由网页视图回调弹出对话框 |
| `getCharData` | 角色卡字段（不含 `tavern_helper` 和 `regex_scripts` 扩展） |
| `SillyTavern.getContext()` | `chat`、`name1`、`name2`、`chatId`、`characters`、`eventSource`、`substituteParams`；`generate()` 提交输入框中的续写要求 |
| `#send_textarea` / `#send_but` | 隐藏的兼容输入框与发送按钮；赋值、`input`/`change`、点击发送直接续写下一章，同轮事件合并，空白不触发；整页 `document.open/write/close` 后恢复节点与监听，不丢失待确认的续写请求 |
| `Mvu` | `getMvuData`/`replaceMvuData`/`getMvuVariable`/`setMvuVariable` 读写变量；`parseMessage` 和 `reloadInitVar` 通过宿主调用内置 MVU 核心，范围见 [MVU 验证](mvu.md)；不是任意社区脚本执行环境 |
| `generate`/`generateRaw`、世界书、预设、正则、音频、脚本库接口 | 不支持；`generate` 返回拒绝的 Promise，其他为未定义 |
| 提示词中的 `{{get_message_variable::路径}}`、`{{get_chat_variable}}`、`{{get_global_variable}}`、`{{format_*_variable}}`、`{{format_*_variable_quoted}}`（酒馆助手的助手宏，MVU 卡片用它把状态写进提示词） | `MacroEngine` 内置：`message`/`chat` 读任务局部变量，`global` 读全局变量，`character`/`preset` 为空；忽略 `$` 开头的键；`format` 输出按行首缩进的 YAML |

Slash 命令（管道 `|`、`\|` 转义、引号内不拆分、`{{pipe}}`）：

| 命令 | 行为 |
| --- | --- |
| `/send`、`/sys`、`/sendas name=`、`/comment`、`/impersonate` | 累积为写作要求 |
| `/setinput` | 直接续写下一章并返回文本作为管道值；与 `/cut` 合用仍确认改写 |
| `/trigger`、`/continue` | 标记触发 |
| `/cut N` | 标记第 N 章改写 |
| `/echo [severity=] [title=]`、`/pass` | 提示条 / 管道值 |
| `/setvar key=`、`/getvar`、`/setglobalvar`、`/getglobalvar`、`/addvar`、`/incvar`、`/decvar`、`/flushvar`、`/flushglobalvar` | 变量读写 |
| `/abort` | 停止管道 |
| `/delay`、`/sleep`、`/hide`、`/unhide` 等 | 空操作 |
| `/gen`、`/genraw`、`/run`、`/qr` 及未知命令 | 抛出错误（与酒馆助手 `triggerSlash` 抛错一致） |

除上述输入框适配及不含 `/cut` 的 `/setinput` 管道外，管道结束时若有写作要求、触发或改写标记，宿主打开写作请求页：追加模式或对 `/cut` 的那一章整章改写，写作要求预填；作者确认后才生成。角色卡开始页上的界面以预览模式运行：开场切换直接改选项，变量在创建小说时写入第一章，`/send` 记下文本并在创建后打开写作请求。

## 沙箱

- 页面以字符串加载在保留地址 `https://render.sillydraft.invalid/` 下，`localStorage` 有稳定来源；相对地址不会解析。
- CSP：前端块 `default-src https: wss: data: blob: 'unsafe-inline' 'unsafe-eval'; object-src 'none'; base-uri 'none'; form-action 'none'`；片段块脚本只允许宿主的 nonce 运行时，禁止 `frame-src` 和 `connect-src`。
- 导航委托阻止主框架离开保留地址（子框架允许 HTTPS）；摄像头/麦克风等权限请求一律拒绝；网页视图背景透明。
- 桥接只有 `SillyDraftBridge`（JSON-RPC，单条 1 MB 上限，方法白名单）和 `SillyDraftHeight` 两个通道；页面只能看到当前分支的章节、变量和角色卡元数据，看不到密钥、其他作品或文件系统。
- 没有生成任务的章节按分支当前绑定的全局、预设、角色卡正则显示（`StoryRepository.displayContext`，按写作档案缓存）；规则出错时显示原文而不是空白。
- 快照规模：章节超过 60 章时只为首章、当前章、末章附带变量；正文总量超过 1.5 MB 时较早章节的 `message` 为空并标记 `truncated`。
- 测量调度同时用 `requestAnimationFrame` 和 `setTimeout`：macOS 的 WKWebView 在窗口被遮挡或视图不可见时不触发动画帧，只靠 rAF 会让首次测量永远不发生（集成测试在模拟器窗口盖住应用时复现，页面已加载、`scrollHeight` 正确但框架停在 160px）。被遮挡时 CSS 淡入动画也不推进，所以可见内容扫描可能暂时看不到 `opacity: 0` 的元素；框架以 `scrollHeight` 增长为准，不受影响。
- 高度策略的依据：对《道渊》创建页实测，`body { height: 100% }` 加 `top:50% + translate(-50%,-50%)` 居中、`max-height: 90vh` 可滚动面板；只按 `scrollHeight` 会在过渡动画后留下空白，只按内容底边会让 90vh 面板无限缩小，混合策略在 macOS 和 iOS 模拟器上分别收敛到 1547px（开场页）和 741px（创建页起始屏，面板 742px）。

输入框适配沿用阅读器现有的下一章生成、实时正文和自动采纳流程，不把选项写进已有正文。缺少写作连接时不创建章节；任务正在写作时拒绝重复请求；启动失败通过提示条反馈且保留输入文本。此适配只在前端代码块启用，普通片段没有接口。

## 验证

`integration_test/tavern_input_test.dart` 在 macOS WKWebView 验证原生 value setter、输入事件、发送、直接赋值合并、失败重试和片段隔离；`test/story_directions_test.dart` 验证输入要求进入模型并自动保存到下一章，以及忙碌和缺失模型时不重复建章。测试不调用付费模型。

| 证据 | 内容 |
| --- | --- |
| `packages/sillydraft_core/test/html_blocks_test.dart` | 围栏/片段识别、未闭合围栏、嵌套同名标签、行内标签不升级、片段净化、`vh` 改写、文档组装与 CSP |
| `packages/sillydraft_core/test/tavern_bridge_test.dart` | 显示上下文缓存、无任务章节的显示正则、消息快照与开场切换、变量往返、新建章节、拒绝删除、Slash 管道、桥接消息校验、预览后端、变量编解码 |
| `test/html_block_flow_test.dart` | 阅读文档偏移、无网页视图时的源码回退、阅读器中切换开场/设置变量/发出写作要求、角色卡开始页预览与创建后写入变量、设置开关 |
| `integration_test/html_render_test.dart`（macOS） | 真实 WKWebView：页面按视口自测高度、接口存在、按钮经桥接切换开场、第二个界面读取角色卡并写入变量、`/sys … \| /cut 0 \| /trigger` 打开整章改写请求 |
| `integration_test/html_libraries_test.dart`（macOS） | 真实 WKWebView：Zod 校验、YAML 往返、showdown、Vue / VueRouter、jQuery UI / Touch Punch、Tailwind 初始及动态样式、按钮与原生桥接往返；另测 `document.open/write/close` 后的相同行为。通道回复使用本地测试桩，不调用模型 |
| `integration_test/ejs_template_test.dart`（macOS） | 真实 WKWebView：异步 EJS、print、原样输出、编译选项、语法诊断、上下文与事件、变量继承 / schema / JSON、保存回执 / 失败重试、整页重写；持久化回执使用本地测试桩 |
| `integration_test/tavern_input_test.dart`（macOS） | 真实 WKWebView：输入赋值 / 事件 / 发送合并、失败重试、片段隔离，整页重写后恢复宿主样式 / 输入监听并完成原有待确认请求 |
| `integration_test/html_height_test.dart`（macOS） | 真实 WKWebView：`details` 和带过渡动画的 `max-height` 面板各反复展开、收起两轮，外层高度从 660px 回到 60px |

2026-10-13 结果：核心 143 项、界面 68 项通过；macOS 真实网页视图集成测试结果见下文“运行记录”。真实角色卡《道渊》v5.4.2 的开场为完整 HTML 页面（烟花画布、`min-height: 100vh`、`getChatMessages`/`setChatMessage`/`triggerSlash` 兜底），其备用开场经角色卡正则变成角色创建界面，提交时执行 `/sys … | /cut N | /trigger`；两种结构都在上述测试中以缩减样本覆盖。这是当时的验证范围：尚未内置 Zod 和 MVU 解析，未运行道渊工坊等社区脚本；当前已内置的能力见上表，不把当时结果当作当前整卡验证。

## 运行记录

2026-10-31，macOS arm64，公共依赖、EJS 与整页重写验证：

- 核心 HTML / 桥接测试 36 项、`html_block_flow_test.dart` 界面测试 11 项、原有 `html_render_test.dart` 原生回归 2 项通过；Flutter / 核心包静态分析及全仓库 Dart 格式检查通过。
- `flutter test --no-pub integration_test/html_libraries_test.dart -d macos` 2 项通过：原始文档与异步 `document.open/write/close` 替换后的文档都能直接使用 Vue、VueRouter、Zod，按钮更新视图并完成原生桥接往返。桥接回复为本地测试桩。
- `flutter test --no-pub integration_test/ejs_template_test.dart -d macos` 1 项通过：覆盖异步模板、编译与诊断、上下文事件、变量继承与 schema、保存回执 / 失败重试，以及整页重写后继续求值。变量保存回复为本地测试桩。
- `flutter test --no-pub integration_test/tavern_input_test.dart -d macos` 1 项通过：整页重写恢复输入框及监听器，原有请求仍能收到回执，重复事件不会重复发送，失败后可重试；通道回复为本地测试桩。
- `flutter test --no-pub integration_test/html_height_test.dart -d macos` 2 项通过：普通折叠及动画面板各展开、收起两轮，高度从 660px 回到 60px。
- 使用本机《无限恐怖》V1030 的完整角色卡在临时作品库验证：压缩开场解码后的 Vue 页面显示“无限恐怖 · 开局设定”，正文可见，阅读器网页高度收敛到 359px，重写后的 `#send_textarea` 存在。点击“使用标准大纲开局”后，第一章从 `<SetupPlaceHolderImpl/>` 替换为长度 5,227 个字符的正文。通过真实阅读器及仓库写入路径，不调用模型；卡片内容未作为仓库测试夹具保留。
- 该卡片仍报告世界书接口不可用；上述真实卡片结果仅覆盖开场显示和默认开局写入，不代表自定义开局或整张卡片的全部功能可用。未验证移动端；模型提示词和世界书中的 EJS 自动处理仍未接入。

2026-10-13，macOS arm64（Flutter 3.47.7，Swift Package Manager 集成，未安装 CocoaPods）：

- `flutter analyze`、核心包 `dart analyze` 无问题；`dart format` 检查通过。
- 核心 `dart test` 143 项通过（含本页 2 个新文件 26 项）；界面 `flutter test test` 68 项通过（含 `html_block_flow_test.dart` 5 项）。
- `flutter test integration_test/html_render_test.dart -d macos` 2 项通过，`✓ Built build/macos/Build/Products/Debug/SillyDraft.app`：
  - 缩减样本：WKWebView 内页面按 `--TH-viewport-height` 自测高度超过 300px；`getChatMessages`/`setChatMessage`/`getLastMessageId`/`getIframeName` 存在且首章有 2 个消息页；页面按钮经桥接把第一章切换为 `[重塑仙缘]` 并记录 `greetingIndex=1`；新网页视图中由角色卡正则生成的创建页读取 `getCharData().name` 与 `getCurrentMessageId()`，`insertOrAssignVariables` 写入该章 `stat_data`；`/sys … | /cut 0 | /trigger` 打开“改写整章”写作请求并预填要求。
  - 真实角色卡《道渊》v5.4.2（PNG，从本机 Downloads 导入，若文件不存在则跳过）：开场页 `#info-card`、`#fireworks-canvas` 和 `switchToSecondGreeting` 均存在，首章 2 个消息页；调用卡片自己的 `switchToSecondGreeting()` 后第一章变为 `[重塑仙缘]`，随后显示的角色创建页 `document.title` 为“道渊”、正文文本长度 337。该卡依赖的外链脚本（MVU 等）未运行，因此状态栏中的变量自动更新不在本次验证范围。
- macOS 的 WKWebView 不支持透明背景（`opaque is not implemented on macOS`），已按可选步骤跳过；iOS/Android 支持。Windows/Linux 未验证，应用在这两个平台显示源码回退。iOS 与 Android 的真实网页视图尚未在本次运行中验证。
