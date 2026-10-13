# HTML 界面渲染验证（酒馆助手兼容）

对照对象：[JS-Slash-Runner（酒馆助手）](https://github.com/N0VI028/JS-Slash-Runner) `main` 分支的 `src/panel/render/iframe.ts`、`src/iframe/adjust_iframe_height.js`、`src/iframe/predefine.js`、`src/util/is_frontend.ts`、`src/function/chat_message.ts` 以及 `@types/function/*.d.ts` 的接口声明。本页记录 SillyDraft 内置实现与其对应关系、沙箱边界和已验证范围；未列出的接口视为不支持。

## 渲染规则

| 酒馆助手 | SillyDraft |
| --- | --- |
| 消息中的 `<pre>` 代码块，内容含 `html>`、`<head>` 或 `<body` 时替换为 iframe | `HtmlBlocks.find`：围栏代码块（任意语言）内容含同样标记，或语言标为 `html`/`htm`/`xhtml`，成为“前端块”；与 showdown 相同，以围栏开头的行即闭合围栏，同一行余下的文字（如正则替换后紧跟的 `<game>`）仍是正文；未闭合围栏延伸到正文末尾 |
| 其余 HTML 由 ST 的 markdown + DOMPurify 显示 | 行首的块级标签（`div`、`details`、`table`、`style`、`span` 等）到匹配闭合标签成为“片段块”，相邻片段合并；用 `package:html` 解析后删除 `script`/`iframe`/`object`/`embed`/`link`/`meta`/`base`、`on*` 属性、`srcdoc` 和 `javascript:`/非图片 `data:` 地址 |
| ST 默认不编码标签（`encode_tags` 关闭），DOMPurify 删除未知元素、保留其文字 | 正文中的标签和注释（`<game>`、`</game>`、`<!-- -->`）隐藏，文字照常显示；代码中的标签、`<主角>`、`a < b` 这类非标签保留。行内 `<b>`/`<i>` 只隐藏、不加粗斜体，`<br>` 不换行 |
| `srcdoc` 包裹：重置样式、`--TH-viewport-height`、`min-height: …vh` 改写、预加载 jQuery/lodash/Font Awesome/Vue/jQuery UI/Tailwind | `HtmlBlocks.document`：同样的重置样式和视口变量，`min-height` 改写逻辑逐条移植；预加载 lodash、jQuery 和 Font Awesome（jsdelivr 镜像），不预加载 Vue、jQuery UI、Tailwind |
| `ResizeObserver` 测量 `body.scrollHeight` 设置 iframe 高度 | 页面内按 `body.scrollHeight` 增长或收缩（与酒馆助手一致，普通折叠和收缩动画持续跟随实际高度）；仅当内容高度受框架约束时，每次 DOM 变化后允许收缩一次到可见内容底边（按 overflow 裁剪、忽略 fixed 层），避免 `body{height:100%}` 把框架锁在动画瞬间的高度，也避免视口比例面板反复缩小；`ResizeObserver`/`MutationObserver`/过渡结束/定时复测触发，经 `SillyDraftHeight` 通道回传（24–20000px） |
| 渲染深度、折叠代码块、流式渲染设置 | 不提供；设置中只有整体开关“渲染正文中的 HTML 界面”，阅读器可切换“显示原正文” |

## 接口对应

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
| `eventOn`/`eventOnce`/`eventMakeFirst`/`eventMakeLast`/`eventOnButton`/`eventRemove*`/`eventClear*`/`eventEmit`/`eventEmitAndWait`/`eventWaitOnce` | 页面内事件表；`eventEmit` 经宿主转发给同一页面的其他界面。宿主不产生 ST 生成/消息事件 |
| `initializeGlobal`/`waitGlobalInitialized` | 单个界面内有效，不跨界面共享对象 |
| `triggerSlash` | 见下表 |
| `toastr.*` | 提示条；`alert`/`confirm`/`prompt` 由网页视图回调弹出对话框 |
| `getCharData` | 角色卡字段（不含 `tavern_helper` 和 `regex_scripts` 扩展） |
| `SillyTavern.getContext()` | `chat`、`name1`、`name2`、`chatId`、`characters`、`eventSource`、`substituteParams`；`generate()` 提交输入框中的续写要求 |
| `#send_textarea` / `#send_but` | 隐藏的兼容输入框与发送按钮；赋值、`input`/`change`、点击发送直接续写下一章，同轮事件合并，空白不触发 |
| `Mvu` | 最小数据层：`getMvuData`/`replaceMvuData`/`getMvuVariable`/`setMvuVariable` 读写该章变量；不解析 `<UpdateVariable>`，`parseMessage` 原样返回旧数据 |
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
| `integration_test/html_height_test.dart`（macOS） | 真实 WKWebView：`details` 和带过渡动画的 `max-height` 面板各反复展开、收起两轮，外层高度从 660px 回到 60px |

2026-10-13 结果：核心 143 项、界面 68 项通过；macOS 真实网页视图集成测试结果见下文“运行记录”。真实角色卡《道渊》v5.4.2 的开场为完整 HTML 页面（烟花画布、`min-height: 100vh`、`getChatMessages`/`setChatMessage`/`triggerSlash` 兜底），其备用开场经角色卡正则变成角色创建界面，提交时执行 `/sys … | /cut N | /trigger`；两种结构都在上述测试中以缩减样本覆盖。该卡依赖的 MVU、ZOD、道渊工坊等酒馆助手脚本不运行，状态栏中依赖 `Mvu.parseMessage` 解析 `<UpdateVariable>` 的部分不会自动更新变量。

## 运行记录

2026-10-13，macOS arm64（Flutter 3.47.7，Swift Package Manager 集成，未安装 CocoaPods）：

- `flutter analyze`、核心包 `dart analyze` 无问题；`dart format` 检查通过。
- 核心 `dart test` 143 项通过（含本页 2 个新文件 26 项）；界面 `flutter test test` 68 项通过（含 `html_block_flow_test.dart` 5 项）。
- `flutter test integration_test/html_render_test.dart -d macos` 2 项通过，`✓ Built build/macos/Build/Products/Debug/SillyDraft.app`：
  - 缩减样本：WKWebView 内页面按 `--TH-viewport-height` 自测高度超过 300px；`getChatMessages`/`setChatMessage`/`getLastMessageId`/`getIframeName` 存在且首章有 2 个消息页；页面按钮经桥接把第一章切换为 `[重塑仙缘]` 并记录 `greetingIndex=1`；新网页视图中由角色卡正则生成的创建页读取 `getCharData().name` 与 `getCurrentMessageId()`，`insertOrAssignVariables` 写入该章 `stat_data`；`/sys … | /cut 0 | /trigger` 打开“改写整章”写作请求并预填要求。
  - 真实角色卡《道渊》v5.4.2（PNG，从本机 Downloads 导入，若文件不存在则跳过）：开场页 `#info-card`、`#fireworks-canvas` 和 `switchToSecondGreeting` 均存在，首章 2 个消息页；调用卡片自己的 `switchToSecondGreeting()` 后第一章变为 `[重塑仙缘]`，随后显示的角色创建页 `document.title` 为“道渊”、正文文本长度 337。该卡依赖的外链脚本（MVU 等）未运行，因此状态栏中的变量自动更新不在本次验证范围。
- macOS 的 WKWebView 不支持透明背景（`opaque is not implemented on macOS`），已按可选步骤跳过；iOS/Android 支持。Windows/Linux 未验证，应用在这两个平台显示源码回退。iOS 与 Android 的真实网页视图尚未在本次运行中验证。
