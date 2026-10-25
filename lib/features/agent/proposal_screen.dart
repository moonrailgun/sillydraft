import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../lore/sidecar.dart';
import '../editor/paragraph_comparison.dart';
import 'agent_providers.dart';

final _comparisonProvider =
    FutureProvider.family<
      ({DocumentRevision base, Chapter current, String before, String after}),
      String
    >((ref, id) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider),
          proposal = await ref.watch(proposalProvider(id).future);
      return (
        base: await repo.getRevision(proposal.baseRevisionId),
        before: (await repo.presentRevision(proposal.baseRevisionId))
            .content
            .text,
        after: (await repo.presentProposal(proposal.id)).content.text,
        current: await repo.getChapter(
          branchId: proposal.branchId,
          chapterId: proposal.chapterId,
        ),
      );
    });

class ProposalScreen extends ConsumerStatefulWidget {
  const ProposalScreen({super.key, required this.proposalId});
  final String proposalId;
  @override
  ConsumerState<ProposalScreen> createState() => _ProposalState();
}

class _ProposalState extends ConsumerState<ProposalScreen> {
  bool _busy = false;
  bool _displayRules = true;
  Future<void> _apply(bool accept) async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      if (accept) {
        final proposal = await repo.getProposal(widget.proposalId);
        await repo.acceptProposal(widget.proposalId);
        startSidecarQuietly(
          ref.read(servicesProvider),
          branchId: proposal.branchId,
          chapterId: proposal.chapterId,
        );
      } else {
        await repo.rejectProposal(widget.proposalId);
      }
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '未写入的正文',
    body: AsyncView(
      value: ref.watch(proposalProvider(widget.proposalId)),
      builder: (proposal) => AsyncView(
        value: ref.watch(_comparisonProvider(proposal.id)),
        builder: (comparison) {
          final stale =
              comparison.current.revisionId != proposal.baseRevisionId;
          final pending = proposal.status == ProposalStatus.pending;
          return SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (stale && pending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: FAlert(
                      variant: FAlertVariant.destructive,
                      icon: const Icon(FLucideIcons.circleAlert),
                      title: const Text(
                        '正文已更新。这份正文依据旧版本，不能直接写入。请比较后重新生成，或复制所需片段手动编辑。',
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FButton(
                            variant: FButtonVariant.outline,
                            size: FButtonSizeVariant.sm,
                            mainAxisSize: MainAxisSize.min,
                            onPress: () => Clipboard.setData(
                              ClipboardData(text: proposal.content.text),
                            ),
                            prefix: const Icon(FLucideIcons.copy),
                            child: const Text('复制这份正文'),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!pending)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      proposal.status == ProposalStatus.accepted
                          ? '已写入正文'
                          : '已放弃，正文未改变',
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (comparison.before != comparison.base.content.text ||
                            comparison.after != proposal.content.text)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: FTile(
                              title: const Text('预览显示效果'),
                              subtitle: const Text(
                                '片段复制使用当前显示的文字；复制原文请关闭预览。写入与导出始终保留原正文。',
                              ),
                              suffix: FSwitch(
                                value: _displayRules,
                                onChange: (value) =>
                                    setState(() => _displayRules = value),
                              ),
                              onPress: () => setState(
                                () => _displayRules = !_displayRules,
                              ),
                            ),
                          ),
                        if (proposal.summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Text(proposal.summary),
                          ),
                        ParagraphComparison(
                          beforeTitle: '依据版本',
                          afterTitle: '新正文',
                          before: _displayRules
                              ? comparison.before
                              : comparison.base.content.text,
                          after: _displayRules
                              ? comparison.after
                              : proposal.content.text,
                        ),
                        if (stale && pending)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: FAccordion(
                              children: [
                                FAccordionItem(
                                  title: const Text('查看最新正文'),
                                  child: SelectableText(
                                    comparison.current.content.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (pending)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        FButton(
                          variant: FButtonVariant.outline,
                          mainAxisSize: MainAxisSize.min,
                          onPress: _busy ? null : () => _apply(false),
                          child: const Text('放弃'),
                        ),
                        const Spacer(),
                        FButton(
                          mainAxisSize: MainAxisSize.min,
                          onPress: _busy || stale ? null : () => _apply(true),
                          child: Text(_busy ? '保存中…' : '写入正文'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
