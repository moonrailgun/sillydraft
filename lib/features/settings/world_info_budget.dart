import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

const worldInfoBudgetHelp =
    '同 SillyTavern 世界信息设置里的 Context % 与 Budget Cap：所有世界书触发的条目共用这一份预算，'
    '提示词上限 = 上下文长度 − 回复长度。';

/// ST 1.19.0 index.html L4730-4745, the World Info budget controls:
/// `world_info_budget` 1-100 and `world_info_budget_cap` 0-65536. A number in
/// range is saved as it is typed.
class WorldInfoBudgetFields extends ConsumerWidget {
  const WorldInfoBudgetFields({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(settingProvider(WorldInfoBudget.settingKey)),
    builder: (json) {
      final budget = WorldInfoBudget.fromJson(json);
      Widget field(
        String key,
        String label,
        int value,
        (int, int) range,
        WorldInfoBudget Function(WorldInfoBudget current, int value) next,
      ) {
        final (min, max) = range;
        int? valid(String? text) => switch (int.tryParse(text?.trim() ?? '')) {
          final int n when n >= min && n <= max => n,
          _ => null,
        };
        return FTextFormField(
          key: Key(key),
          control: FTextFieldControl.managed(
            initial: TextEditingValue(text: '$value'),
            // Also called for cursor moves; the other field's value is read
            // back so a save never undoes it.
            onChange: (text) async {
              final typed = valid(text.text);
              if (typed == null) return;
              final repository = ref.read(repositoryProvider);
              try {
                final current = WorldInfoBudget.fromJson(
                  await repository.getSetting(WorldInfoBudget.settingKey),
                );
                final updated = next(current, typed);
                if (updated.percent == current.percent &&
                    updated.cap == current.cap) {
                  return;
                }
                await repository.setSetting(
                  WorldInfoBudget.settingKey,
                  updated.toJson(),
                );
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          keyboardType: TextInputType.number,
          label: Text(label),
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (text) =>
              valid(text) == null ? '请输入 $min 到 $max 的整数' : null,
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field('world-info-budget', '占提示词上限的比例（%）', budget.percent, (
            1,
            100,
          ), (current, v) => WorldInfoBudget(percent: v, cap: current.cap)),
          const SizedBox(height: 12),
          field('world-info-budget-cap', '预算上限（token，0 为不限）', budget.cap, (
            0,
            65536,
          ), (current, v) => WorldInfoBudget(percent: current.percent, cap: v)),
        ],
      );
    },
  );
}

/// A one-tap write's notice that the budget left entries out: [summary] and
/// a way to raise the budget for the next write. The write goes on.
void showWorldInfoBudgetNotice(BuildContext context, String summary) {
  if (!context.mounted) return;
  // The toaster sits above the navigator: the dialog opens on the page's,
  // which outlives a page part such as the directions card.
  final navigator = Navigator.of(context);
  late final FToasterEntry entry;
  entry = showFToast(
    context: context,
    icon: const Icon(FLucideIcons.bookOpen),
    title: Text(summary),
    description: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FButton(
        key: const Key('world-book-budget-notice'),
        variant: FButtonVariant.outline,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        onPress: () {
          entry.dismiss();
          if (navigator.mounted) showWorldInfoBudgetDialog(navigator.context);
        },
        child: const Text('调整世界书预算'),
      ),
    ),
    duration: const Duration(seconds: 15),
  );
}

/// The budget controls in a dialog, opened from a request's budget warning.
Future<void> showWorldInfoBudgetDialog(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('世界书预算'),
        body: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(worldInfoBudgetHelp),
            SizedBox(height: 16),
            WorldInfoBudgetFields(),
          ],
        ),
        actions: [
          FButton(
            onPress: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
