import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/live_playback.dart';
import 'package:duanju_app/live_repository.dart';
import 'package:duanju_app/ysp_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MenuPlayback extends LivePlaybackController {
  _MenuPlayback(LiveRepository repository) : super(repository: repository);

  @override
  bool get supportsCatchup => true;

  @override
  bool get catchup => true;
}

void main() {
  Future<List<String?>> openMenu(
    WidgetTester tester, {
    required Size size,
    String? catchupLabel,
  }) async {
    final repository = LiveRepository();
    final playback = _MenuPlayback(repository);
    addTearDown(repository.dispose);
    addTearDown(playback.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    final insets = FakeViewPadding(bottom: size.width > size.height ? 21 : 34);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
    final selections = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  selections.add(
                    await (catchupLabel == null
                        ? showYspPlaybackMenu(context, playback)
                        : showYspPlaybackMenu(
                            context,
                            playback,
                            catchupLabel: catchupLabel,
                          )),
                  );
                },
                child: const Text('打开播放菜单'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开播放菜单'));
    await tester.pumpAndSettle();
    return selections;
  }

  testWidgets('竖屏回看菜单四项全部可见，最后一项可以直接点击', (tester) async {
    final selections = await openMenu(tester, size: const Size(393, 852));
    for (final title in ['画质选择', '7 天回看', '回到直播', '订阅分享与诊断']) {
      expect(find.text(title).hitTestable(), findsOneWidget);
    }
    await tester.tap(find.text('订阅分享与诊断'));
    await tester.pumpAndSettle();
    expect(selections, ['settings']);
    expect(tester.takeException(), isNull);
  });

  for (final catchupLabel in [null, '节目单与 7 天回看']) {
    testWidgets('横屏${catchupLabel == null ? '三点' : '全屏'}菜单可以上滑并点击底部选项', (
      tester,
    ) async {
      final selections = await openMenu(
        tester,
        size: const Size(844, 390),
        catchupLabel: catchupLabel,
      );
      final last = find.text('订阅分享与诊断');
      expect(find.text(catchupLabel ?? '7 天回看'), findsOneWidget);
      expect(last.hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();

      expect(last.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(390 - 21),
        reason: '最后一项滚动后应完整位于 Home 指示条安全区域上方',
      );
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selections, ['settings']);
      expect(tester.takeException(), isNull);
    });
  }
}
