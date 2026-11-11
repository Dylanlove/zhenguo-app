import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlaybackPlan route(int index, {int count = 3}) => PlaybackPlan(
    url: 'https://media.test/$index.mp4',
    session: 'session-$index',
    routeIndex: index,
    routeCount: count,
  );

  test(
    'refreshed resolution is retried across all its routes before stopping',
    () {
      final recovery = PlaybackRecovery();
      expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(1)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(2)), PlaybackRecoveryAction.refresh);
      // 重新解析后应从头完整遍历新线路，而不是只试第一条就放弃。
      expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(1)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(2)), PlaybackRecoveryAction.stop);
      recovery.reset();
      expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
    },
  );

  test('one-route sources refresh once without endless retrying', () {
    final recovery = PlaybackRecovery();
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.refresh);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.stop);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.stop);
  });

  test('exhausts every route then retries the re-resolved routes once', () {
    final recovery = PlaybackRecovery();
    for (var index = 0; index < 30; index++) {
      expect(
        recovery.next(route(index, count: 31)),
        PlaybackRecoveryAction.alternative,
      );
    }
    expect(recovery.next(route(30, count: 31)), PlaybackRecoveryAction.refresh);
    for (var index = 0; index < 30; index++) {
      expect(
        recovery.next(route(index, count: 31)),
        PlaybackRecoveryAction.alternative,
      );
    }
    expect(recovery.next(route(30, count: 31)), PlaybackRecoveryAction.stop);
    recovery.reset();
    expect(
      recovery.next(route(0, count: 31)),
      PlaybackRecoveryAction.alternative,
    );
  });

  test(
    'a repeated line triggers a fresh resolution instead of an immediate stop',
    () {
      final recovery = PlaybackRecovery();
      expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
      // 回退没有切到新线路（仍是同一条）时改为重新解析，而不是直接放弃。
      expect(recovery.next(route(0)), PlaybackRecoveryAction.refresh);
      expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(1)), PlaybackRecoveryAction.alternative);
      expect(recovery.next(route(2)), PlaybackRecoveryAction.stop);
    },
  );

  test(
    'recovery starting at a later route tries remaining then re-resolved',
    () {
      final recovery = PlaybackRecovery();
      expect(
        recovery.next(route(5, count: 7)),
        PlaybackRecoveryAction.alternative,
      );
      expect(recovery.next(route(6, count: 7)), PlaybackRecoveryAction.refresh);
      for (var index = 0; index < 6; index++) {
        expect(
          recovery.next(route(index, count: 7)),
          PlaybackRecoveryAction.alternative,
        );
      }
      expect(recovery.next(route(6, count: 7)), PlaybackRecoveryAction.stop);
    },
  );

  test('site route labels preserve gaps and old plans use their positions', () {
    final plan = PlaybackPlan.fromJson({
      'url': 'https://media.test/last.mp4',
      'routeIndex': 1,
      'routeCount': 2,
      'routeNames': ['线路 2', '线路 10'],
    });
    expect(plan.routeLabel(0), '线路 2');
    expect(plan.routeLabel(plan.routeIndex), '线路 10');
    expect(route(1).routeLabel(1), '线路 2');
  });

  test(
    'a stalled foreground stream times out but paused and background playback do not',
    () {
      final health = PlaybackHealth();
      final start = DateTime(2026, 9, 18);
      bool stalled(
        int seconds, {
        bool playing = true,
        bool foreground = true,
        int position = 5,
      }) => health.stalled(
        position: Duration(seconds: position),
        playing: playing,
        foreground: foreground,
        now: start.add(Duration(seconds: seconds)),
      );
      expect(stalled(0), isFalse);
      expect(stalled(19), isFalse);
      expect(stalled(20), isTrue);
      expect(stalled(21, position: 6), isFalse);
      expect(stalled(40, position: 6), isFalse);
      expect(stalled(60, playing: false, position: 6), isFalse);
      expect(stalled(80, playing: false, position: 6), isFalse);
      expect(stalled(100, foreground: false, position: 6), isFalse);
      expect(stalled(101, position: 6), isFalse);
      health.reset();
      expect(stalled(200, position: 6), isFalse);
    },
  );
}
