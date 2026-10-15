# 桌面远程作品库与扫码传输设计

## 目标

1. **桌面远程作品库**：桌面端在设置里打开“允许手机连接”，不用终端、不写配置文件。手机启动时用本机作品库，可在书架切换到已配对的桌面：书架、正文、资料、任务全部读写桌面那一份，生成任务在桌面用桌面的模型连接与密钥执行，手机退到后台不影响任务。
2. **扫码传输**：资源库四类资源（角色卡、预设、世界书、正则）、技能、人设、模型连接，都能用二维码在设备间快速传一份副本。

网络先做局域网；经 Tailscale 等互通网络的外网访问能用，但不为弱网专门优化。

本次不做：手机本地作品库搭配桌面模型的组合（现有独立执行器 `server/` 保持原样，可继续用于这种场景）、离线缓存与断线写入排队、多用户/多密钥权限、批量传输、桌面作为客户端连接另一台桌面的入口。

## 现状

- 作品库是单个 drift/SQLite 库，`StoryRepository` 全部用手写 SQL（`customSelect` / `customStatement`），drift 不会自动发表变更通知。界面刷新靠仓库自己的 `_changes` 流：`_write` 提交事务后发出 `tasksOnly` 标志（`story_repository.dart:85`），`lib/app/services.dart:436`、`:444` 据此递增 revision。
- `AppServices` 由 `AppServices.open()` 组装一次，`SillyDraftApp` 用 `servicesProvider.overrideWithValue` 注入；`registerDraft` / `_drafts` 用于在离开前保存草稿。
- 任务由 `TaskRunner`（`tasks/task_runner.dart`）在本进程执行：`start` 建任务行后立即 `_launch`；`wait`、`cancel`、`resume`、`reconnectRemote`、`respondToImageConfirmation` 都依赖进程内状态。待确认的生图请求写在 `task.result['imageConfirmation']`，界面据此显示（`agent_screen.dart:912`）。启动时 `recoverInterrupted` 把所有执行中的任务标为中断。
- 任务输入冻结了连接配置（不含密钥）；执行时 `providerFactory` 按连接 ID 从本机 `secrets.json` 取密钥。模型连接列表存在库内设置 `connections`，密钥不进库。
- 文件（插图、角色卡图等）由 `AssetLibrary` 按内容哈希存在数据目录 `assets/`，`file()` 返回本地文件。
- 导入的 ST 原文件经 `ResourceLibrary` 用本机 `secrets.json` 中的 `resources/aes256` 加密保存；`original(id)` 解密取回，`import(...)` 导入。
- 保存正文已检查 `expectedRevisionId` 并抛 `RevisionConflict`；采纳候选检查 `baseRevisionId`。
- drift 2.35.2 提供 `package:drift/remote.dart`（标记 experimental）：`DriftServer(executor).serve(channel)` 与 `connectToRemoteAndInitialize(channel)`，协议要求两端 drift 版本一致；客户端 `notifyUpdates` 会经服务端转发给其他客户端。

## 连接与安全

**桌面：设置 → 手机连接**

- 开关“允许手机连接”：打开后监听 `0.0.0.0`，默认端口 `8790`（可改）；关闭即停止监听并断开已连接设备。开关状态保存在本机设置，下次启动按此恢复。
- 首次打开时生成：
  - 访问密钥：32 字节随机数，存本机 `secrets.json`（`remote/access-key`）。
  - 自签 TLS 证书：证书与私钥一起存 `secrets.json`（`remote/tls`）。手机作为分享方时也用它。
- 页面显示二维码与可复制的连接链接：
  `sillydraft://connect?host=<地址>&port=<端口>&key=<访问密钥>&fp=<证书 DER 的 SHA-256>&name=<桌面名称>`
- 地址默认取第一个局域网 IPv4；有多个网卡（如 Tailscale `100.x`）时可下拉切换，二维码随之更新。
- “重新生成密钥”使所有已配对设备失效。
- 页面明确提示：持有链接即可读写桌面全部作品，并可用桌面的模型发起付费调用。

**传输与鉴权**

- 全部走 HTTPS / WSS，客户端只接受指纹与链接中 `fp` 相同的证书（`HttpClient.badCertificateCallback` 比对 SHA-256），不信任系统 CA，也不接受其他证书。
- 每个请求与 WebSocket 握手带 `Authorization: Bearer <访问密钥>`；服务端比较 SHA-256 哈希，常量时间。同一来源 IP 一分钟内失败 10 次后拒绝该 IP 五分钟。
- 不接受重定向。

**手机配对**

- 扫码或粘贴连接链接，两者同一格式。配对前先 `hello` 校验证书、密钥与版本，成功才保存。
- 配对列表（名称、地址、密钥、指纹）存手机本机 `secrets.json`，不进作品库、备份、同步。

新增依赖：`basic_utils`（生成自签证书，纯 Dart；证书用 EC P-256，手机上生成 RSA 太慢）、`qr_flutter`（显示二维码）、`mobile_scanner`（扫码；iOS `NSCameraUsageDescription`，Android 由插件声明 `CAMERA`）。iOS 访问局域网设备另需 `NSLocalNetworkUsageDescription`。核心包把已在锁文件中的 `stream_channel` 改为直接依赖。

## 桌面服务

纯 Dart，放在核心包 `packages/sillydraft_core/lib/src/remote/`。一个端口，所有接口都要求鉴权：

| 接口 | 行为 |
| --- | --- |
| `GET /v1/hello` | 返回应用版本与构建号、桌面名称、资源密钥（同一构建即同一数据库结构） |
| `WS /v1/db` | drift 远程协议（`serialize: true`） |
| `WS /v1/events` | 双向的写入通知 `{"tasksOnly": bool}`，兼作连接存活检测 |
| `POST /v1/provider/text` | 直接模型调用：`{connection, request}`，响应为逐行 JSON 事件流 |
| `POST /v1/provider/image` | 直接生图：`{connection, request, references}`，返回图片 |
| `POST /v1/provider/workflow` | 读取 ComfyUI 服务端工作流：`{connection, filename}` |
| `POST /v1/tasks/start` | `{branchId, kind, input, chapterId?, baseRevisionId?, retryOf?}` → 在桌面 `TaskRunner.start`，返回任务 |
| `POST /v1/tasks/{id}/cancel` | 桌面 `cancel` |
| `POST /v1/tasks/{id}/resume` | 桌面 `resume`（新任务、可能重新计费） |
| `POST /v1/tasks/{id}/reconnect` | 桌面 `reconnectRemote` |
| `POST /v1/tasks/{id}/confirm` | `{confirmationId, approved}` → `respondToImageConfirmation`，返回是否生效 |
| `GET /v1/assets/<hash>.<png\|jpg>` | 文件字节 |
| `PUT /v1/assets/<hash>.<png\|jpg>` | 上传文件；服务端按 `installBackupFile` 校验文件名与哈希 |

**数据库共享**

- 桌面继续用自己的数据库连接；`DriftServer` 包装同一个执行器，`closeConnectionAfterShutdown: false`，关闭开关不关闭桌面自己的库。迁移只由桌面执行，手机连接时不迁移（握手已保证版本一致）。
- **跨设备刷新**：仓库增加 `localWrites`（本仓库 `_write` 提交的写入）与 `notifyExternal(tasksOnly)`（把别处的写入并入 `changes` / `contentChanges`）。手机把 `localWrites` 经 `WS /v1/events` 发给桌面；桌面并入自己的仓库并转发给其他手机，同时把自己的 `localWrites` 发给所有手机。任一方写入，各方界面都刷新，界面代码不改。不用 drift 自带的表通知：它绑定单个远程连接，断线重连换连接后就断了。
- 仓库内缓存：`_displayCache` 每次先从库里读出写作配置与人设作为键再比对（`display_store.dart`），`_listedInputs` 只缓存创建后不变的任务输入，跨设备写入不会让它们读到旧值。
- **事务中途断线**：drift 2.35.2 的服务端在通道关闭时回滚该客户端未完成的事务（`server_impl.dart` 的 `_abandonExecutorsOf`），计划第一步用测试钉住。剩下的风险是半开连接迟迟不关闭：两个 WebSocket 都设 10 秒心跳，失联的连接在约 20 秒内关闭并回滚。

**任务在桌面执行**

- 核心包抽出任务控制接口（`start`、`wait`、`cancel`、`resume`、`reconnectRemote`、`respondToImageConfirmation`、`recoverInterrupted`、`close`）。`TaskRunner` 是本地实现；远程实现把 `start` 等转发到上面的接口，`wait` 监听 `changes` 并重读任务状态（不含冻结快照，同时只读一次，期间的改动读完再补读一次）直到不再活跃，再读回完整任务，`recoverInterrupted` 为空操作（手机绝不改桌面的任务）。`WritingService` 等服务改为依赖该接口。
- 手机仍在本地编译 ST 请求（读的是桌面库），冻结输入交给桌面执行；上游密钥只在桌面。桌面的本地订阅（Claude Code / Codex）暂时只在桌面上用：手机发来的任务、任务操作与模型代理请求中含本地订阅连接时，桌面以 403“本地订阅只能在桌面上使用”拒绝（手机写的提示词或参数会到达能读桌面文件的命令行工具，加固前不开放）。
- **直接模型调用**：不建任务的调用（人设 AI 补全与参考图、自动拟章节名、读取 ComfyUI 工作流）在手机上换成代理 provider，经 `/v1/provider/*` 由桌面的 provider 执行。取消即断开请求，桌面随之取消上游调用。
- **端点校验**：桌面执行任何任务或代理调用前（含重新生成、取回远程结果、取消这些读取已存任务输入的动作），按连接 ID 取自己保存的连接，要求协议、`baseUrl`、`command`、`allowInsecureHttp` 与请求中的一致，否则拒绝；缺少这些字段的连接形对象同样拒绝。重新生成只读一次任务行，校验后用这同一份输入新建任务，手机在校验之后改写任务行也影响不到这次运行。
- **密钥与端点绑定**：连接列表存在共享的库里，手机能改写，所以上面的校验只是提前拒绝。真正的防线在桌面本机：保存连接时把它的端点（上述四项）写进 `secrets.json`（`endpoint/<连接 ID>`），桌面每次取用 `model/<连接 ID>` 密钥前比对，不一致就不交出密钥。开启共享时为已有密钥补写端点记录（此刻还没有手机能写库）。桌面自己的设置页同样只在端点与记录一致时取用已存密钥：获取模型列表、ComfyUI 请求、密钥栏留空的“测试连接”和扫码分享连接，遇到被改过地址的连接都以“连接地址已在本机之外改动，请重新输入密钥”拒绝；不填新密钥保存这样的连接也会拒绝，填了新密钥才保存并把记录改到新地址（作者自己改了地址也要重输密钥）；打开这样的连接时对话框提示“此连接的地址或命令在本机之外被改动过，可能来自已配对的手机。请核对后重新输入密钥并保存。”。在表单里新输入的密钥随时可用。这样即使链接泄露，也无法把桌面的密钥发往别的地址。

**文件**

- 远程实现的 `AssetLibrary`：读取按哈希下载，缓存到手机缓存目录（内容寻址，缓存永不失效）；`file()` 返回缓存文件。导入走上传接口。`pruneOrphans` 只由桌面执行。

**资源密钥**

- `hello` 返回的资源密钥只保存在手机内存，供 `ResourceLibrary` 解密桌面的 ST 原文件；切回本机即丢弃。

## 手机端

**切换入口**

- 书架标题处显示“本机 ▾”，菜单：本机、已配对桌面（名称与地址）、扫码或粘贴链接添加、管理配对（删除）。
- 远程模式下书架与设置顶部常驻“桌面：<名称>”。
- 每次启动都在本机，不自动连接。两边作品库完全隔离，切换不改手机本地数据。
- 切换流程：先刷新全部 `_drafts`；本机有运行中的任务时先提示“切换会中断 N 个本机任务”；关闭当前 `AppServices`，组装新的（远程模式：远程数据库连接、远程任务控制、远程文件、内存中的资源密钥；`secrets` 仍是手机本机的），以新 key 重建 `ProviderScope`，回到书架。

**远程模式的限制**

- 不能新增、编辑模型连接，也不能“检查连接”（密钥在桌面），显示“连接在桌面管理”；可以给各任务角色选择连接（库内设置）。
- 手机看不到桌面的本地订阅（Claude Code / Codex）连接：连接列表、任务角色与旁路整理都不提供它们（只能在桌面上用，见上文）。
- 导出、备份可用，图片经网络读取，较慢。
- 更新检查、手机本机密钥与本机连接不受影响。

**断线**

- WebSocket 断开、桌面睡眠或关闭开关：顶部提示条“与桌面断开，正在重连”，按退避自动重试；桌面明确停止共享时提示并提供“切回本机”。
- 远程数据库连接包一层可重连的执行器：仓库对象与界面状态不重建，编辑器中未保存的文字保留。断线期间读写报“与桌面断开”，不排队补写。
- 重连成功先重新 `hello`，再发一次全量刷新通知，补上断线期间的改动。
- 任务在桌面继续，不受影响。

**版本不一致**：`hello` 要求两端应用版本与构建号完全一致（drift 远程协议要求同版本），否则拒绝连接并提示“桌面 x.y.z，手机 a.b.c，请升级到同一版本”。

**同时编辑**：与同一台设备开两个窗口一致。正文保存的 `RevisionConflict`、候选采纳的 `baseRevisionId` 检查照常生效；手机发起的任务在桌面任务列表可见，两边都能取消；桌面退出时运行中的任务按现有逻辑中断，手机看到 `interrupted`。

## 扫码传输

**可分享**：资源库四类资源、技能、人设、模型连接（总是含 API Key）。各自的菜单加“扫码分享”。

**流程**

- 分享方开一个临时传输会话，复用桌面服务的证书（未生成时同样生成），监听同一端口；未开“允许手机连接”时只临时开放传输接口，不暴露作品库。
- 二维码 / 链接：`sillydraft://receive?host=…&port=…&t=<一次性令牌>&fp=<证书指纹>`。令牌 32 字节随机，分享页开着时有效，最长 10 分钟，被接收一次即失效，关闭页面立即失效。页面显示“已被接收”。
- 接收方扫码或粘贴链接（桌面无相机时粘贴），`GET /v1/share/<令牌>` 经证书锁定下载，显示预览（名称、类型；连接标“含 API Key”），确认后导入。
- 传输内容 `{format: 1, kind, name, ...}`，带格式版本；接收方不认识的版本或类型报错，不猜测导入。

**各类内容**

- 资源库资源：传当前版本——原文件（`ResourceLibrary.original`，保留角色卡图片与附件）加当前版本数据；接收后与发送方当前版本内容一致。同源文件已存在时沿用现有去重。
- 技能：`AgentSkill.raw`，接收后经 `SkillLibrary.install` 安装；同名技能先询问是否覆盖。
- 人设：文字字段与参考图字节。
- 模型连接：`connection.raw` 加 API Key；导入为新连接（ID 冲突时新分配），密钥写入接收方本机 `secrets.json`。本地订阅（Claude Code / Codex）连接在不支持的平台上拒绝导入并说明。

**限制**：两台设备需网络互通；单个资源，不批量；手机作为分享方时分享页须留在前台（系统会挂起后台应用的监听）。

## 测试

核心（`dart test`，回环地址起服务端与客户端，模型用本地协议模拟服务器）：

- 鉴权：错误密钥拒绝、失败计数封锁；证书指纹不符拒绝；版本不一致拒绝。
- 桌面仓库与手机仓库互见写入并触发 `changes` / `contentChanges`。
- 远程启动的任务在桌面执行；远程取消、生图确认生效；客户端断开后任务照常完成，重连后 `wait` 得到终态。
- 文件读取、上传、缓存命中。
- 事务中途断线后锁被释放，桌面可继续写入。
- 断线重连后仓库对象不变并收到全量刷新。
- 传输会话：令牌一次性、过期失效、关闭失效；每类内容往返一致（资源含附件，连接含 API Key）；未知格式版本拒绝。
- 连接链接与接收链接的生成与解析。

界面（`flutter test`）：模式切换菜单与切换前的草稿保存、本机任务提示；断线提示条；远程模式连接设置只读；分享页与接收预览。

原生：相机扫码、真实局域网 / Tailscale 连接无法在 CI 运行，在 `docs/verification/` 补手动验证清单。

## 文档

更新 `docs/user-guide.md`（手机连接、模式切换、扫码传输）、`docs/product-spec.md`，AGENTS.md 架构一节加一行说明远程模块位置。
