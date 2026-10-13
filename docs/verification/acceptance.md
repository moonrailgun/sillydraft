# 需求与验证记录

验收基线：`docs/product-spec.md` 的 16 条要求及 ST 文档的 10 个兼容案例。测试使用本地数据和模拟协议服务；本地构建、模拟器操作、远程 CI、真实模型效果分别记录。

## 产品要求

| 编号 | 交付与测试证据 | 边界 |
| --- | --- | --- |
| 1 书架 | `bookshelf/`、`app_flow_test.dart`、`native_workflow_test.dart`：创建、属性、搜索、归档/恢复、示例 | 全文搜索最多返回 200 项 |
| 2 正文 | Quill、不可变版本与 CAS；`story_repository_test.dart`、`editor_flow_test.dart`、`task_runner_test.dart`；原生中文拼音输入截图 | 自动保存无法拦截系统强制终止 |
| 3 阅读器 | `reader_flow_test.dart`、`reader_presentation_test.dart`、`agent_flow_test.dart`、原生编辑→阅读→数据库重开 | 只展示已保存正文与资产 |
| 4 Agent 隔离 | `editor_agent_test.dart`、`proposal_flow_test.dart`、`task_runner_test.dart`：工具范围、候选采纳、并发冲突、删除会话 | 不把模型生成建议自动当事实 |
| 5 角色卡 | `st_import_test.dart`、`resource_library_test.dart`、`card_start_flow_test.dart`：V1/V2/V3、PNG/CHARX、备用开场、身份映射、加密原文 | JSON 分享不包含卡片二进制附件 |
| 6 ST 预设 | 下方 10 项映射；`preset_editor_test.dart` 覆盖手机完整聊天预设/提示词包的顺序、开关、深度、未知字段及旧版本不变 | 按受测能力兼容，未实现扩展明确诊断 |
| 7 模型与示例 | 设置、安全存储、四类模型角色、`provider_test.dart`、`remote_runner_flow_test.dart`、原生平台本机密钥文件读写删除 | OpenAI 兼容及个人 runner；无真实付费模型测试 |
| 8 旁路资料 | `lore_repository_test.dart`、`lore_flow_test.dart`：资料类型、来源、计划/推测、AI 建议、过期与跨故事位置拒绝 | 作者审阅后采纳 |
| 9 关系和地图 | `map_flow_test.dart`、关系端点/方向校验、地图坐标/路线校验；原生带底图地图截图 | 关系图布局是展示状态，资料关系本身持久化 |
| 10 分支 | `branch_flow_test.dart`、历史分叉与变量投影、候选选择幂等、分支比较；原生较早场景分叉截图 | 不合并未选中候选；版本和分支是不同概念 |
| 11 插画 | `asset_library_test.dart`、`image_provider_test.dart`、`illustration_task_test.dart`、`illustration_flow_test.dart`；原生封面、地图、正文插画 | 图片经过格式/大小校验及元数据清理；失败不改正文 |
| 12 任务 | `task_store_test.dart`、`task_runner_test.dart`：输入快照、流式输出、取消、重启、工具记录、明确重试 | 直连流中断后只保留结果，不冒充网络续传 |
| 13 离线/远程 | `server/test/runner_http_test.dart`、真实 `process_restart_test.dart`：鉴权、断开继续、查询恢复、缺失不重提、旧结果 CAS、插画恢复、SIGKILL | 可选单人服务，无多租户账户；编辑工具留在客户端 |
| 14 迁移 | `publication_export_test.dart`、`project_backup_test.dart`、`project_sync_test.dart`、`transfer_flow_test.dart`；实际 EPUB/系统分享截图 | 手动全项目同步、强 ETag、保留冲突副本；EPUB 已检查 XML/manifest，未运行独立 EPUBCheck |
| 15 跨端 | 五套平台工程；菜单/快捷键/面板/搜索/缩放/退出保护测试；Android、iOS、macOS 原生操作截图 | Windows/Linux 原生构建与运行待对应宿主；iOS 原生分享打开已验证，系统“存储到文件”完成未自动化验证 |
| 17 HTML 界面 | `html_blocks_test.dart`、`tavern_bridge_test.dart`、`html_block_flow_test.dart`、macOS 真实网页视图 `html_render_test.dart`；见 [HTML 界面验证](html-rendering.md) | 内置酒馆助手常用接口，不运行脚本库；Windows/Linux 显示源码 |
| 18 MVU 变量 | `mvu_test.dart`、`macro_variable_test.dart`、`variables_flow_test.dart`；见 [MVU 验证](mvu.md) | 内置 MagVarUpdate 的初始化、命令、schema、宏与变量管理器；不运行 MVU Zod 等脚本，额外模型解析未实现 |
| 16 交付 | 锁文件、`docs/building.md`、`docs/user-guide.md`、`server/README.md`、GitHub Actions、签名配置 | CI 尚未发布运行；没有商店发布或公证 |

核心测试文件都在 `packages/sillydraft_core/test/`，界面测试在根目录 `test/`。原生证据见 [平台记录](native-platforms.md)、[编辑阅读](editor-reader.md)、[资料分支](lore-branches.md)、[插画](illustrations.md)、[迁移](transfer.md)。

## ST 兼容案例

固定 ST 提交 `06bde939fb1e9c4c8d8641d810f0a916b5bce127`。官方文件附有哈希与许可证；`packages/sillydraft_core/tool/capture_st_reference.mjs` 在隔离 Node VM 中执行实际 ST 注入和指令序列化函数。其他语义使用固定输入、源码对应断言与边界样本，不把这些测试称为整个浏览器运行时的等价认证。

| 案例 | 证据 |
| --- | --- |
| 1 格式/未知字段 | `st_import_test.dart` 区分聊天、提示词包、组合模板；`resource_library_test.dart` 加密原件、字段往返与版本化 |
| 2 100001/启停/引用 | `st_compiler_test.dart` 使用 100001 并排除关闭条目；导入测试对缺失引用/重复标识报告诊断；手机条目编辑保留 100000 组 |
| 3 注入 | 同深度角色分组、次序与触发对照固定 ST 输出；空条目与深度在请求快照中可查 |
| 4 覆盖 | 卡片主提示词/历史后指令、forbid_overrides 与 original 宏的编译测试 |
| 5 宏与副作用 | 嵌套/条件/局部与全局变量、一次预览编译复用；候选采纳事务与历史分叉变量投影 |
| 6 世界书/历史 | 触发/递归/预算与未来、其他分支、未采纳内容排除；资料证据时间位置检查 |
| 7 文本模板 | Handlebars 后宏处理、指令序列、前后缀、换行、停止串与继续模式；实际 ST 默认模板夹具 |
| 8 正则 | 来源顺序、阶段、捕获替换、深度；`manuscript_presentation_test.dart`、`reader_presentation_test.dart` 验证显示专用规则实际呈现，正文/导出不变，原始输出独立保留 |
| 9 模型能力/凭据 | `provider_test.dart` 预填和参数诊断；资源导入不改变连接，普通导出清理已识别凭据；runner 由服务端控制上游目的地 |
| 10 产物/版本 | 原始响应、处理后的候选和依据版本各自持久化；`story_repository_test.dart`、远程 HTTP 测试拒绝旧候选覆盖 |

预算是估算 token，随机 pick 的种子与 ST 聊天标识不同；local/global 变量额外受项目和分支约束。未实现世界书定时/分组/自动化、未知宏/helper、任意浏览器扩展和专用后端。用户未提供特定社区预设，本次没有宣称兼容其全部扩展。

## 本轮验证与独立审查

最终核心 90 项、Flutter 33 项、服务端 9 项测试通过，分析器均无问题。独立审查发现的 5 项重要问题已完成一次修复并通过回归测试；无延后的小问题。具体复现、修复及证据见 [最终审查](final-review.md)。原生平台与签名验证状态分别记录在平台文档中。

Android Release 开发构建通过；未提供正式签名的 Release 被构建脚本明确拒绝。该验证只使用开发密钥。平台包不会自动上传或发布。
