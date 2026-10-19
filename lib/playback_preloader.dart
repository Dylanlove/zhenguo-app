import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';

class PreloadEvent {
  const PreloadEvent(
    this.stage,
    this.episode, {
    this.elapsedMs = 0,
    this.bytes = 0,
    this.error,
  });
  final String stage;
  final int episode, elapsedMs, bytes;
  final Object? error;
}

class PlaybackPreloadPolicy {
  static bool shouldPrepare({
    required Duration position,
    required Duration duration,
    required Duration buffer,
    required double rate,
    required Duration stableFor,
  }) {
    final length = duration.inMilliseconds;
    final at = position.inMilliseconds;
    if (length <= 0 ||
        at < 2000 ||
        at >= length ||
        stableFor < const Duration(seconds: 2))
      return false;
    final speed = rate.isFinite && rate > 0 ? rate.clamp(.25, 4.0) : 1.0;
    final remaining = (length - at) / speed;
    if (remaining > 45000) return false;
    final ahead = math.max(0, buffer.inMilliseconds - at) / speed;
    if (ahead >= math.min(5000.0, remaining)) return true;
    return buffer <= position &&
        stableFor >= const Duration(seconds: 10) &&
        remaining <= 30000;
  }
}

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(this.repository, {DateTime Function()? now, this.onEvent})
    : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final void Function(PreloadEvent event)? onEvent;
  PlaybackPlan? _ready;
  String? _identity;
  Episode? _episode;
  Timer? _delay;
  Completer<void>? _pending;
  DateTime _expires = DateTime(2000), _retryAt = DateTime(2000);
  int _generation = 0;
  bool _closed = false, loading = false;
  String error = '';

  bool get active =>
      _ready != null || loading || _delay != null || error.isNotEmpty;

  void _release(PlaybackPlan plan) =>
      unawaited(repository.release(plan.session).catchError((Object _) {}));
  void _event(
    String stage, {
    int elapsedMs = 0,
    int bytes = 0,
    Object? failure,
  }) {
    final episode = _episode;
    if (episode != null)
      onEvent?.call(
        PreloadEvent(
          stage,
          episode.number,
          elapsedMs: elapsedMs,
          bytes: bytes,
          error: failure,
        ),
      );
  }

  String get status {
    final label = _episode == null ? '下一集' : '下一集（第 ${_episode!.number} 集）';
    if (_ready != null && _now().isBefore(_expires)) {
      final bytes = _ready!.prefetchedBytes;
      return _ready!.local
          ? '$label已下载'
          : bytes > 0
          ? '$label已准备 · 预取 ${(bytes / 1024).ceil()} KB'
          : '$label播放地址已准备';
    }
    if (loading || _delay != null) return '正在准备$label';
    return error.isNotEmpty ? '下一集预加载暂不可用，切集时会重新获取' : '播放后段提前准备下一集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.id}\u0000${episode.number}\u0000$quality\u0000$online';

  void prepare(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    if (_closed) return;
    final identity = _key(drama, episode, quality, online);
    if (_identity != identity) {
      clear();
      _identity = identity;
      _episode = episode;
    }
    if (_ready != null && !_now().isBefore(_expires)) {
      final expired = _ready!;
      _ready = null;
      _release(expired);
      _event('预加载计划已过期');
    }
    if (_ready != null ||
        loading ||
        _delay != null ||
        _now().isBefore(_retryAt))
      return;
    final ticket = _generation;
    final pending = Completer<void>();
    _pending = pending;
    _delay = Timer(const Duration(milliseconds: 600), () async {
      _delay = null;
      loading = true;
      final clock = Stopwatch()..start();
      _event('下一集预加载开始');
      notifyListeners();
      try {
        final plan = await repository.preload(
          drama,
          episode,
          quality: quality,
          online: online,
        );
        if (_closed || ticket != _generation) {
          if (plan != null) _release(plan);
          return;
        }
        if (plan == null || plan.url.isEmpty) throw AppFailure('未取得预加载结果');
        var expires = _now().add(const Duration(minutes: 2));
        if (plan.expiresAt > 0) {
          final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
            plan.expiresAt,
          ).subtract(const Duration(seconds: 5));
          if (authorizationExpiry.isBefore(expires))
            expires = authorizationExpiry;
        }
        if (!expires.isAfter(_now())) {
          _release(plan);
          throw AppFailure('下一集播放凭证即将过期');
        }
        _ready = plan;
        _expires = expires;
        error = '';
        _event(
          '下一集预加载就绪',
          elapsedMs: clock.elapsedMilliseconds,
          bytes: plan.prefetchedBytes,
        );
      } catch (failure) {
        if (_closed || ticket != _generation) return;
        error = failure.toString();
        _retryAt = _now().add(const Duration(seconds: 30));
        _event(
          '下一集预加载失败',
          elapsedMs: clock.elapsedMilliseconds,
          failure: failure,
        );
      } finally {
        if (!pending.isCompleted) pending.complete();
        if (!_closed && ticket == _generation) {
          if (identical(_pending, pending)) _pending = null;
          loading = false;
          notifyListeners();
        }
      }
    });
    notifyListeners();
  }

  Future<PlaybackPlan?> takeWhenReady(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    required bool Function() stillCurrent,
  }) async {
    final identity = _key(drama, episode, quality, online);
    if (!_closed &&
        _identity == identity &&
        _ready == null &&
        _pending != null) {
      await _pending!.future.timeout(
        const Duration(milliseconds: 900),
        onTimeout: () {},
      );
    }
    if (_closed || !stillCurrent()) return null;
    return take(drama, episode, quality: quality, online: online);
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final result =
        _identity == _key(drama, episode, quality, online) &&
            _now().isBefore(_expires)
        ? _ready
        : null;
    if (result != null) {
      _ready = null;
      _event('下一集预加载复用', bytes: result.prefetchedBytes);
    } else if (active) {
      _event('下一集预加载未命中');
    }
    clear();
    return result;
  }

  void pause() {
    final changed = loading || _delay != null;
    _generation++;
    _delay?.cancel();
    _delay = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    if (loading)
      unawaited(repository.cancelPreload().catchError((Object _) {}));
    if (changed) _event('下一集预加载取消');
    loading = false;
    if (changed && !_closed) notifyListeners();
  }

  void clear() {
    pause();
    final old = _ready;
    _ready = null;
    _identity = null;
    _episode = null;
    _retryAt = DateTime(2000);
    error = '';
    if (old != null) _release(old);
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}
