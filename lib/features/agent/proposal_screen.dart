import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'agent_providers.dart';

final _comparisonProvider =
    FutureProvider.family<({DocumentRevision base, Scene current}), String>((
      ref,
      id,
    ) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider),
          proposal = await ref.watch(proposalProvider(id).future);
      return (
        base: await repo.getRevision(proposal.baseRevisionId),
        current: await repo.getScene(
          branchId: proposal.branchId,
          sceneId: proposal.sceneId,
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
  Future<void> _apply(bool accept) async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      if (accept) {
        await repo.acceptProposal(widget.proposalId);
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('审阅正文候选')),
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
              children: [
                if (stale && pending)
                  MaterialBanner(
                    content: const Text(
                      '正文已更新。这份候选依据旧版本，不能直接采纳。请比较后重新生成，或复制所需片段手动编辑。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: proposal.content.text),
                        ),
                        child: const Text('复制候选'),
                      ),
                    ],
                  ),
                if (!pending)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      proposal.status == ProposalStatus.accepted
                          ? '已采纳到正文'
                          : '已拒绝，正文未改变',
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (proposal.summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Text(proposal.summary),
                          ),
                        LayoutBuilder(
                          builder: (context, size) {
                            final before = _panel(
                              '依据版本',
                              comparison.base.content.text,
                              proposal.content.text,
                              false,
                            );
                            final after = _panel(
                              '候选正文',
                              comparison.base.content.text,
                              proposal.content.text,
                              true,
                            );
                            return size.maxWidth >= 800
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: before),
                                      const SizedBox(width: 20),
                                      Expanded(child: after),
                                    ],
                                  )
                                : Column(
                                    children: [
                                      before,
                                      const SizedBox(height: 20),
                                      after,
                                    ],
                                  );
                          },
                        ),
                        if (stale && pending)
                          ExpansionTile(
                            title: const Text('查看最新正文'),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: SelectableText(
                                  comparison.current.content.text,
                                ),
                              ),
                            ],
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
                        OutlinedButton(
                          onPressed: _busy ? null : () => _apply(false),
                          child: const Text('拒绝候选'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: _busy || stale ? null : () => _apply(true),
                          child: Text(_busy ? '保存中…' : '采纳到正文'),
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
  Widget _panel(String title, String old, String next, bool after) {
    var prefix = 0, suffix = 0;
    while (prefix < old.length &&
        prefix < next.length &&
        old.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }
    while (suffix < old.length - prefix &&
        suffix < next.length - prefix &&
        old.codeUnitAt(old.length - suffix - 1) ==
            next.codeUnitAt(next.length - suffix - 1)) {
      suffix++;
    }
    if (prefix > 0 &&
        prefix < old.length &&
        old.codeUnitAt(prefix) >= 0xdc00 &&
        old.codeUnitAt(prefix) <= 0xdfff) {
      prefix--;
    }
    if (suffix > 0 &&
        suffix < old.length &&
        old.codeUnitAt(old.length - suffix) >= 0xdc00 &&
        old.codeUnitAt(old.length - suffix) <= 0xdfff) {
      suffix--;
    }
    final text = after ? next : old;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(text: text.substring(0, prefix)),
                  TextSpan(
                    text: text.substring(prefix, text.length - suffix),
                    style: TextStyle(
                      backgroundColor: after
                          ? const Color(0x334a996d)
                          : const Color(0x33cb655f),
                    ),
                  ),
                  TextSpan(text: text.substring(text.length - suffix)),
                ],
              ),
              style: const TextStyle(height: 1.7),
            ),
          ],
        ),
      ),
    );
  }
}
