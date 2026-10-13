import 'package:sillydraft_core/sillydraft_core.dart';

Future<Novel> createSample(StoryRepository repo) async {
  final novel = await repo.createNovel(
    title: '雾港来信 · 示例',
    genre: '悬疑幻想',
    synopsis: '一封迟到十三年的信，把年轻信使引向一座地图上不存在的灯塔。此为内置示例，可离线阅读和编辑。',
    style: '克制、细腻，以环境和动作推进悬念。',
  );
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '渡口的信',
    content: ManuscriptContent.plainText(
      '雨停在凌晨三点。\n\n林舟站在渡口，掌心压着一封没有邮戳的信。信纸微微发烫，像刚从另一个人的手里接过来。可这条街已经空了很久，连守夜的灯也熄了。\n\n信封上写着他的名字。\n\n字迹是父亲的。\n\n十三年前，父亲带着最后一班渡船离开雾港。人们说那场大雾吞掉了整艘船，连一块船板都没留下。林舟记得的却是另一件事：父亲出门时，特意把门外那盏灯留着。\n\n信里只有一句话：\n\n“不要去找亮着的灯塔。”\n\n对岸的雾里，一束白光缓缓转过来。',
    ),
  );
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '旧地图',
    content: ManuscriptContent.plainText(
      '旧邮局的地板总在第三块木板处发出响声。林舟避开了它，借着窗外路灯的余光，把地图铺在柜台上。\n\n地图已经很旧。海岸线褪成浅灰色，标注的村庄有一半被水渍抹去了。但他记得这张图上从来没有灯塔。\n\n现在有了。\n\n墨迹还是湿的。\n\n“你也收到了？”\n\n阿雨站在门口。她没有打伞，肩上却一滴水也没有。',
    ),
  );
  return novel;
}
