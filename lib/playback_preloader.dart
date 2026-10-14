import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'models.dart';

class _PreloadSlot {
  _PreloadSlot(this.identity);

  final String identity;
  Drama? drama;
  Episode? episode;
  int quality = 0;
  bool online = false;
  PlaybackPlan? ready;
  DateTime expires = DateTime(2000);
  DateTime retryAt = DateTime(2000);
  Timer? delay;
  bool loading = false;
  String error = '';

  bool get pending => loading || delay != null;

  bool get usable => ready != null && ready!.url.isNotEmpty;
}

class PlaybackPreloader extends ChangeNotifier {
  PlaybackPreloader(this.repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppRepository repository;
  final DateTime Function() _now;
  final Map<String, _PreloadSlot> _slots = {};
  int _generation = 0;
  bool _closed = false;

  void _release(PlaybackPlan? plan) {
    if (plan == null) return;
    unawaited(repository.release(plan.session).catchError((Object _) {}));
  }

  String get status {
    final slots = _slots.values.toList();
    bool usable(_PreloadSlot slot) =>
        slot.usable && _now().isBefore(slot.expires);
    if (slots.isEmpty) return '播放后段提前准备下两集';
    final next = slots.first;
    if (usable(next)) {
      final bytes = next.ready!.prefetchedBytes;
      final label = next.ready!.local
          ? '下一集已下载'
          : bytes > 0
          ? '下一集已准备 · 预取 ${(bytes / 1024).ceil()} KB'
          : '下一集播放地址已准备';
      if (slots.length > 1 && usable(slots[1])) {
        return '$label · 下两集已准备';
      }
      if (slots.length > 1 && slots[1].pending) {
        return '$label · 正在准备下两集';
      }
      return label;
    }
    if (slots.any((slot) => slot.pending)) return '正在准备下一集';
    return slots.any((slot) => slot.error.isNotEmpty)
        ? '下一集预加载暂不可用，切集时会重新获取'
        : '播放后段提前准备下两集';
  }

  String _key(Drama drama, Episode episode, int quality, bool online) =>
      '${drama.id}\u0000${episode.number}\u0000$quality\u0000$online';

  void prepare(
    Drama drama,
    List<Episode> episodes, {
    int quality = 0,
    bool online = false,
    bool start = true,
  }) {
    if (_closed) return;
    final ordered = <String, _PreloadSlot>{};
    for (final episode in episodes) {
      final identity = _key(drama, episode, quality, online);
      final existing = _slots.remove(identity);
      if (existing != null) {
        existing.drama = drama;
        existing.episode = episode;
        existing.quality = quality;
        existing.online = online;
        ordered[identity] = existing;
      } else {
        ordered[identity] = _PreloadSlot(identity)
          ..drama = drama
          ..episode = episode
          ..quality = quality
          ..online = online;
      }
    }
    for (final stale in _slots.values) {
      stale.delay?.cancel();
      stale.delay = null;
      stale.loading = false;
      _release(stale.ready);
    }
    _slots
      ..clear()
      ..addAll(ordered);
    notifyListeners();
    if (start) _pump();
  }

  PlaybackPlan? take(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final identity = _key(drama, episode, quality, online);
    final slot = _slots[identity];
    final result =
        slot != null && _now().isBefore(slot.expires) ? slot.ready : null;
    if (slot != null) {
      _slots.remove(identity);
      if (!identical(result, slot.ready)) _release(slot.ready);
      slot.ready = null;
    }
    if (!_closed) notifyListeners();
    return result;
  }

  void pause() {
    final changed = _slots.values.any((slot) => slot.pending);
    _generation++;
    for (final slot in _slots.values) {
      slot.delay?.cancel();
      slot.delay = null;
      slot.loading = false;
    }
    if (changed) {
      unawaited(repository.cancelPreload().catchError((Object _) {}));
      if (!_closed) notifyListeners();
    }
  }

  void clear() {
    pause();
    final stale = _slots.values.toList();
    _slots.clear();
    for (final slot in stale) {
      slot.error = '';
      slot.retryAt = DateTime(2000);
      _release(slot.ready);
    }
    if (stale.isNotEmpty && !_closed) notifyListeners();
  }

  void _pump() {
    if (_closed) return;
    if (_slots.values.any((slot) => slot.pending)) return;
    for (final slot in _slots.values) {
      if (slot.usable && _now().isBefore(slot.expires)) continue;
      if (_now().isBefore(slot.retryAt)) continue;
      _start(slot);
      return;
    }
  }

  void _start(_PreloadSlot slot) {
    final drama = slot.drama!;
    final episode = slot.episode!;
    final quality = slot.quality;
    final online = slot.online;
    final ticket = _generation;
    slot.delay = Timer(const Duration(milliseconds: 600), () async {
      slot.delay = null;
      slot.loading = true;
      if (!_closed) notifyListeners();
      try {
        final plan = await repository.preload(
          drama,
          episode,
          quality: quality,
          online: online,
        );
        if (_closed ||
            ticket != _generation ||
            !identical(_slots[slot.identity], slot)) {
          if (plan != null) await repository.release(plan.session);
          return;
        }
        if (plan == null || plan.url.isEmpty) throw AppFailure('未取得预加载结果');
        var expires = _now().add(const Duration(minutes: 2));
        if (plan.expiresAt > 0) {
          final authorizationExpiry = DateTime.fromMillisecondsSinceEpoch(
            plan.expiresAt,
          ).subtract(const Duration(seconds: 5));
          if (authorizationExpiry.isBefore(expires)) {
            expires = authorizationExpiry;
          }
        }
        if (!expires.isAfter(_now())) {
          _release(plan);
          throw AppFailure('下一集播放凭证即将过期');
        }
        slot.ready = plan;
        slot.expires = expires;
        slot.error = '';
      } catch (failure) {
        if (_closed || ticket != _generation) return;
        slot.error = failure.toString();
        slot.retryAt = _now().add(const Duration(seconds: 30));
      } finally {
        if (!_closed && ticket == _generation) {
          slot.loading = false;
          notifyListeners();
          _pump();
        }
      }
    });
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}
