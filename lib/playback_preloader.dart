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

class _PreloadRequest {
  const _PreloadRequest(this.drama, this.episode, this.quality, this.online);
  final Drama drama;
  final Episode episode;
  final int quality;
  final bool online;
}

class _PreloadSlot {
  _PreloadSlot(this.identity, this.request);
  final String identity;
  _PreloadRequest request;
  PlaybackPlan? ready;
  DateTime expires = DateTime(2000);
  Timer? delay;
  Completer<void>? pending;
  bool loading = false;
  DateTime retryAt = DateTime(2000);
  int generation = 0;
  String error = '';
}

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(this.repository, {DateTime Function()? now, this.onEvent})
    : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final void Function(PreloadEvent event)? onEvent;
  final Map<String, _PreloadSlot> _slots = {};
  bool _loadingNow = false;
  bool _closed = false;

  static const _maxSlots = 2;

  bool get active => _slots.isNotEmpty || _loadingNow;

  void _event(
    String stage, {
    Episode? episode,
    int elapsedMs = 0,
    int bytes = 0,
    Object? failure,
  }) {
    onEvent?.call(
      PreloadEvent(
        stage,
        episode?.number ?? 0,
        elapsedMs: elapsedMs,
        bytes: bytes,
        error: failure,
      ),
    );
  }

  String get status {
    final slots = _slots.values.toList();
    if (slots.isEmpty) {
      return '播放后段提前准备下一集';
    }
    final now = _now();
    final readySlots = slots
        .where((slot) => slot.ready != null && now.isBefore(slot.expires))
        .toList();
    if (readySlots.isNotEmpty) {
      final bytes = readySlots.fold<int>(
        0,
        (sum, slot) => sum + slot.ready!.prefetchedBytes,
      );
      if (readySlots.length >= 2) {
        return bytes > 0
            ? '下两集已准备 · 预取 ${(bytes / 1024).ceil()} KB'
            : '下两集播放地址已准备';
      }
      final first = readySlots.first.ready!;
      return first.local
          ? '下一集已下载'
          : bytes > 0
          ? '下一集已准备 · 预取 ${(bytes / 1024).ceil()} KB'
          : '下一集播放地址已准备';
    }
    final waiting = slots.where((slot) => slot.loading || slot.delay != null);
    if (waiting.isNotEmpty) {
      return slots.length > 1 ? '正在准备下两集' : '正在准备下一集';
    }
    return slots.first.error.isNotEmpty ? '下一集预加载暂不可用，切集时会重新获取' : '正在准备下一集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.id}\u0000${episode.number}\u0000$quality\u0000$online';

  void prepare(
    Drama drama,
    List<Episode> episodes, {
    int quality = 0,
    bool online = false,
    bool start = true,
  }) {
    if (_closed) return;
    final wanted = <_PreloadRequest>[];
    final identities = <String>{};
    for (final episode in episodes) {
      if (wanted.length >= _maxSlots) break;
      final identity = _key(drama, episode, quality, online);
      if (identities.contains(identity)) continue;
      identities.add(identity);
      wanted.add(_PreloadRequest(drama, episode, quality, online));
    }
    var changed = false;
    for (final identity in _slots.keys.toSet()) {
      if (identities.contains(identity)) continue;
      _removeSlot(_slots[identity]!, notify: false);
      changed = true;
    }
    for (final request in wanted) {
      final identity = _key(
        request.drama,
        request.episode,
        request.quality,
        request.online,
      );
      final slot = _slots[identity];
      if (slot != null) {
        slot.request = request;
        if (slot.ready != null && !_now().isBefore(slot.expires)) {
          _removeSlot(slot, notify: false);
          _event('预加载计划已过期', episode: request.episode);
          changed = true;
        }
        continue;
      }
      _slots[identity] = _PreloadSlot(identity, request)
        ..delay = start
            ? Timer(const Duration(milliseconds: 600), () {
                _pump();
              })
            : null;
      changed = true;
    }
    if (changed) notifyListeners();
    if (start) _pump();
  }

  void _pump() {
    if (_closed || _loadingNow) return;
    for (final slot in _slots.values) {
      if (slot.ready != null || slot.loading || slot.delay != null) continue;
      if (_now().isBefore(slot.retryAt)) continue;
      _startLoad(slot);
      return;
    }
  }

  Future<void> _startLoad(_PreloadSlot slot) async {
    _loadingNow = true;
    slot.loading = true;
    final pending = Completer<void>();
    slot.pending = pending;
    final ticket = ++slot.generation;
    final clock = Stopwatch()..start();
    _event('下一集预加载开始', episode: slot.request.episode);
    notifyListeners();
    try {
      final plan = await repository.preload(
        slot.request.drama,
        slot.request.episode,
        quality: slot.request.quality,
        online: slot.request.online,
      );
      if (_closed ||
          ticket != slot.generation ||
          _slots[slot.identity] != slot) {
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
      slot.ready = plan;
      slot.expires = expires;
      slot.error = '';
      _event(
        '下一集预加载就绪',
        episode: slot.request.episode,
        elapsedMs: clock.elapsedMilliseconds,
        bytes: plan.prefetchedBytes,
      );
      _pump();
    } catch (failure) {
      if (_closed ||
          ticket != slot.generation ||
          _slots[slot.identity] != slot) {
        return;
      }
      slot.error = failure.toString();
      slot.retryAt = _now().add(const Duration(seconds: 30));
      _event(
        '下一集预加载失败',
        episode: slot.request.episode,
        elapsedMs: clock.elapsedMilliseconds,
        failure: failure,
      );
      _pump();
    } finally {
      if (!pending.isCompleted) pending.complete();
      if (identical(slot.pending, pending)) slot.pending = null;
      slot.loading = false;
      _loadingNow = false;
      if (!_closed) notifyListeners();
    }
  }

  void _release(PlaybackPlan plan) =>
      unawaited(repository.release(plan.session).catchError((Object _) {}));

  void _removeSlot(_PreloadSlot slot, {bool notify = true}) {
    slot.generation++;
    slot.delay?.cancel();
    slot.delay = null;
    final pending = slot.pending;
    slot.pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    final ready = slot.ready;
    slot.ready = null;
    _slots.remove(slot.identity);
    if (ready != null) _release(ready);
    if (notify && !_closed) notifyListeners();
  }

  Future<PlaybackPlan?> takeWhenReady(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    required bool Function() stillCurrent,
  }) async {
    final identity = _key(drama, episode, quality, online);
    final slot = _slots[identity];
    if (!_closed &&
        slot != null &&
        slot.ready == null &&
        slot.pending != null) {
      await slot.pending!.future.timeout(
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
    final identity = _key(drama, episode, quality, online);
    final slot = _slots[identity];
    final now = _now();
    final result =
        slot != null && slot.ready != null && now.isBefore(slot.expires)
        ? slot.ready
        : null;
    if (result != null && slot != null) {
      _event('下一集预加载复用', episode: episode, bytes: result.prefetchedBytes);
      _removeSlot(slot, notify: false);
    } else {
      if (slot != null) _removeSlot(slot, notify: false);
      if (active) _event('下一集预加载未命中', episode: episode);
    }
    return result;
  }

  void pause() {
    var changed = false;
    var hadLoading = false;
    for (final slot in _slots.values) {
      slot.generation++;
      if (slot.delay != null) {
        slot.delay!.cancel();
        slot.delay = null;
        changed = true;
      }
      final pending = slot.pending;
      slot.pending = null;
      if (pending != null && !pending.isCompleted) pending.complete();
      if (slot.loading) {
        slot.loading = false;
        hadLoading = true;
        changed = true;
      }
      slot.error = '';
      _event('下一集预加载取消', episode: slot.request.episode);
    }
    _loadingNow = false;
    if (hadLoading) {
      unawaited(repository.cancelPreload().catchError((Object _) {}));
    }
    if (changed && !_closed) notifyListeners();
  }

  void clear() {
    pause();
    while (_slots.isNotEmpty) {
      _removeSlot(_slots.values.first, notify: false);
    }
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}
