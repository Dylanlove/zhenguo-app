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
    if (_refreshed ||
        plan.routeIndex <= _lastRoute ||
        plan.routeIndex >= count) {
      return PlaybackRecoveryAction.stop;
    }
    _lastRoute = plan.routeIndex;
    if (plan.hasAlternative && plan.routeIndex + 1 < count) {
      return PlaybackRecoveryAction.alternative;
    }
    _refreshed = true;
    return PlaybackRecoveryAction.refresh;
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
