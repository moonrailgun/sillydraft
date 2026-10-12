# 最终审查与修复

独立审查覆盖初始文档到 `4e2c422` 的整套项目，实现者随后进行一次修复并验证。审查发现 5 项重要问题，全部已修复；无严重问题或延后的小问题。没有把“审查过”当作全部平台和全部模型已验证。

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| 远程重连失败清空已收到内容 | 保留持久化正文和推理，重放追上后才替换；缩短或分歧结果不能被采纳 | 核心回归从空字符串失败到通过；服务端原 ID 重连、取消、进程重启套件通过 |
| 合法加密备份含无效嵌套数据 | 恢复前检查来源与场景/历史版本、变量字符串映射、资料字段、写作/阅读设置和正文属性 | 9 种带正确口令、MAC 和清单的错误载荷均被拒绝，原项目指纹与可读性保持不变 |
| macOS 所选文件旁的临时文件没有沙箱权限 | 使用 Foundation 同卷 `itemReplacementDirectory` 与替换 API；通过原生通道调用 | 2 项 XCTest；文件范围沙箱先证明旧写法被拒绝，再验证新建/替换；原生通道读回验证 |
| ST 显示专用正则未接入界面 | 候选和阅读器使用任务中冻结的规则与宏上下文；提供原文切换 | 正则改变可见内容，但正文、原始响应和 TXT 导出保持不变；不提交显示阶段变量副作用 |
| 阅读器忽略段落格式 | 解析 Delta 的标题、列表和引用；可见位置映射回原正文 | 标题样式、有序/无序标记、引用与书签回归；原生截图 |

最终自动测试：核心 90 项、Flutter 33 项、服务端 9 项通过；Flutter、核心和服务端分析器均无问题。137 个 Dart 文件格式检查通过。macOS、iOS 和 Android 的最终原生执行及交付包状态见 [平台记录](native-platforms.md)。

macOS 导出的权限依据是 [Apple 的沙箱文件访问说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) 和 [Foundation 文件替换 API](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:))。可运行 `python3 tool/verify_macos_atomic_export.py` 重现“只允许写所选文件”的权限条件；这个脚本不声称自动操作过 NSSavePanel。

仍需实际环境验收的项目：Windows/Linux 原生构建与运行、远程 GitHub Actions、真实模型质量与延迟、iOS 真机/商店签名、macOS 分发签名和公证。代码及 CI 已提供，未发布或调用付费模型。

实施中的决定和逐任务验证记录会保存在 [实施记录](implementation-log.md)，包括所有取舍及判断错误时的成本。
