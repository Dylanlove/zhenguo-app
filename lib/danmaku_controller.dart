import 'dart:async';

import 'package:flutter/foundation.dart';

import 'danmaku_api.dart';
import 'danmaku_models.dart';
import 'danmaku_preferences.dart';
import 'models.dart';

class DanmakuController extends ChangeNotifier {
  DanmakuController({
    DanmakuService? service,
    DanmakuPreferences preferences = const DanmakuPreferences(),
    DateTime Function()? now,
    this.onRememberMatch,
  }) : service = service ?? DanmakuApiClient(),
       _preferences = preferences {
    final clock = Stopwatch()..start();
    _now =
        now ??
        () => DateTime.fromMillisecondsSinceEpoch(clock.elapsedMilliseconds);
  }

  final DanmakuService service;
  final Future<void> Function(String key, DanmakuMatch match)? onRememberMatch;
  late final DateTime Function() _now;
  DanmakuPreferences _preferences;
  DanmakuPreferences get preferences => _preferences;
  PlaybackPlan? _plan;
  DanmakuSubject? _subject;
  DanmakuSubject? get subject => _subject;
  DanmakuMatch? _match;
  DanmakuMatch? get currentMatch => _match;
  DanmakuCancellation? _pending;
  int _generation = 0;
  bool _closed = false, _enabled = true, _available = false, _foreground = true;
  bool _playing = false,
      _buffering = false,
      _seeking = false,
      _loaded = false,
      _attempted = false;
  String? _error;
  String? get error => _error;
  int positionMs = 0, durationMs = 0;
  double rate = 1;
  int motionRevision = 0, dataRevision = 0;
  List<DanmakuItem> items = const [];
  DateTime? _anchorTime;
  double _anchorPosition = 0;

  bool get enabled => _enabled;
  bool get supported => _plan != null && !_plan!.local && _subject != null;
  bool get visible =>
      !_closed &&
      supported &&
      _enabled &&
      _available &&
      _foreground &&
      !_seeking &&
      _loaded &&
      (durationMs == 0 || positionMs < durationMs);
  bool get moving => visible && items.isNotEmpty && _playing && !_buffering;
  bool get loading => _pending != null;
  bool get canRetry =>
      supported &&
      _enabled &&
      _preferences.source != null &&
      !loading &&
      (_error != null || (_attempted && _match == null));
  double get timelinePositionMs {
    if (!moving || _anchorTime == null) return _anchorPosition;
    final elapsed = _now().difference(_anchorTime!).inMicroseconds / 1000;
    final projected = _anchorPosition + elapsed.clamp(0, 2000) * rate;
    return durationMs > 0
        ? projected.clamp(0, durationMs.toDouble())
        : projected;
  }

  String get status {
    if (!_enabled) return '弹幕已关闭';
    if (_plan?.local == true) return '本地播放不加载在线弹幕';
    if (_plan != null && !supported) return '缺少有效的剧名或分集信息';
    if (_preferences.source == null) return '尚未配置弹幕 API，请先添加数据源';
    if (_error != null) return _error!;
    if (loading) return _match == null ? '正在匹配作品与分集…' : '正在加载弹幕…';
    if (_loaded) return items.isEmpty ? '本集暂无弹幕' : '已载入 ${items.length} 条弹幕';
    if (_attempted && _match == null) return '未找到唯一匹配，请手动搜索作品和分集';
    if (!_preferences.autoMatch && _match == null) return '自动匹配已关闭，可手动搜索';
    return '等待视频就绪';
  }

  void setPlan(PlaybackPlan? plan, {DanmakuSubject? subject}) {
    if (_closed) return;
    _cancel();
    _plan = plan;
    _subject = subject;
    _clearData();
    _seeking = false;
    _available = false;
    positionMs = durationMs = 0;
    _anchorPosition = 0;
    _resetMotion();
    notifyListeners();
  }

  void configure(DanmakuPreferences value) {
    if (_closed || identical(_preferences, value)) return;
    final changedSource =
        _preferences.source?.id != value.source?.id ||
        _preferences.source?.baseUrl != value.source?.baseUrl;
    final autoEnabled = !_preferences.autoMatch && value.autoMatch;
    final wasAuto = _preferences.autoMatch;
    _preferences = value;
    if (changedSource ||
        (wasAuto && !value.autoMatch && loading && _match == null)) {
      _cancel();
      _clearData();
    }
    if (autoEnabled) {
      _attempted = false;
      _error = null;
    }
    dataRevision++;
    notifyListeners();
    _ensureLoad();
  }

  void setEnabled(bool enabled) {
    if (_closed || _enabled == enabled) return;
    _anchorPosition = timelinePositionMs;
    _enabled = enabled;
    _cancel();
    _attempted = _loaded;
    _error = null;
    _resetMotion();
    notifyListeners();
    _ensureLoad();
  }

  void update({
    required Duration position,
    required Duration duration,
    required double speed,
    required bool playing,
    required bool buffering,
    required bool foreground,
    required bool available,
    bool discontinuity = false,
  }) {
    if (_closed) return;
    final previousMoving = moving, previousVisible = visible;
    final predicted = timelinePositionMs;
    final next = position.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    final nextRate = speed.isFinite && speed > 0 ? speed : 1.0;
    final jumped =
        discontinuity || next < positionMs - 250 || next - positionMs > 2000;
    final drift = (next - predicted).abs() > 180;
    final speedChanged = nextRate != rate;
    if (!_seeking) positionMs = next;
    durationMs = duration.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    rate = nextRate;
    _playing = playing;
    _buffering = buffering;
    _foreground = foreground;
    _available = available;
    if ((!available || !foreground) && loading) {
      _cancel();
      _attempted = _loaded;
    }
    if (jumped ||
        drift ||
        speedChanged ||
        previousMoving != moving ||
        previousVisible != visible) {
      _anchorPosition = _seeking ? predicted : positionMs.toDouble();
      _resetMotion();
      notifyListeners();
    } else if (_anchorTime == null ||
        _now().difference(_anchorTime!).inMilliseconds > 800) {
      _anchorPosition = predicted;
      _anchorTime = _now();
    }
    _ensureLoad();
  }

  void beginSeek() {
    if (_closed) return;
    _anchorPosition = timelinePositionMs;
    _seeking = true;
    _resetMotion();
    notifyListeners();
  }

  void endSeek(Duration position) {
    if (_closed) return;
    _seeking = false;
    positionMs = position.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    _anchorPosition = positionMs.toDouble();
    _resetMotion();
    notifyListeners();
    _ensureLoad();
  }

  void retry({bool rematch = false}) {
    if (_closed || !_enabled) return;
    _cancel();
    _attempted = false;
    _loaded = false;
    _error = null;
    if (rematch) _match = null;
    _ensureLoad(ignoreSaved: rematch);
    notifyListeners();
  }

  Future<void> selectMatch(DanmakuMatch match) async {
    if (_closed || !supported || match.sourceId != _preferences.source?.id)
      return;
    final subject = _subject!;
    _cancel();
    _clearData();
    _match = match;
    _preferences = _preferences.remember(subject.key, match);
    notifyListeners();
    _ensureLoad();
    await onRememberMatch?.call(subject.key, match);
  }

  void _resetMotion() {
    motionRevision++;
    _anchorTime = _now();
  }

  void _cancel() {
    _generation++;
    _pending?.cancel();
    _pending = null;
  }

  void _clearData() {
    _match = null;
    _error = null;
    _loaded = _attempted = false;
    items = const [];
    dataRevision++;
  }

  void _ensureLoad({bool ignoreSaved = false}) {
    if (_closed ||
        !_enabled ||
        !supported ||
        !_available ||
        !_foreground ||
        _buffering ||
        _seeking ||
        loading ||
        _loaded ||
        _attempted ||
        _preferences.source == null)
      return;
    final saved = ignoreSaved
        ? null
        : _preferences.savedMatch(_subject!.key, _preferences.source!.id);
    if (_match == null && saved?.sourceId == _preferences.source!.id)
      _match = saved;
    if (_match == null && !_preferences.autoMatch) return;
    unawaited(_load(rematch: ignoreSaved));
  }

  Future<void> _load({bool rematch = false}) async {
    final ticket = _generation;
    final source = _preferences.source!, subject = _subject!;
    final cancel = DanmakuCancellation();
    _pending = cancel;
    _attempted = true;
    notifyListeners();
    try {
      final match =
          _match ??
          await service.match(source, subject, cancel, force: rematch);
      if (_closed || ticket != _generation) return;
      cancel.check();
      _match = match;
      if (match == null) return;
      notifyListeners();
      final loaded = await service.comments(source, match, cancel);
      if (_closed || ticket != _generation) return;
      cancel.check();
      items = List.unmodifiable(loaded);
      _loaded = true;
      dataRevision++;
      _anchorPosition = positionMs.toDouble();
      _resetMotion();
    } on DanmakuCancelled {
      return;
    } catch (error) {
      if (_closed || ticket != _generation) return;
      _error = error is DanmakuApiException ? error.message : '弹幕加载失败，可重试或手动搜索';
    } finally {
      if (!_closed && ticket == _generation) {
        _pending = null;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _cancel();
    service.dispose();
    items = const [];
    super.dispose();
  }
}
