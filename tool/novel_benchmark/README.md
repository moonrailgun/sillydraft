# 小说质量 benchmark

SillyDraft harness 接受 `fixture.json story-id output-dir base-url [reviewer-model]`。可选第五个参数把独立审读模型存为正式 `review` 职责，正文、规划、返修和资料整理仍沿用原有模型；不传则审读沿用正文模型。首次运行保存 `run-config.json`，续跑必须使用相同故事和完整模型连接配置；已有未记录配置的旧作品不能中途增加审读模型。四参数旧入口保持兼容。

协议及适用边界见 [novel-benchmark-protocol.md](../../docs/novel-benchmark-protocol.md)。
本次结果、原文证据和评审缺项见 [完整评测报告](../../docs/novel-benchmark-report.md)。
这些入口调用真实生产写作流程；生成和 `judge` 命令会调用真实模型。
`self-check`、`metrics` 和 `summarize` 只使用本地数据。

在仓库根目录启动记录代理，终端会打印端口，同时写入输出目录的 `proxy.json`：

```sh
python3 tool/novel_benchmark/capture_proxy.py build/novel-benchmark/2026-11-05
```

以下以端口 `50157` 和开发故事 `tidemark` 为例；保留故事 ID 为 `nightbus`。
每次独立生成使用新目录。同一目录只能运行一个进程，已完成章节可续跑；
恢复前先核对日志、原生任务状态和进程，不能把仍在工作的任务重复启动。
旁路整理失败或已由原生恢复流程标记为中断时，会记录状态和错误后继续，不重新抽样；未结束的任务须先人工核对。主机退出后先备份并确认进程已结束，再调用原生恢复接口；不要把仍在工作的任务标记为中断。

```sh
# 在 packages/sillydraft_core 目录执行：
dart run tool/novel_benchmark.dart ../../tool/novel_benchmark/fixtures.json tidemark ../../build/novel-benchmark/2026-11-05/sillydraft-tidemark http://127.0.0.1:50157/sillydraft-tidemark/v1

# 在仓库根目录执行，InkOS checkout 须已构建 packages/core：
node tool/novel_benchmark/inkos.mjs build/novel-benchmark/inkos-source tool/novel_benchmark/fixtures.json tidemark build/novel-benchmark/2026-11-05/inkos-tidemark http://127.0.0.1:50157/inkos-tidemark/v1

# 两部同输入作品均完成全部 16 章后，在仓库根目录执行：
python3 tool/novel_benchmark/evaluate.py judge tool/novel_benchmark/fixtures.json tidemark build/novel-benchmark/2026-11-05/sillydraft-tidemark build/novel-benchmark/2026-11-05/inkos-tidemark build/novel-benchmark/2026-11-05/judging-baseline-tidemark http://127.0.0.1:50157/judging-baseline-tidemark/v1
```

InkOS 本次固定在 `53adac4e974b54dafda975edc4edd07cad364c18`，安装及构建命令为
`corepack pnpm@10.32.1 install --frozen-lockfile` 和
`corepack pnpm@10.32.1 --filter @actalk/inkos-core build`。
SillyDraft 使用其锁文件：在核心包执行 `dart pub get --enforce-lockfile`。

本地检查和统计：

```sh
python3 tool/novel_benchmark/capture_proxy.py --self-check
python3 tool/novel_benchmark/evaluate.py self-check
python3 tool/novel_benchmark/evaluate.py metrics build/novel-benchmark/2026-11-05/sillydraft-tidemark
python3 tool/novel_benchmark/evaluate.py summarize build/novel-benchmark/2026-11-05/judging-baseline-tidemark
node --check tool/novel_benchmark/inkos.mjs
node tool/novel_benchmark/inkos_test.mjs build/novel-benchmark/inkos-source
# 在 packages/sillydraft_core 目录执行，无真实模型请求：
dart test tool/novel_benchmark_test.dart
```

每个生成目录保存冻结输入、原生状态、逐章结果和 `http/` 下的原始请求与响应。
SillyDraft 逐章导出正文，InkOS 在整本完成后导出，因此途中不能用顶层 TXT 数量比较进度。
InkOS 途中查看 `works/<故事 ID>/source/chapters/index.json`。
统计中的汉字数由同一个函数重算，不混用两个系统自身的字数口径。

盲评每次发起四个请求：两个评委分别评两种 A/B 排序。
`unblinding.json` 保存映射和输入哈希，评委请求中不含系统名称。
无效引文、格式错误或截断输出不会自动重试，原始产物全部保留。
人工确认失败原因后才可指定新的 `--attempt 2`；统计会列出全部有效尝试，不能择优。
若只有部分评审失败，可同时传 `--only 0:0 --only 0:1`（评委索引:排序索引），只补跑已诊断的失败项，避免重复请求已通过的评审；不改变提示词或校验规则。
本次引文提示曾在查看分数前修订，原因及完整重跑规则见协议；修订前对照保留在 `judging-control-tidemark`，修订后主对照在 `judging-control-tidemark-evidence-v2`，不混合统计。每项最多三次尝试，超过则报告缺项。
`http/` 的 usage 是接口返回量，不等于供应商实际计费量，缺失项也不视为零成本。

本次未修改基线保存于 `build/novel-benchmark/2026-11-05/sillydraft-baseline-source.tar`，
来自 `1375544eb15a6eba359f2c0051ca1e42bf1746f2`。
对照生成使用该源码和同一份 benchmark 入口，保留新的独立数据库及请求记录。

## 长篇连续性改进复测

新实验使用 `fixtures-continuity.json`，开发故事为 `projection`，确认故事为 `bindery`。
生成前冻结的改进范围和达标标准见 [长篇连续性方案](../../docs/longform-continuity-plan.md)。
确认集的评分在开发版选择冻结后才解封；不能使用确认集挑选实现。

汇总器对每位评委的两个排序等权平均，保留全部有效尝试；缺少任一单元不算达标。
连续性、因果、伏笔回收三维均值差与八维总分差都不得低于 InkOS 0.3 分，两位评委均须通过。

```sh
python3 tool/novel_benchmark/summarize_continuity.py --self-check
python3 tool/novel_benchmark/summarize_continuity.py build/novel-benchmark/2026-11-06-continuity/judging-v1-projection build/novel-benchmark/2026-11-06-continuity/sillydraft-v1-projection
```

完整小说、请求、评分尝试及版本冻结记录保存在 `build/novel-benchmark/2026-11-06-continuity/`。
该目录是本地实验产物，复现或交接时需单独保留；不把接口返回的 token 用量当成实际账单。

## 补充核验评委可靠性

`audit_evidence.py` 使用 Kaon Router 的 `tianji/kaon/gemini-4-argon`，分别阅读匿名完整作品，按同一组检查项目核对事实、因果和伏笔。程序给段落编号并回填原文，保留原始请求、响应、无效输出和全部出处。它只允许开发故事；确认集仍封存。该审计用于诊断，不代替原有双评委、双排序评分，也不改变达标门槛。

```sh
# 本地测试，不调用模型：
python3 -m unittest discover -s tool/novel_benchmark -p 'audit_evidence_test.py'

# 以下调用真实模型；输出目录必须未使用过：
python3 tool/novel_benchmark/audit_evidence.py calibrate tool/novel_benchmark/evidence-audit-spec.json build/novel-benchmark/2026-11-06-continuity/audit-gemini-calibration-001 http://127.0.0.1:57443/audit-gemini-calibration-001/v1
python3 tool/novel_benchmark/audit_evidence.py audit tool/novel_benchmark/fixtures-continuity.json projection build/novel-benchmark/2026-11-06-continuity/sillydraft-v3-projection tool/novel_benchmark/evidence-audit-spec.json build/novel-benchmark/2026-11-06-continuity/audit-gemini-v3-projection-001 http://127.0.0.1:57443/audit-gemini-v3-projection-001/v1
```

短题校准通过、编号有效都不能证明整本判断正确。关键结论仍须核对前后文、可能的解释和实际运算；不能因为评委漏检就手工改分，也不能反复补评到出现有利分数。

## 段落编号双评委盲评

原逐字引文协议用尽补评次数后，按[预登记修订](../../docs/novel-evaluation-amendment.md)单独重评基线与 V3。维度、模型和门槛不变，程序用作品前缀的段落编号回填原文；原协议的失败和分数保留，不混合汇总。每单元最多三次，已有有效单元不重跑。

```sh
# 本地测试，不调用真实模型：
python3 -m unittest discover -s tool/novel_benchmark -p 'evaluate_sources_test.py'

# 调用真实模型；同一入口也用于冻结后的确认集：
python3 tool/novel_benchmark/evaluate_sources.py tool/novel_benchmark/fixtures-continuity.json projection build/novel-benchmark/2026-11-06-continuity/sillydraft-v3-projection build/novel-benchmark/2026-11-06-continuity/inkos-projection build/novel-benchmark/2026-11-06-continuity/judging-sources-v3-projection http://127.0.0.1:57443/judging-sources-v3-projection/v1
```

`unblinding.json` 记录新协议及脚本哈希；每次 `.resolved.json` 保存被引段落全文。汇总仍用 `summarize_continuity.py`。编号有效不代表论证正确，仍须对关键结论核查前后文。
