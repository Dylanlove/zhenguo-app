import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/live_epg.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_playback.dart';
import 'package:duanju_app/live_programme_guide.dart';
import 'package:duanju_app/live_repository.dart';
import 'package:duanju_app/ysp_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = LiveChannel(
  key: 'ysp-cctv2',
  name: 'CCTV-2 财经',
  urls: ['ysp://cctv2'],
  source: 'ysp',
  token: 'cctv2',
  tvgId: 'CCTV2',
  catchup: true,
);

final _now = DateTime.utc(2026, 10, 19, 2, 59);
bool _qaFontsLoaded = false;

List<LiveProgramme> _items(DateTime date) {
  DateTime time(int hour, [int minute = 0]) => DateTime.utc(
    date.year,
    date.month,
    date.day,
    hour,
    minute,
  ).subtract(const Duration(hours: 8));
  return [
    LiveProgramme(
      channelId: 'CCTV2',
      title: '天下财经',
      start: time(8),
      end: time(9),
    ),
    LiveProgramme(
      channelId: 'CCTV2',
      title: '交易时间',
      start: time(9),
      end: time(10),
    ),
    LiveProgramme(
      channelId: 'CCTV2',
      title: '正点财经',
      start: time(10),
      end: time(10, 30),
    ),
    LiveProgramme(
      channelId: 'CCTV2',
      title: '经济半小时',
      start: time(10, 30),
      end: time(11),
    ),
    LiveProgramme(
      channelId: 'CCTV2',
      title: '后续节目',
      start: time(11),
      end: time(12),
    ),
  ];
}

class _FixtureEpg extends LiveEpgRepository {
  bool empty = false;
  final pending = <int, Completer<LiveEpgSchedule>>{};
  final requested = <DateTime>[];

  @override
  Future<LiveEpgSchedule> programmes(
    LiveChannel channel,
    DateTime date, {
    bool force = false,
  }) async {
    requested.add(date);
    if (pending[date.day] case final response?) return response.future;
    return LiveEpgSchedule(
      items: empty ? const [] : _items(date),
      source: '合成节目单',
      updated: _now,
    );
  }
}

class _FixturePlayback extends LivePlaybackController {
  _FixturePlayback(LiveRepository repository) : super(repository: repository);

  final requests =
      <({DateTime start, DateTime end, LiveProgramme? programme})>[];
  int liveCalls = 0;
  DateTime? _start;
  DateTime? _end;
  LiveProgramme? _programme;

  @override
  LiveChannel get channel => _channel;
  @override
  bool get ysp => true;
  @override
  bool get supportsCatchup => true;
  @override
  bool get catchup => _start != null;
  @override
  DateTime? get catchupStart => _start;
  @override
  DateTime? get catchupEnd => _end;
  @override
  LiveProgramme? get catchupProgramme => _programme;

  @override
  Future<void> playCatchup(
    DateTime start,
    DateTime end, {
    LiveProgramme? programme,
  }) async {
    requests.add((start: start, end: end, programme: programme));
    _start = start;
    _end = end;
    _programme = programme;
    notifyListeners();
  }

  @override
  Future<void> returnToLive() async {
    liveCalls++;
    _start = _end = null;
    _programme = null;
    notifyListeners();
  }
}

void main() {
  (_FixtureEpg, _FixturePlayback) fixture() {
    final epg = _FixtureEpg();
    final repository = LiveRepository(epg: epg);
    final playback = _FixturePlayback(repository);
    addTearDown(repository.dispose);
    addTearDown(playback.dispose);
    return (epg, playback);
  }

  Future<GlobalKey> pump(
    WidgetTester tester,
    _FixturePlayback playback, {
    Size size = const Size(393, 620),
    double textScale = 1,
    Future<void> Function()? manual,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final boundary = GlobalKey();
    final qaFont = const bool.fromEnvironment('SAVE_LIVE_GUIDE_PREVIEW')
        ? Platform.environment['LIVE_GUIDE_QA_FONT']
        : null;
    if (qaFont != null && !_qaFontsLoaded) {
      await tester.runAsync(() async {
        final bytes = await File(qaFont).readAsBytes();
        await (FontLoader(
          'LiveGuideQA',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      _qaFontsLoaded = true;
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: qaFont == null
            ? AppTheme.light
            : AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(
                  fontFamily: 'LiveGuideQA',
                ),
              ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: LiveProgrammeGuide(
              playback: playback,
              now: () => _now,
              onClose: () {},
              onManualTime: manual ?? () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return boundary;
  }

  testWidgets('点节目使用完整起止时间，显示当前回看并可返回直播', (tester) async {
    final (_, playback) = fixture();
    final boundary = await pump(tester, playback);
    await tester.ensureVisible(find.text('交易时间'));
    await tester.tap(find.text('交易时间'));
    await tester.pumpAndSettle();
    expect(playback.requests, hasLength(1));
    expect(playback.requests.single.start, DateTime.utc(2026, 10, 19, 1));
    expect(playback.requests.single.end, DateTime.utc(2026, 10, 19, 2));
    expect(playback.requests.single.programme?.title, '交易时间');
    expect(find.text('播放中'), findsOneWidget);
    expect(find.text('正在回看：交易时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('SAVE_LIVE_GUIDE_PREVIEW')) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ysp95-qa/live-programme-guide.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('回到直播'));
    await tester.pumpAndSettle();
    expect(playback.liveCalls, 1);
    expect(find.text('播放中'), findsNothing);
  });

  testWidgets('未播出不可回看，正在播出的节目进入直播', (tester) async {
    final (_, playback) = fixture();
    await pump(tester, playback);
    await tester.ensureVisible(find.text('后续节目'));
    await tester.tap(find.text('后续节目'));
    await tester.pump();
    expect(playback.requests, isEmpty);
    expect(find.text('未播出'), findsOneWidget);
    await tester.tap(find.text('看直播'));
    await tester.pumpAndSettle();
    expect(playback.liveCalls, 1);
  });

  testWidgets('缺少节目单时保留手动选时入口', (tester) async {
    final (epg, playback) = fixture();
    epg.empty = true;
    var manualCalls = 0;
    await pump(
      tester,
      playback,
      manual: () async {
        manualCalls++;
      },
    );
    expect(find.textContaining('当天暂无节目单'), findsOneWidget);
    await tester.tap(find.text('手动选时').first);
    expect(manualCalls, 1);
  });

  testWidgets('快速切换日期时丢弃旧日期的迟到结果', (tester) async {
    final (epg, playback) = fixture();
    epg.pending[18] = Completer<LiveEpgSchedule>();
    epg.pending[17] = Completer<LiveEpgSchedule>();
    await pump(tester, playback);
    final date18 = find.byKey(
      ValueKey('live-epg-date-${DateTime.utc(2026, 10, 18).toIso8601String()}'),
    );
    final date17 = find.byKey(
      ValueKey('live-epg-date-${DateTime.utc(2026, 10, 17).toIso8601String()}'),
    );
    await tester.ensureVisible(date18);
    await tester.tap(date18);
    await tester.pump();
    await tester.ensureVisible(date17);
    await tester.tap(date17);
    await tester.pump();
    LiveEpgSchedule response(int day) => LiveEpgSchedule(
      items: [
        LiveProgramme(
          channelId: 'CCTV2',
          title: '$day 日节目',
          start: DateTime.utc(2026, 10, day, 1),
          end: DateTime.utc(2026, 10, day, 2),
        ),
      ],
      source: '合成节目单',
      updated: _now,
    );
    epg.pending[17]!.complete(response(17));
    await tester.pumpAndSettle();
    epg.pending[18]!.complete(response(18));
    await tester.pumpAndSettle();
    expect(find.text('17 日节目'), findsOneWidget);
    expect(find.text('18 日节目'), findsNothing);
    expect(playback.requests, isEmpty);
  });

  for (final size in [const Size(320, 568), const Size(720, 300)]) {
    testWidgets('节目单在 $size 不溢出', (tester) async {
      final (_, playback) = fixture();
      await pump(tester, playback, size: size);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏节目单弹层在 $size 不溢出', (tester) async {
      final (_, playback) = fixture();
      await pump(tester, playback, size: size);
      final context = tester.element(find.byType(LiveProgrammeGuide));
      unawaited(showYspCatchupSheet(context, playback));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('节目单支持放大文字', (tester) async {
    final (_, playback) = fixture();
    await pump(tester, playback, size: const Size(393, 780), textScale: 1.5);
    expect(tester.takeException(), isNull);
  });
}
