import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:duanju_app/danmaku_api.dart';
import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_overlay.dart';
import 'package:duanju_app/danmaku_preferences.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'danmaku_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Dandan JSON preserves time, mode, color, literal text and grapheme clusters',
    () {
      final items = parseDanmakuDocument(
        jsonEncode({
          'comments': [
            {'p': '2.125,5,16711680,user', 'm': '顶部 👨‍👩‍👧‍👦'},
            {'p': '0,1,16777215,user', 'm': '<b>文字</b>\n下一行'},
            {'p': '0,1,16777215,user', 'm': '<b>文字</b>\n下一行'},
            {'p': '3,4,255,user', 'm': '底部'},
            {'time': 1, 'text': '默认滚动'},
            {'p': '-1,1,1,user', 'm': '负数'},
            {'p': 'NaN,1,1,user', 'm': '坏时间'},
            {'p': '4,7,1,user', 'm': '不执行高级内容'},
          ],
        }),
      );
      expect(items.map((value) => value.timeMs), [0, 1000, 2125, 3000]);
      expect(items.first.text, '<b>文字</b> 下一行');
      expect(items[1].mode, DanmakuMode.scroll);
      expect(items[2].mode, DanmakuMode.top);
      expect(items[2].color, 0xff0000);
      expect(items.last.mode, DanmakuMode.bottom);
      expect(
        trimDanmakuText('字👨‍👩‍👧‍👦🇨🇳👍🏽e\u0301尾', 5),
        '字👨‍👩‍👧‍👦🇨🇳👍🏽e\u0301',
      );
    },
  );

  test(
    'Bilibili XML reads escaped text, decimal timestamps, types and colors',
    () {
      final items = parseDanmakuDocument(
        '<?xml version="1.0"?><i><d p="0,1,25,16777215,0,0,u,1">A &amp; B</d>'
        '<d p="1.5,4,25,255,0,0,u,2"><![CDATA[<文字>]]></d><d p="2,5,25,0,0,0,u,3">顶部</d></i>',
      );
      expect(items.map((value) => value.text), ['A & B', '<文字>', '顶部']);
      expect(items[1].timeMs, 1500);
      expect(items[1].color, 255);
      expect(items.last.mode, DanmakuMode.top);
      expect(parseDanmakuDocument('<i/>'), isEmpty);
      for (final raw in [
        '{}',
        '{"comments":null}',
        '<html/>',
        '<!DOCTYPE i><i/>',
      ]) {
        expect(() => parseDanmakuDocument(raw), throwsFormatException);
      }
    },
  );

  test(
    'large responses are sampled across the full timeline and remain bounded',
    () {
      final items = parseDanmakuDocument(
        jsonEncode({
          'comments': List.generate(
            60000,
            (i) => {'p': '${i / 100},1,16777215,u', 'm': '合成 $i'},
          ),
        }),
      );
      expect(items.length, lessThanOrEqualTo(danmakuMaxItems));
      expect(items.last.timeMs, greaterThan(590000));
    },
  );

  test(
    'subject extracts seasons and retains provider-independent episode identity',
    () {
      final subject = DanmakuSubject.fromEpisode(
        const Drama(id: 'site:42', source: 'other', title: '示例 第二季'),
        Episode({'id': 'ep', 'currentEpisode': 12}, 1),
      )!;
      expect(subject.title, '示例');
      expect(subject.season, 2);
      expect(subject.episode, 12);
      expect(subject.fileName, '示例 S02E12.mp4');
      expect(subject.key, 'site:42|2|12');
    },
  );

  test(
    'source paths preserve tokens and API roots without splitting episode IDs',
    () {
      for (final base in [
        'https://example.test/token',
        'https://example.test/token/api/v2/',
      ]) {
        final source = DanmakuSource(id: 'a', name: 'a', baseUrl: base);
        expect(
          source.endpoint('search/anime').path,
          '/token/api/v2/search/anime',
        );
        expect(source.commentEndpoint('a/b?c').pathSegments.last, 'a/b?c');
      }
      expect(
        () => DanmakuSource.validateUrl('file:///local'),
        throwsFormatException,
      );
      expect(
        () => DanmakuSource.validateUrl('https://user:pass@example.test'),
        throwsFormatException,
      );
    },
  );

  DanmakuController create(
    FixtureDanmakuService service, {
    DanmakuPreferences preferences = fixtureDanmakuPreferences,
    DateTime Function()? now,
  }) {
    final controller = DanmakuController(
      service: service,
      preferences: preferences,
      now: now,
    )..setPlan(danmakuPlan, subject: danmakuSubject);
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'unconfigured APIs never request a source and provide a clear hint',
    () async {
      final service = FixtureDanmakuService();
      final controller = create(
        service,
        preferences: const DanmakuPreferences(),
      );
      updateDanmaku(controller);
      await flushDanmaku();
      expect(service.matchCalls, 0);
      expect(service.loads, isEmpty);
      expect(controller.status, contains('尚未配置'));
    },
  );

  test(
    'online playback needs valid metadata rather than a native provider session',
    () async {
      final service = FixtureDanmakuService();
      final controller = create(service);
      updateDanmaku(controller);
      await flushDanmaku();
      expect(controller.supported, isTrue);
      expect(controller.visible, isTrue);
      expect(service.loads.single.match.episodeId, 'api-1');
      controller.setPlan(
        const PlaybackPlan(url: 'file:///local', local: true),
        subject: danmakuSubject,
      );
      updateDanmaku(controller);
      expect(controller.visible, isFalse);
      expect(service.loads.length, 1);
    },
  );

  test(
    'late responses cannot cross episodes, disabled state, background or disposal',
    () async {
      final service = FixtureDanmakuService()..hold = true;
      final controller = DanmakuController(
        service: service,
        preferences: fixtureDanmakuPreferences,
      )..setPlan(danmakuPlan, subject: danmakuSubject);
      updateDanmaku(controller);
      await flushDanmaku();
      final first = service.loads.single;
      controller.setPlan(
        danmakuPlan,
        subject: const DanmakuSubject(key: 'other|2', title: '合成', episode: 2),
      );
      updateDanmaku(controller);
      await flushDanmaku();
      expect(first.cancel.cancelled, isTrue);
      first.result.complete(const [
        DanmakuItem(id: 'old', text: '旧集', timeMs: 0),
      ]);
      await flushDanmaku();
      expect(controller.items, isEmpty);
      final second = service.loads.last;
      controller.setEnabled(false);
      expect(second.cancel.cancelled, isTrue);
      second.result.complete(const []);
      for (var i = 0; i < 10; i++) {
        updateDanmaku(controller, position: i * 100);
      }
      expect(service.loads.length, 2);
      controller.setEnabled(true);
      await flushDanmaku();
      final third = service.loads.last;
      updateDanmaku(controller, foreground: false);
      expect(third.cancel.cancelled, isTrue);
      third.result.complete(const []);
      controller.dispose();
      expect(service.disposed, isTrue);
      await flushDanmaku();
    },
  );

  test(
    'failure is isolated and needs an explicit retry without request loops',
    () async {
      final service = FixtureDanmakuService()..fail = true;
      final controller = create(service);
      updateDanmaku(controller);
      await flushDanmaku();
      expect(controller.canRetry, isTrue);
      for (var i = 0; i < 100; i++) {
        updateDanmaku(controller, position: i * 100);
      }
      expect(service.loads.length, 1);
      service.fail = false;
      controller.retry();
      await flushDanmaku();
      expect(controller.visible, isTrue);
      expect(service.loads.length, 2);
    },
  );

  test(
    'manual mappings work with automatic matching disabled and display changes never reload',
    () async {
      final service = FixtureDanmakuService();
      const match = DanmakuMatch(
        sourceId: 'custom',
        episodeId: 'saved',
        animeTitle: '选择作品',
        episodeTitle: '第2集',
      );
      final settings = fixtureDanmakuPreferences
          .copyWith(autoMatch: false)
          .remember(danmakuSubject.key, match);
      final controller = create(service, preferences: settings);
      updateDanmaku(controller);
      await flushDanmaku();
      expect(service.matchCalls, 0);
      expect(service.loads.single.match.episodeId, 'saved');
      controller.configure(
        settings.copyWith(fontSize: 28, offsetSeconds: -5, speed: 1.5),
      );
      expect(service.loads.length, 1);
      controller.setEnabled(false);
      await controller.selectMatch(
        const DanmakuMatch(
          sourceId: 'custom',
          episodeId: 'new',
          animeTitle: '新匹配',
          episodeTitle: '第1集',
        ),
      );
      expect(service.loads.length, 1);
      expect(
        controller.preferences
            .savedMatch(danmakuSubject.key, 'custom')
            ?.episodeId,
        'new',
      );
    },
  );

  test(
    'pause, resume, buffering, playback rate and seek use the video timeline',
    () async {
      var now = DateTime(2026);
      final controller = create(FixtureDanmakuService(), now: () => now);
      updateDanmaku(controller);
      await flushDanmaku();
      now = now.add(const Duration(seconds: 1));
      expect(controller.timelinePositionMs, 1000);
      updateDanmaku(controller, position: 1000, speed: 2);
      now = now.add(const Duration(milliseconds: 500));
      expect(controller.timelinePositionMs, 2000);
      updateDanmaku(controller, position: 2000, playing: false);
      now = now.add(const Duration(seconds: 1));
      expect(controller.timelinePositionMs, 2000);
      updateDanmaku(controller, position: 2000, buffering: true);
      now = now.add(const Duration(seconds: 1));
      expect(controller.timelinePositionMs, 2000);
      updateDanmaku(controller, position: 2000);
      now = now.add(const Duration(milliseconds: 300));
      expect(controller.timelinePositionMs, 2300);
      controller.beginSeek();
      expect(controller.visible, isFalse);
      controller.endSeek(const Duration(seconds: 65));
      expect(controller.timelinePositionMs, 65000);
    },
  );

  test(
    'settings, sources and manual mappings survive persistence and old preferences migrate',
    () async {
      expect(
        PlaybackPreferences.fromJson({
          'danmaku': false,
        }).danmakuSettings.opacity,
        .85,
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = LocalStore(preferences);
      final settings = fixtureDanmakuPreferences
          .copyWith(
            fontSize: 26,
            area: .75,
            blockColored: true,
            keywords: ['剧透'],
            offsetSeconds: -3.5,
          )
          .remember(
            danmakuSubject.key,
            const DanmakuMatch(
              sourceId: 'custom',
              episodeId: 'manual',
              animeTitle: '作品',
              episodeTitle: '集',
            ),
          );
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(danmakuSettings: settings),
      );
      store.dispose();
      final restored = LocalStore(preferences);
      addTearDown(restored.dispose);
      expect(
        restored.playbackPreferences.danmakuSettings.toJson(),
        settings.toJson(),
      );
      expect(settings.resetDisplay().sources.single.id, 'custom');
      expect(settings.resetDisplay().matches.length, 1);
      expect(settings.resetDisplay().offsetSeconds, 0);
    },
  );

  test('manual mappings remain independent for multiple APIs', () {
    const first = DanmakuMatch(
      sourceId: 'custom',
      episodeId: 'a',
      animeTitle: '作品',
      episodeTitle: '第1集',
    );
    const second = DanmakuMatch(
      sourceId: 'second',
      episodeId: 'b',
      animeTitle: '作品',
      episodeTitle: '第1集',
    );
    final settings = fixtureDanmakuPreferences
        .remember(danmakuSubject.key, first)
        .remember(danmakuSubject.key, second);
    expect(settings.savedMatch(danmakuSubject.key, 'custom')?.episodeId, 'a');
    expect(settings.savedMatch(danmakuSubject.key, 'second')?.episodeId, 'b');
  });

  void verifyNoOverlap(List<DanmakuFlight> flights, double width) {
    for (var i = 0; i < flights.length; i++) {
      for (final next in flights.skip(i + 1)) {
        final previous = flights[i];
        if (previous.lane != next.lane) continue;
        final start = math.max(previous.startMs, next.startMs),
            end = math.min(previous.endMs, next.endMs);
        if (start >= end) continue;
        for (var sample = 0; sample <= 8; sample++) {
          final time = start + (end - start) * sample / 8;
          final a = previous.x(width, time), b = next.x(width, time);
          final overlap =
              math.min(math.min(a + previous.width, b + next.width), width) -
              math.max(math.max(a, b), 0);
          expect(
            overlap,
            lessThanOrEqualTo(.001),
            reason:
                'lane=${previous.lane}, time=$time, ${previous.text} / ${next.text}',
          );
        }
      }
    }
  }

  test(
    'dynamic tracks exceed four rows and mixed modes never overlap or catch up',
    () {
      final random = math.Random(42);
      final items = List.generate(
        3000,
        (i) => DanmakuItem(
          id: '$i',
          text: '弹幕${'字' * (1 + random.nextInt(40))}',
          timeMs: i * 14,
          mode:
              DanmakuMode.values[i % 7 == 0
                  ? 1
                  : i % 11 == 0
                  ? 2
                  : 0],
        ),
      );
      final flights = planDanmaku(
        items,
        width: 960,
        rows: 18,
        scrollingRows: 14,
        preferences: const DanmakuPreferences(density: DanmakuDensity.high),
        measure: (text) => text.characters.length * 17.0,
      );
      expect(
        flights.map((flight) => flight.lane).toSet().length,
        greaterThan(4),
      );
      verifyNoOverlap(flights, 960);
      expect(flights.every((flight) => flight.width <= 944), isTrue);
    },
  );

  test(
    'incremental planning preserves active tracks and enforces collisions across batches',
    () {
      final initial = planDanmaku(
        List.generate(
          30,
          (i) => DanmakuItem(id: '$i', text: '弹幕 $i', timeMs: i * 100),
        ),
        width: 600,
        rows: 7,
        measure: (_) => 120,
      );
      final appended = planDanmaku(
        List.generate(
          30,
          (i) =>
              DanmakuItem(id: 'new$i', text: '长弹幕 $i', timeMs: 3000 + i * 100),
        ),
        width: 600,
        rows: 7,
        measure: (_) => 300,
        previous: initial,
      );
      expect(appended.take(initial.length), initial);
      verifyNoOverlap(appended, 600);
    },
  );

  test(
    'density, types, keywords and signed time offsets filter without unnecessary measurements',
    () {
      final items = List.generate(
        20000,
        (i) => DanmakuItem(id: '$i', text: '密集 $i', timeMs: 2000),
      );
      var measures = 0;
      final flights = planDanmaku(
        items,
        width: 640,
        rows: 12,
        preferences: const DanmakuPreferences(offsetSeconds: -1),
        measure: (_) {
          measures++;
          return 100;
        },
      );
      expect(flights.first.startMs, 1000);
      expect(measures, lessThan(30));
      final blocked = planDanmaku(
        items,
        width: 640,
        rows: 12,
        preferences: const DanmakuPreferences(keywords: ['密集']),
        measure: (_) => throw StateError('should not measure blocked content'),
      );
      expect(blocked, isEmpty);
      expect(
        planDanmaku(
          items,
          width: 640,
          rows: 12,
          preferences: const DanmakuPreferences(scroll: false),
          measure: (_) => 100,
        ),
        isEmpty,
      );
    },
  );
}
