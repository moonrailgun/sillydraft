import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/widgets.dart';

/// Finds a control by its tooltip label: the forui counterpart of
/// `find.byTooltip`, matching every [ActionLabel] (icon buttons, header
/// actions, the back button).
Finder findAction(Pattern label, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is ActionLabel &&
          (label is RegExp
              ? label.hasMatch((widget as ActionLabel).tooltip)
              : (widget as ActionLabel).tooltip == label),
      description: 'control labelled "$label"',
      skipOffstage: skipOffstage,
    );

/// Opens [chapter] from the workspace outline in the editor, by way of the
/// reader's 编辑本章.
Future<void> editChapter(WidgetTester tester, String chapter) async {
  await tester.tap(find.widgetWithText(FItem, chapter).first);
  await tester.pumpAndSettle();
  await tester.tap(findAction('编辑本章'));
  await tester.pumpAndSettle();
}
