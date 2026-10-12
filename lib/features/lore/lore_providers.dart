import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';

typedef LoreScope = ({String branchId, String? sceneId});
final loreProvider = FutureProvider.family<List<LoreEntry>, LoreScope>((
  ref,
  scope,
) {
  ref.watch(repositoryChangesProvider);
  return ref
      .watch(repositoryProvider)
      .listLore(
        scope.branchId,
        throughSceneId: scope.sceneId,
        includeDeleted: true,
      );
});
const loreLabels = {
  LoreKind.character: '人物',
  LoreKind.world: '世界设定',
  LoreKind.organization: '组织',
  LoreKind.item: '物品',
  LoreKind.location: '地点',
  LoreKind.event: '事件',
  LoreKind.foreshadow: '暗线与伏笔',
  LoreKind.relationship: '人物关系',
  LoreKind.map: '地图',
};
const certaintyLabels = {
  LoreCertainty.fact: '已确认',
  LoreCertainty.plan: '创作计划',
  LoreCertainty.inference: '尚待证实',
};
const loreStatusLabels = {
  'active': '进行中',
  'planted': '已埋下',
  'developing': '铺垫中',
  'resolved': '已回收',
  'abandoned': '已放弃',
};
