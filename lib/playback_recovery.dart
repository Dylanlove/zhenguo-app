import 'models.dart';

enum PlaybackRecoveryAction { alternative, refresh, stop }

class PlaybackRecovery {
  bool _refreshed = false;
  int _lastRoute = -1;
  int? _routeCount;

  void reset() {
    _refreshed = false;
    _lastRoute = -1;
    _routeCount = null;
  }

  PlaybackRecoveryAction next(PlaybackPlan plan) {
    final count = _routeCount ??= plan.routeCount;
    if (plan.routeIndex > _lastRoute && plan.routeIndex < count) {
      // 这条线路尚未尝试过：先逐条切换到备用线路，最后一条仍失败时再刷新。
      _lastRoute = plan.routeIndex;
      if (plan.hasAlternative && plan.routeIndex + 1 < count) {
        return PlaybackRecoveryAction.alternative;
      }
      if (!_refreshed) {
        _refreshed = true;
        _lastRoute = -1;
        _routeCount = null;
        return PlaybackRecoveryAction.refresh;
      }
      return PlaybackRecoveryAction.stop;
    }
    // 当前线路已经尝试过或超出范围：尚未刷新过时重新解析地址。
    // 刷新会得到一份全新的线路列表，应当被完整遍历，而不是只试第一条就放弃。
    if (!_refreshed) {
      _refreshed = true;
      _lastRoute = -1;
      _routeCount = null;
      return PlaybackRecoveryAction.refresh;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  static const stallTimeout = Duration(seconds: 20);
  Duration? _position;
  DateTime? _lastProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
  }) {
    if (!playing || !foreground || position != _position) {
      _position = position;
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= stallTimeout;
  }
}
