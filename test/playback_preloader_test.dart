import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class _PreloadRepository extends FixtureRepository {
  final pending = <Completer<PlaybackPlan>>[];
  final released = <String>[];
  int cancellations = 0;

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final request = Completer<PlaybackPlan>();
    pending.add(request);
    return request.future;
  }

  @override
  Future<void> release(String session) async => released.add(session);

  @override
  Future<void> cancelPreload() async {
    cancellations++;
  }
}

void main() {
  Episode episode(String id) => Episode({'id': id, 'currentEpisode': 2}, 2);
  const plan = PlaybackPlan(
    url: 'https://example.test/video',
    session: 'prepared',
    prefetchedBytes: 1024,
  );

  test('切集可接用即将完成的预加载，且只解析一次', () {
    fakeAsync((async) {
      final repository = _PreloadRepository();
      final preloader = PlaybackPreloader(repository);
      preloader.prepare(FixtureRepository.free, episode('target'));
      async.elapse(const Duration(milliseconds: 600));
      PlaybackPlan? claimed;
      preloader
          .takeWhenReady(
            FixtureRepository.free,
            episode('target'),
            stillCurrent: () => true,
          )
          .then((value) => claimed = value);
      async.elapse(const Duration(milliseconds: 300));
      repository.pending.single.complete(plan);
      async.flushMicrotasks();
      expect(claimed?.session, 'prepared');
      expect(repository.pending, hasLength(1));
      expect(repository.cancellations, 0);
      preloader.dispose();
    });
  });

  test('集数相同但分集 ID 不同不会复用', () {
    fakeAsync((async) {
      final repository = _PreloadRepository();
      final preloader = PlaybackPreloader(repository);
      preloader.prepare(FixtureRepository.free, episode('first-id'));
      async.elapse(const Duration(milliseconds: 600));
      repository.pending.single.complete(plan);
      async.flushMicrotasks();
      expect(
        preloader.take(FixtureRepository.free, episode('second-id')),
        isNull,
      );
      async.flushMicrotasks();
      expect(repository.released, ['prepared']);
      preloader.dispose();
    });
  });

  test('迟到的切集请求不能拿走当前预加载计划', () {
    fakeAsync((async) {
      final repository = _PreloadRepository();
      final preloader = PlaybackPreloader(repository);
      preloader.prepare(FixtureRepository.free, episode('target'));
      async.elapse(const Duration(milliseconds: 600));
      var current = true;
      PlaybackPlan? stale;
      preloader
          .takeWhenReady(
            FixtureRepository.free,
            episode('target'),
            stillCurrent: () => current,
          )
          .then((value) => stale = value);
      current = false;
      repository.pending.single.complete(plan);
      async.flushMicrotasks();
      expect(stale, isNull);
      expect(
        preloader.take(FixtureRepository.free, episode('target'))?.session,
        'prepared',
      );
      preloader.dispose();
    });
  });

  test('等待到期后正常解析可继续，迟到计划会释放', () {
    fakeAsync((async) {
      final repository = _PreloadRepository();
      final preloader = PlaybackPreloader(repository);
      preloader.prepare(FixtureRepository.free, episode('target'));
      async.elapse(const Duration(milliseconds: 600));
      var completed = false;
      preloader
          .takeWhenReady(
            FixtureRepository.free,
            episode('target'),
            stillCurrent: () => true,
          )
          .then((value) {
            expect(value, isNull);
            completed = true;
          });
      async.elapse(const Duration(milliseconds: 901));
      async.flushMicrotasks();
      expect(completed, isTrue);
      repository.pending.single.complete(plan);
      async.flushMicrotasks();
      expect(repository.released, ['prepared']);
      expect(preloader.active, isFalse);
      preloader.dispose();
    });
  });

  test('预加载触发考虑倍速和缓冲未知时的稳定播放时间', () {
    bool ready({
      double rate = 1,
      int at = 40,
      int buffer = 50,
      int stable = 10,
    }) => PlaybackPreloadPolicy.shouldPrepare(
      position: Duration(seconds: at),
      duration: const Duration(seconds: 120),
      buffer: Duration(seconds: buffer),
      rate: rate,
      stableFor: Duration(seconds: stable),
    );
    expect(ready(), isFalse);
    expect(ready(rate: 2), isTrue);
    expect(ready(at: 100, buffer: 0, stable: 2), isFalse);
    expect(ready(at: 100, buffer: 0, stable: 10), isTrue);
    expect(ready(at: 10, buffer: 0, stable: 30), isFalse);
    expect(
      PlaybackPreloadPolicy.shouldPrepare(
        position: const Duration(minutes: 30),
        duration: const Duration(hours: 1),
        buffer: const Duration(minutes: 31),
        rate: 1,
        stableFor: const Duration(seconds: 20),
      ),
      isFalse,
    );
  });
}
