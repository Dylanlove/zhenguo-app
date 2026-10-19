import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'app_orientation.dart';
import 'android_video_surface.dart';
import 'catalog_sort.dart';
import 'app_theme.dart';
import 'core_bridge.dart';
import 'cross_source_search.dart';
import 'danmaku_controller.dart';
import 'danmaku_api.dart';
import 'danmaku_models.dart';
import 'danmaku_overlay.dart';
import 'danmaku_settings.dart';
import 'download_picker.dart';
import 'downloads_screen.dart';
import 'follow_state.dart';
import 'glass_panel.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'playback_loader.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_preferences.dart';
import 'playback_diagnostics.dart';
import 'diagnostics_screen.dart';
import 'source_status.dart';
import 'hongguo_series.dart';
import 'player_series.dart';
import 'player_content.dart';
import 'player_route.dart';
import 'player_controls.dart';
import 'player_interactions.dart';
import 'player_menu.dart';
import 'player_rotation_icon.dart';
import 'screen_awake.dart';
import 'search_cache.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'lan_controller.dart';
import 'lan_screen.dart';
import 'video_enhancement.dart';
import 'video_output_size.dart';
import 'sleep_timer.dart';
import 'watch_session.dart';

enum _DanmakuMenuAction { sources, display, keywords, enable, disable }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.danmakuServiceFactory,
    this.handoff,
    this.searchKeyword = '',
    this.initialSeriesEntries,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  final String searchKeyword;
  final List<HongguoSeriesEntry>? initialSeriesEntries;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @visibleForTesting
  final DanmakuService Function()? danmakuServiceFactory;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  VideoController? _video;
  bool _surfaceOutput = false;
  bool _surfaceFailed = false;
  final _videoSurfaceRelease = Completer<void>();
  bool _videoSurfaceReleaseSignaled = false;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  late final String _diagnosticOwner;
  late String _diagnosticTrace;
  Stopwatch? _openClock;
  Stopwatch? _bufferClock;
  bool _progressRecorded = false;
  late final PlayerSeriesController _series;
  int _seasonSwitchTicket = 0;
  bool _switchingSeason = false;
  bool _seasonCommitting = false;
  bool _preloadEnabled = true;
  bool _takingPreload = false;
  final _stablePlayback = Stopwatch();
  late final DanmakuController _danmaku;
  String _danmakuPreferencesJson = '';
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final _screenAwake = ScreenAwake();
  late final SleepTimerController _sleepTimer;
  final _watchSession = WatchSession();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  double? _savedProgressPosition;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _coalesceTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _buffering = false;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool _autoAdvance = true;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _showControlsOnPlaybackReady = true;
  bool _pendingError = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  String? _pictureInPictureSyncKey;
  bool? _pictureInPicturePreference;
  DateTime? _lastBackAt;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  List<Drama> _recommendations = const [];
  bool _recommendationLoading = false;
  String _recommendationKeyword = '';
  int _recommendationGeneration = 0;
  DateTime? _recommendationRetryAfter;
  Timer? _recommendationProgressTimer;
  bool _videoSurfaceMounted = false;
  Size? _lastViewportPixels;
  bool _lastViewportTelevision = false;
  Animation<double>? _routeAnimation;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _resumePosition = 0;
  bool _rotating = false;
  bool _television = false;
  AppOrientationController? _orientationController;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      !_television &&
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  bool get _supportsDanmaku =>
      _plan?.local != true &&
      DanmakuSubject.fromEpisode(
            widget.detail.drama,
            widget.detail.episodes[_index],
          ) !=
          null;
  PlaybackPreferences get _preferences =>
      widget.store.playbackPreferences.copyWith(
        speed: _speed,
        quality: _requestedQuality,
        autoAdvance: _autoAdvance,
        danmaku: _danmakuEnabled,
        preload: _preloadEnabled,
        enhancement: _enhancement.preferences,
      );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? '自动'
      : '${_requestedQuality}P';
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  void _watchRouteAnimation(Animation<double> animation) {
    if (identical(_routeAnimation, animation)) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation..addStatusListener(_onRouteAnimationStatus);
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _videoSurfaceMounted ||
        _closed) {
      return;
    }
    if (!mounted) return;
    setState(() => _videoSurfaceMounted = true);
  }

  Widget _videoSurfaceHost(bool settled) {
    if (!settled && !_videoSurfaceMounted) {
      return const SizedBox.expand();
    }
    if (settled && !_videoSurfaceMounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closed && !_videoSurfaceMounted) {
          setState(() => _videoSurfaceMounted = true);
        }
      });
      return const SizedBox.expand();
    }
    return VideoSurfaceHost(
      player: _player,
      onUnavailable: _fallbackToTextureOutput,
      onReleased: _signalVideoSurfaceReleased,
    );
  }

  void _signalVideoSurfaceReleased() {
    if (_videoSurfaceReleaseSignaled) return;
    _videoSurfaceReleaseSignaled = true;
    _videoSurfaceRelease.complete();
  }

  void _fallbackToTextureOutput() {
    if (_closed || _surfaceFailed || _surfaceOutput == false) return;
    if (widget.videoBuilder != null) return;
    _surfaceFailed = true;
    _surfaceOutput = false;
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isIOS,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _sleepTimer = SleepTimerController(onExpire: _expireSleepTimer)
      ..addListener(_sleepTimerChanged);
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    _diagnosticOwner = '${widget.store.profile.id}:$_profileEpoch';
    _diagnosticTrace = widget.repository.playbackDiagnostics.begin(
      _diagnosticOwner,
    );
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = preferences.quality;
    _autoAdvance = preferences.autoAdvance;
    _danmakuEnabled = preferences.danmaku;
    _preloadEnabled = preferences.preload;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(
      widget.repository,
      onEvent: (event) {
        if (_closed) return;
        _recordPlayback(
          event.stage,
          episode: event.episode,
          elapsedMs: event.elapsedMs,
          message: event.error == null
              ? '预取 ${event.bytes} 字节'
              : '${event.error}',
          state: event.error == null ? 'info' : 'failed',
          code: event.error == null
              ? ''
              : DiagnosticIssue.classify(event.error).code,
        );
      },
    );
    _series = PlayerSeriesController(
      repository: widget.repository,
      store: widget.store,
      anchor: widget.detail.drama,
      initialEntries: widget.initialSeriesEntries,
    )..addListener(_seriesChanged);
    if (!widget.localOnly &&
        widget.mediaId == null &&
        widget.initialSeriesEntries == null)
      unawaited(_series.discover());
    _danmakuPreferencesJson = jsonEncode(preferences.danmakuSettings.toJson());
    _danmaku = DanmakuController(
      service: widget.danmakuServiceFactory?.call(),
      preferences: preferences.danmakuSettings,
      onRememberMatch: (key, match) async {
        if (_closed ||
            widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked)
          return;
        final current = widget.store.playbackPreferences;
        await widget.store.setPlaybackPreferences(
          current.copyWith(
            danmakuSettings: current.danmakuSettings.remember(key, match),
          ),
        );
      },
    )..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player =
        widget.playerFactory?.call() ??
        Player(
          configuration: PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: Platform.isWindows ? MPVLogLevel.v : MPVLogLevel.error,
          ),
        );
    _surfaceOutput = androidSurfaceViewSupported && widget.videoBuilder == null;
    _video = widget.videoBuilder == null && !_surfaceOutput
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration: !Platform.isIOS,
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      holdSpeed: () => widget.store.playbackPreferences.holdSpeed,
      swipeSeek: () => widget.store.playbackPreferences.swipeSeekSeconds,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (!_closed && _acceptErrors && error.trim().isNotEmpty) {
          _recordPlayback(
            '播放器错误',
            state: 'failed',
            message: error,
            code: DiagnosticIssue.classify(error, code: 'MEDIA').code,
          );
        }
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.distinct().listen((buffering) {
        if (!mounted || _closed) return;
        if (_buffering == buffering) return;
        if (buffering) {
          _bufferClock = Stopwatch()..start();
          _recordPlayback('开始缓冲');
        } else if (_bufferClock != null) {
          _recordPlayback(
            '缓冲结束',
            state: 'ok',
            elapsedMs: _bufferClock!.elapsedMilliseconds,
          );
          _bufferClock = null;
        }
        setState(() => _buffering = buffering);
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          _recordPlayback(
            '媒体结束事件',
            message:
                '进度 ${_player.state.position.inSeconds} / ${duration.inSeconds} 秒',
          );
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_sleepTimer.consumeFinishEpisode()) {
            _watchSession.completeEpisode();
            _expireSleepTimer();
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _watchSession.completeEpisode();
            _play(_index + 1, showControlsOnReady: false);
          } else {
            _watchSession.completeEpisode();
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
          if (!_progressRecorded && !_loading && _player.state.playing) {
            _progressRecorded = true;
            _recordPlayback(
              '播放进度开始推进',
              state: 'ok',
              elapsedMs: _openClock?.elapsedMilliseconds ?? 0,
            );
          }
        }
        _scheduleSync();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _coalesceTimer?.cancel();
          _coalesceTimer = null;
          _syncPlayback();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          _scheduleSystemUi();
          unawaited(_syncPictureInPictureParams());
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        _recordPlayback('播放进度停滞', state: 'failed', code: 'STALL');
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null)
        unawaited(widget.repository.release(handoff.plan.session));
      _loading = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
        unawaited(_loadRecommendations());
      }
    });
  }

  SearchCacheEntry? _cachedRecommendations({bool allowStale = false}) {
    final source = widget.detail.drama.source;
    final fromSearch = widget.searchKeyword.trim();
    if (fromSearch.isNotEmpty) {
      return SearchResultCache.instance.read(
        source,
        fromSearch,
        allowStale: allowStale,
      );
    }
    final base = searchKeyword(widget.detail.drama.title);
    if (base.isEmpty) return null;
    final exact = SearchResultCache.instance.read(
      source,
      base,
      allowStale: allowStale,
    );
    if (exact != null) return exact;
    final needle = _normalizedForMatch(base);
    return SearchResultCache.instance.readAnyQuery(
      source,
      allowStale: allowStale,
      where: (entry) {
        final query = _normalizedForMatch(entry.query);
        if (query.isEmpty) return false;
        if (query == needle) return true;
        if (needle.contains(query) || query.contains(needle)) return true;
        return entry.items.any(
          (drama) =>
              _normalizedForMatch(searchKeyword(drama.title)).contains(needle),
        );
      },
    );
  }

  static String _normalizedForMatch(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _sleepTimer.cancel();
      _watchSession.setPlaying(false);
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource(widget.detail.drama.source))) {
      _danmaku.setPlan(null);
    }
    if (!_closed &&
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked) {
      final current = widget.store.playbackPreferences;
      final signature = jsonEncode(current.danmakuSettings.toJson());
      if (signature != _danmakuPreferencesJson) {
        _danmakuPreferencesJson = signature;
        _danmaku.configure(current.danmakuSettings);
      }
      if (_danmakuEnabled != current.danmaku) {
        _danmaku.setEnabled(current.danmaku);
        if (mounted) setState(() => _danmakuEnabled = current.danmaku);
      }
    }
    final autoPictureInPicture =
        widget.store.playbackPreferences.autoPictureInPicture;
    if (autoPictureInPicture != _pictureInPicturePreference) {
      _pictureInPicturePreference = autoPictureInPicture;
      unawaited(_syncPictureInPictureParams());
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  Future<void> _syncPictureInPictureParams() async {
    if (defaultTargetPlatform != TargetPlatform.android || _television) {
      return;
    }
    final enabled =
        _pictureInPictureSupported &&
        widget.store.playbackPreferences.autoPictureInPicture &&
        !_closed;
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    final key = '$enabled:$width:$height';
    if (key == _pictureInPictureSyncKey) return;
    _pictureInPictureSyncKey = key;
    try {
      await AppDevice.channel.invokeMethod<void>('configurePictureInPicture', {
        'enabled': enabled,
        'width': width,
        'height': height,
      });
    } on PlatformException {
    } on MissingPluginException {}
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    unawaited(_syncPictureInPictureParams());
    if (_pictureInPictureVisible || _lifecycleOnScreen) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed && !_pictureInPictureVisible && !_lifecycleOnScreen) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  bool get _lifecycleOnScreen =>
      _lifecycleState == AppLifecycleState.resumed ||
      _lifecycleState == AppLifecycleState.inactive;

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    final visible = _lifecycleOnScreen || _pictureInPictureVisible;
    if (_foreground != visible)
      _recordPlayback(visible ? '播放器返回前台' : '播放器进入后台');
    _foreground = visible;
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _syncScreenAwake();
    _health.reset();
    if (!visible) _interactions.cancel();
    if (pauseWhenHidden &&
        !visible &&
        (_lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.hidden)) {
      _playIntent = false;
      unawaited(_player.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _loading ||
        _error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice('当前设备不支持画中画');
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice('无法进入画中画，请检查系统权限');
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            widget.detail.drama.title +
            ' · 第 ' +
            widget.detail.episodes[_index].number.toString() +
            ' 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch)
      return;
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20)
      return;
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed ||
          generation != _generation ||
          widget.store.profileEpoch != _profileEpoch)
        return;
      _playIntent = false;
      _interactions.cancel();
      _enhancement.suspend();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null)
      return;
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        AppNotice.show(context, error.toString());
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed || _takingPreload) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _stablePlayback.reset();
      _stablePlayback.stop();
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _stablePlayback.reset();
      _stablePlayback.stop();
      _preloader.pause();
      return;
    }
    if (!_stablePlayback.isRunning) _stablePlayback.start();
    if (!PlaybackPreloadPolicy.shouldPrepare(
      position: state.position,
      duration: state.duration,
      buffer: state.buffer,
      rate: state.rate,
      stableFor: _stablePlayback.elapsed,
    ))
      return;
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
      online: _forceOnline,
    );
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource(widget.detail.drama.source),
      discontinuity: discontinuity,
    );
  }

  static const _coalesceInterval = Duration(milliseconds: 50);

  void _sleepTimerChanged() {
    if (mounted && !_closed) setState(() {});
  }

  Future<void> _showSleepTimer() async {
    if (_closed || _panelOpen) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showSleepTimerSheet(
        context,
        controller: _sleepTimer,
        onSelect: (choice) {
          if (!_closed && widget.store.profileEpoch == _profileEpoch) {
            _sleepTimer.select(choice);
          }
        },
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _expireSleepTimer() {
    if (_closed) return;
    _playIntent = false;
    _watchSession.setPlaying(false);
    _interactions.cancel();
    _preloader.clear();
    _screenAwake.disable();
    unawaited(_player.pause().catchError((Object _) {}));
    unawaited(_saveProgress(flush: true));
    _syncDanmaku();
    _notice('睡眠定时已结束，播放已暂停');
  }

  void _syncWatchSession() {
    final state = _player.state;
    _watchSession.setPlaying(
      !_closed &&
          _foreground &&
          _playIntent &&
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          state.playing &&
          !state.buffering &&
          !state.completed &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked,
    );
  }

  void _syncPlayback() {
    _syncWatchSession();
    _syncDanmaku();
    _syncPreload();
    _syncScreenAwake();
    _acknowledgeHandoff();
  }

  void _syncScreenAwake() {
    final active =
        !_closed &&
        _foreground &&
        _playIntent &&
        _error == null &&
        _player.state.playing;
    if (active) {
      _screenAwake.enable();
    } else {
      _screenAwake.disable();
    }
  }

  void _scheduleSync() {
    if (_closed || (_coalesceTimer?.isActive ?? false)) return;
    _coalesceTimer = Timer(_coalesceInterval, () {
      _coalesceTimer = null;
      _syncPlayback();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  void _recordPlayback(
    String stage, {
    String state = 'info',
    String message = '',
    String code = '',
    int elapsedMs = 0,
    int? episode,
  }) {
    if (widget.store.profileEpoch != _profileEpoch || widget.store.locked)
      return;
    widget.repository.playbackDiagnostics.record(
      owner: _diagnosticOwner,
      trace: _diagnosticTrace,
      source: widget.detail.drama.source,
      stage: stage,
      state: state,
      episode: episode ?? widget.detail.episodes[_index].number,
      route: (_plan?.routeIndex ?? 0) + 1,
      elapsedMs: elapsedMs,
      message: message,
      code: code,
    );
  }

  void _seriesChanged() {
    if (mounted && !_closed) {
      setState(() {});
      _menuRevision.value++;
    }
  }

  Future<void> _switchSeason(Drama drama) async {
    if (_closed ||
        _seasonCommitting ||
        widget.localOnly ||
        widget.mediaId != null ||
        drama.source != widget.detail.drama.source ||
        drama.id == widget.detail.drama.id ||
        widget.store.profileEpoch != _profileEpoch ||
        !widget.store.allowsSource(drama.source))
      return;
    final ticket = ++_seasonSwitchTicket;
    var pausedForSwitch = false;
    var previousIntent = false;
    setState(() => _switchingSeason = true);
    bool current() =>
        mounted &&
        !_closed &&
        ticket == _seasonSwitchTicket &&
        widget.store.profileEpoch == _profileEpoch &&
        !widget.store.locked &&
        widget.store.allowsSource(drama.source);
    try {
      final detail = await widget.repository.detail(drama);
      if (!current()) return;
      if (detail.drama.id != drama.id ||
          detail.drama.source != drama.source ||
          detail.episodes.isEmpty)
        throw AppFailure('该季暂未返回有效分集，请稍后重试');
      await _saveProgress(flush: true);
      if (!current()) return;
      await widget.store.refreshDrama(detail.drama);
      if (!current()) return;
      final anchor = widget.detail.drama;
      if (widget.store.following(anchor.id)?.seriesSeasons[drama.id]?.read ==
          false) {
        await widget.store.markSeriesSeasonRead(anchor.id, drama.id);
        if (!current()) return;
      }
      final watched = widget.store.watched(drama.id);
      final index = resumeEpisodeIndex(detail.episodes, watched);
      final position =
          watched?.episode == detail.episodes[index].number &&
              watched?.finished == false
          ? watched!.position
          : 0.0;
      _recordPlayback('切换同系列季', state: 'ok');
      _seasonCommitting = true;
      previousIntent = _playIntent;
      pausedForSwitch = true;
      _playIntent = false;
      _watchSession.setPlaying(false);
      _preloader.clear();
      await _player.pause();
      if (!mounted || !current()) return;
      widget.handoff?.fail('接收端已切换剧集');
      await Navigator.of(context).pushReplacement<void, void>(
        playerRoute(
          PlayerScreen(
            detail: detail,
            initialIndex: index,
            initialPosition: position,
            repository: widget.repository,
            store: widget.store,
            playerFactory: widget.playerFactory,
            videoBuilder: widget.videoBuilder,
            danmakuServiceFactory: widget.danmakuServiceFactory,
            allowOnlineFallback: widget.allowOnlineFallback,
            searchKeyword: widget.searchKeyword,
            initialSeriesEntries: _series.entries,
          ),
        ),
      );
    } catch (error) {
      if (current()) {
        if (pausedForSwitch) {
          _playIntent = previousIntent;
          if (previousIntent && _foreground)
            unawaited(_player.play().catchError((Object _) {}));
        }
        _recordPlayback(
          '切换同系列季失败',
          state: 'failed',
          message: '$error',
          code: DiagnosticIssue.classify(error).code,
        );
        _notice(error is AppFailure ? error.message : '切换该季失败，当前播放已保留');
      }
    } finally {
      if (current())
        setState(() {
          _switchingSeason = false;
          _seasonCommitting = false;
        });
    }
  }

  Future<void> _showPlaybackReport() async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        !widget.store.allowsSource(widget.detail.drama.source))
      return;
    final source = SourceSite.byId(widget.detail.drama.source);
    final version = AppLayout.versionOf(context);
    SourceStatus? status;
    if (widget.repository.supportsSourceManagement) {
      try {
        status = await widget.repository.sourceStatus(source.id);
      } catch (_) {}
    }
    if (!mounted ||
        _closed ||
        widget.store.profileEpoch != _profileEpoch ||
        !widget.store.allowsSource(source.id))
      return;
    final report = DiagnosticReport(
      version: version,
      source: source.id,
      sourceName: source.name,
      fingerprint: source.adapterFingerprint,
      status: status,
      events: widget.repository.playbackDiagnostics.events(
        _diagnosticOwner,
        source.id,
      ),
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(
          store: widget.store,
          report: report,
          profileEpoch: _profileEpoch,
        ),
      ),
    );
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    _recordPlayback(
      switch (action) {
        PlaybackRecoveryAction.alternative => '恢复：切换备用线路',
        PlaybackRecoveryAction.refresh => '恢复：重新解析地址',
        PlaybackRecoveryAction.stop => '自动恢复结束',
      },
      state: action == PlaybackRecoveryAction.stop ? 'failed' : 'info',
      code: action == PlaybackRecoveryAction.stop ? 'MEDIA' : '',
    );
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            if (!_manualRoutesAvailable) {
              await widget.repository.release(current.session);
            }
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : SourceSite.byId(widget.detail.drama.source).filmSource
              ? '自动换线及恢复未成功，请检查网络后重试，也可手动选择播放线路或其他站源。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    _playIntent = !_player.state.playing;
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
  }

  Future<void> _saveProgress({bool flush = false}) async {
    if (_openedIndex < 0 || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    _syncWatchSession();
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex';
    if (!flush &&
        _savedProgressKey == progressKey &&
        _saveWarning == null &&
        _savedProgressPosition != null &&
        (position - _savedProgressPosition!).abs() < .5) {
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    final sample = _watchSession.take();
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(
          entry,
          watchSeconds: sample.seconds,
          completedEpisodes: sample.episodes,
        );
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(
          widget.mediaId!,
          entry,
          watchSeconds: sample.seconds,
          completedEpisodes: sample.episodes,
        );
      }
      _savedProgressKey = progressKey;
      _savedProgressPosition = position;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      _watchSession.restore(sample);
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
    int? route,
  }) async {
    if (_closed ||
        _seasonCommitting ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    _watchSession.setPlaying(false);
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final ticket = ++_generation;
    _acceptErrors = false;
    _takingPreload = true;
    setState(() {
      _loading = true;
      _error = null;
      _loadingMessage = '正在准备播放';
    });
    final warmed =
        handoffPlan ??
        (recoveryAction == null &&
                route == null &&
                _preloadEnabled &&
                !widget.localOnly
            ? await _preloader.takeWhenReady(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
                stillCurrent: () =>
                    !_closed &&
                    ticket == _generation &&
                    widget.store.profileEpoch == _profileEpoch &&
                    !widget.store.locked &&
                    _preloadEnabled &&
                    _foreground &&
                    widget.store.allowsSource(widget.detail.drama.source),
              )
            : null);
    if (_closed ||
        ticket != _generation ||
        widget.store.profileEpoch != _profileEpoch) {
      if (warmed != null) unawaited(widget.repository.release(warmed.session));
      return;
    }
    _takingPreload = false;
    _preloader.clear();
    _stablePlayback.reset();
    _stablePlayback.stop();
    _diagnosticTrace = widget.repository.playbackDiagnostics.begin(
      _diagnosticOwner,
    );
    _openClock = Stopwatch()..start();
    _progressRecorded = false;
    _bufferClock = null;
    _recordPlayback(
      '准备播放',
      episode: widget.detail.episodes[index].number,
      message: warmed != null ? '使用已就绪的播放计划' : '获取播放计划',
    );
    _enhancement.suspend();
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        _ => '正在准备播放',
      };
    });
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress(flush: true);
        await _enhancement.beforeMedia();
        if (_closed || ticket != _generation) return;
        if (recoveryAction == null) _watchSession.beginEpisode();
        _openedIndex = -1;
        await _player.stop();
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative ||
            route != null) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      prepared = retained != null
          ? route != null
                ? await _loader.selectRoute(retained!, route)
                : await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              widget.detail.drama,
              widget.detail.episodes[index],
              quality: _requestedQuality,
              localOnly: widget.localOnly,
              online: _forceOnline,
            );
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      _recordPlayback(
        '播放计划就绪',
        state: 'ok',
        elapsedMs: _openClock?.elapsedMilliseconds ?? 0,
        message: '画质 ${plan.quality} · 已预取 ${plan.prefetchedBytes} 字节',
      );
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          for (final option in {
            'cache-on-disk': 'no',
            'cache-secs': '20',
            'demuxer-readahead-secs': '1',
            'framedrop': 'vo',
            'hr-seek-framedrop': 'yes',
            'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1,avs3',
            if (Platform.isAndroid) 'ao': 'audiotrack,opensles',
          }.entries) {
            await platform.setProperty(option.key, option.value);
          }
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        _recordPlayback('打开媒体', message: plan.local ? '本地媒体' : '在线媒体');
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _generation) {
          return;
        }
        if (!_playIntent || !_foreground) await _player.pause();
        _openedIndex = index;
        _recordPlayback(
          '媒体已打开',
          state: 'ok',
          elapsedMs: _openClock?.elapsedMilliseconds ?? 0,
        );
        _enhancement.mediaReady();
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
          _danmaku.setPlan(
            plan,
            subject: DanmakuSubject.fromEpisode(
              widget.detail.drama,
              widget.detail.episodes[index],
            ),
          );
          _syncWatchSession();
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        _recordPlayback(
          '播放准备失败',
          state: 'failed',
          elapsedMs: _openClock?.elapsedMilliseconds ?? 0,
          message: '$error',
          code: DiagnosticIssue.classify(
            error,
            code: error is AppFailure ? error.code : '',
          ).code,
        );
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _player.state.playing,
    );
  }

  bool get _showFullscreen =>
      _television ||
      _fullscreen ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                television: _television,
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ),
            ));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    AppNotice.show(context, message);
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final nextPreferences = preferences;
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch)
      return;
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    _enhancement.setPreferences(nextPreferences.enhancement);
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _autoAdvance = nextPreferences.autoAdvance;
      _danmakuEnabled = nextPreferences.danmaku;
      _preloadEnabled = nextPreferences.preload;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _toggleDanmaku() => _setDanmakuEnabled(!_danmakuEnabled);

  Future<void> _setDanmakuEnabled(bool enabled) async {
    if (!_supportsDanmaku || _closed || widget.store.locked) return;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: enabled));
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  GlassMenuEntry<_DanmakuMenuAction> _danmakuMenuItem(
    _DanmakuMenuAction action,
    String label,
    IconData icon,
  ) => GlassMenuEntry(
    value: action,
    label: Text(label, key: ValueKey('player-danmaku-${action.name}')),
    trailing: Icon(icon),
  );

  Future<void> _showDanmakuMenu(BuildContext buttonContext) async {
    if (_panelOpen || _closed || !_supportsDanmaku) return;
    final anchor = glassMenuAnchor(buttonContext);
    if (anchor == null) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    _DanmakuMenuAction? action;
    try {
      action = await showGlassMenu<_DanmakuMenuAction>(
        context: buttonContext,
        anchor: anchor,
        alignRight: true,
        entries: [
          _danmakuMenuItem(
            _DanmakuMenuAction.sources,
            '数据源设置',
            Icons.dns_outlined,
          ),
          _danmakuMenuItem(
            _DanmakuMenuAction.display,
            '显示设置',
            Icons.settings_outlined,
          ),
          _danmakuMenuItem(
            _DanmakuMenuAction.keywords,
            '过滤关键词',
            Icons.filter_alt_outlined,
          ),
          _danmakuMenuItem(
            _danmakuEnabled
                ? _DanmakuMenuAction.disable
                : _DanmakuMenuAction.enable,
            _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
            _danmakuEnabled
                ? Icons.highlight_off_rounded
                : Icons.check_circle_outline_rounded,
          ),
        ],
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
    if (!mounted ||
        _closed ||
        widget.store.locked ||
        widget.store.profileEpoch != _profileEpoch)
      return;
    switch (action) {
      case _DanmakuMenuAction.sources:
        await _showDanmakuSettings();
      case _DanmakuMenuAction.display:
        await _showDanmakuSettings(initialTab: DanmakuSettingsTab.display);
      case _DanmakuMenuAction.keywords:
        await _editDanmakuKeywords();
      case _DanmakuMenuAction.enable:
        await _setDanmakuEnabled(true);
      case _DanmakuMenuAction.disable:
        await _setDanmakuEnabled(false);
      case null:
        break;
    }
  }

  Future<void> _editDanmakuKeywords() async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      final keywords = await showDialog<List<String>>(
        context: context,
        builder: (_) => Theme(
          data: Theme.of(context),
          child: DanmakuKeywordsDialog(
            keywords: widget.store.playbackPreferences.danmakuSettings.keywords,
          ),
        ),
      );
      if (keywords == null ||
          !mounted ||
          _closed ||
          widget.store.locked ||
          widget.store.profileEpoch != _profileEpoch)
        return;
      await _setPreferences(
        _preferences.copyWith(
          danmakuSettings: _preferences.danmakuSettings.copyWith(
            keywords: keywords,
          ),
        ),
      );
    } catch (_) {
      _notice('屏蔽关键词未能保存，请重试');
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _showDanmakuSettings({
    DanmakuSettingsTab initialTab = DanmakuSettingsTab.sources,
  }) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => Theme(
          data: _television
              ? televisionTheme(Theme.of(context))
              : Theme.of(context),
          child: DanmakuSettingsPanel(
            store: widget.store,
            controller: _danmaku,
            television: _television,
            initialTab: initialTab,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    AppNotice.showAction(
      context,
      added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过',
      actionLabel: '查看',
      onAction: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DownloadsScreen(
              repository: widget.repository,
              store: widget.store,
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    var openDanmaku = false;
    int? selectedRoute;
    var openDiagnostics = false;
    Drama? selectedSeason;
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _danmaku,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              routeIndex: _plan?.routeIndex ?? 0,
              routeLabel: _plan?.routeLabel,
              routeCount: _plan?.routeCount ?? 0,
              onRoute: _manualRoutesAvailable
                  ? (route) {
                      selectedRoute = route;
                      Navigator.pop(menuContext);
                    }
                  : null,
              local: _plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              mobile: _mobile,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              showDanmaku: _supportsDanmaku,
              danmakuStatus: _danmaku.status,
              onDanmakuSettings: () {
                openDanmaku = true;
                Navigator.pop(menuContext);
              },
              preloadStatus: _preloader.status,
              seriesEntries: widget.localOnly ? const [] : _series.entries,
              currentDramaId: widget.detail.drama.id,
              switchingSeason: _switchingSeason,
              onSeason: (drama) {
                selectedSeason = drama;
                Navigator.pop(menuContext);
              },
              onDiagnostics: () {
                openDiagnostics = true;
                Navigator.pop(menuContext);
              },
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
        ),
      );
      if (mounted && !_closed && index != null && index != _index) {
        await _play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
    if (selectedRoute != null && mounted && !_closed) {
      await _changeRoute(selectedRoute!);
    }
    if (openDiagnostics && mounted && !_closed) {
      await _showPlaybackReport();
      return;
    }
    if (selectedSeason != null && mounted && !_closed) {
      await _switchSeason(selectedSeason!);
      return;
    }
    if (openDanmaku && mounted && !_closed) await _showDanmakuSettings();
  }

  bool get _manualRoutesAvailable =>
      SourceSite.byId(widget.detail.drama.source).filmSource &&
      _plan != null &&
      !_plan!.local &&
      _plan!.routeCount > 1;

  Future<void> _changeRoute(int route) async {
    if (!_manualRoutesAvailable ||
        route == _plan!.routeIndex && _error == null ||
        _loading) {
      return;
    }
    await _play(
      _index,
      position: _error != null
          ? _resumePosition
          : _player.state.position.inMilliseconds / 1000,
      playWhenReady: _error != null ? _playIntent : _player.state.playing,
      route: route,
    );
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
      if (!_closed && ticket == _seekSequence && generation == _generation)
        _recordPlayback(
          '定位完成',
          state: 'ok',
          message: '目标 ${target.inSeconds} 秒',
        );
    } catch (error) {
      if (!_closed && ticket == _seekSequence && generation == _generation)
        _recordPlayback(
          '定位失败',
          state: 'failed',
          message: '$error',
          code: 'MEDIA',
        );
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    Drama? selectedSeason;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (dialogContext) => AnimatedBuilder(
          animation: _series,
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionEpisodeDialog(
              episodes: widget.detail.episodes,
              currentIndex: _index,
              seriesEntries: widget.localOnly ? const [] : _series.entries,
              currentDramaId: widget.detail.drama.id,
              onSeason: _switchingSeason
                  ? null
                  : (drama) {
                      selectedSeason = drama;
                      Navigator.pop(dialogContext);
                    },
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selectedSeason != null && mounted && !_closed) {
      await _switchSeason(selectedSeason!);
      return;
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    var openDanmaku = false;
    int? selectedRoute;
    var openDiagnostics = false;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionSettingsDialog(
              speed: _speed,
              quality: _requestedQuality,
              routeIndex: _plan?.routeIndex ?? 0,
              routeLabel: _plan?.routeLabel,
              routeCount: _plan?.routeCount ?? 0,
              onRoute: _manualRoutesAvailable
                  ? (route) {
                      selectedRoute = route;
                      Navigator.pop(menuContext);
                    }
                  : null,
              qualities: _plan?.qualities ?? [],
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              onFavorite: _toggleFavorite,
              autoAdvance: _autoAdvance,
              showDanmaku: _supportsDanmaku,
              danmakuStatus: _danmaku.status,
              onDanmakuSettings: () {
                openDanmaku = true;
                Navigator.pop(menuContext);
              },
              preload: _preloadEnabled,
              preloadStatus: _preloader.status,
              onDiagnostics: () {
                openDiagnostics = true;
                Navigator.pop(menuContext);
              },
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (openDiagnostics && mounted && !_closed) {
      await _showPlaybackReport();
      return;
    }
    if (openDanmaku && mounted && !_closed) {
      await _showDanmakuSettings();
      return;
    }
    if (selectedRoute != null && mounted && !_closed) {
      await _changeRoute(selectedRoute!);
      return;
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: selection.autoAdvance,
          preload: selection.preload,
          enhancement: selection.enhancement,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  void _back() {
    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(milliseconds: 350)) {
      return;
    }
    _lastBackAt = now;
    if (_showFullscreen && !_television) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _recordPlayback('离开播放');
    _watchSession.setPlaying(false);
    _sleepTimer.removeListener(_sleepTimerChanged);
    _sleepTimer.dispose();
    _closed = true;
    _screenAwake.disable();
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = null;
    final enhancementClosed = _enhancement.close();
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _seasonSwitchTicket++;
    _series.removeListener(_seriesChanged);
    _series.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _coalesceTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _recommendationProgressTimer?.cancel();
    _recommendationProgressTimer = null;
    _recommendationGeneration++;
    _pictureInPictureExitTimer?.cancel();
    unawaited(_syncPictureInPictureParams());
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        if (_surfaceOutput &&
            !_surfaceFailed &&
            _videoSurfaceMounted &&
            !_videoSurfaceReleaseSignaled) {
          await _videoSurfaceRelease.future
              .timeout(const Duration(milliseconds: 600))
              .catchError((Object _) {});
        }
        await _interactions.pendingRates.catchError((Object _) {});
        await enhancementClosed.catchError((Object _) {});
        await _player.dispose();
      }),
    );
    if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile || _television && Platform.isAndroid) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          final bars = AppTheme.systemBars(overlayBrightness);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: _mobile || fullscreen || _pictureInPictureVisible
                ? bars.copyWith(
                    statusBarIconBrightness: Brightness.light,
                    statusBarBrightness: Brightness.dark,
                  )
                : bars,
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible;
    return PopScope(
      canPop: _television || !fullscreen || _error != null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && fullscreen && !_television) {
          _rotate();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: fullscreen || pictureInPicture
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            body: pictureInPicture
                ? _videoPane(context)
                : SafeArea(
                    top: false,
                    bottom: !fullscreen,
                    maintainBottomViewPadding: true,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 840;
                        if (fullscreen) {
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 312 : 210,
                                child: _episodePanel(),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          final height = constraints.maxHeight * .56;
                          return Column(
                            children: [
                              SizedBox(
                                height: height,
                                width: double.infinity,
                                child: _videoPane(context),
                              ),
                              Expanded(child: _mobilePlaybackPanel()),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / _aspectRatio)
                            .clamp(0.0, constraints.maxHeight * .64);
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(child: _episodePanel()),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final videoTheme = _television
        ? televisionTheme(AppTheme.dark)
        : AppTheme.dark;
    final plan = _plan;
    final routeLabel =
        plan != null && (plan.routeIndex > 0 || plan.routeNames.isNotEmpty)
        ? ' · ${plan.routeLabel(plan.routeIndex)}'
        : '';
    final episodeLabel =
        '第 ${widget.detail.episodes[_index].number} 集${plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}$routeLabel';
    final hideOverlayForPictureInPicture = _pictureInPictureVisible;
    final Widget controls = hideOverlayForPictureInPicture || _error != null
        ? const SizedBox.shrink()
        : _television
        ? TelevisionControls(
            player: _player,
            title: widget.detail.drama.title,
            subtitle: episodeLabel,
            episodeNumber: widget.detail.episodes[_index].number,
            episodeCount: widget.detail.episodes.length,
            enabled: !_loading && _error == null,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            enhancement: _enhancementForUi,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            danmakuEnabled: _danmakuEnabled,
            onDanmaku: _supportsDanmaku ? _toggleDanmaku : null,
            onDanmakuSettings: _supportsDanmaku ? _showDanmakuSettings : null,
            onSleepTimer: _showSleepTimer,
            sleepTimerLabel: _sleepTimer.label,
            onBack: _back,
          )
        : PlayerControls(
            player: _player,
            interactions: _interactions,
            enabled: !_loading && _error == null,
            enhancement: _enhancementForUi,
            panelOpen: _panelOpen,
            fullscreen: _showFullscreen,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            title: widget.detail.drama.title,
            subtitle: episodeLabel,
            episodeNumber: widget.detail.episodes[_index].number,
            episodeCount: widget.detail.episodes.length,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile,
            onFullscreen: _rotate,
            onBack: _back,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _speed,
            qualityLabel: _qualityLabel,
            showBufferingMessage: false,
            showDanmaku: _supportsDanmaku,
            danmakuEnabled: _danmakuEnabled,
            danmakuStatus: _danmaku.status,
            onEpisodes: () => _openPanel(PlayerMenuSection.episodes),
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onSleepTimer: _showSleepTimer,
            sleepTimerLabel: _sleepTimer.label,
            onDanmakuMenu: _supportsDanmaku ? _showDanmakuMenu : null,
            onPush: widget.mediaId == null ? _pushToDevice : null,
            onPictureInPicture: _canUsePictureInPicture
                ? _enterPictureInPicture
                : null,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (_loading && !hideOverlayForPictureInPicture)
          const ColoredBox(color: Colors.black),
        if (!_loading && _error == null && !hideOverlayForPictureInPicture)
          DanmakuOverlay(
            controller: _danmaku,
            aspectRatio: _aspectRatio,
            television: _television,
          ),
        controls,
        if ((_loading || _buffering) &&
            _error == null &&
            !hideOverlayForPictureInPicture)
          PlayerStatusMessage(message: _loading ? _loadingMessage : '正在缓冲'),
      ],
    );
    return Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final routeAnimation = ModalRoute.of(context)?.animation;
          final settled = routeAnimation == null || routeAnimation.isCompleted;
          if (!settled && !_videoSurfaceMounted) {
            _watchRouteAnimation(routeAnimation);
          }
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final pixels = Size(
            constraints.maxWidth * ratio,
            constraints.maxHeight * ratio,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final changed =
                _lastViewportPixels != pixels ||
                _lastViewportTelevision != _television;
            if (mounted && !_closed && changed) {
              _lastViewportPixels = pixels;
              _lastViewportTelevision = _television;
              _enhancement.setViewport(pixels, television: _television);
            }
          });
          return Stack(
            key: _videoPaneKey,
            fit: StackFit.expand,
            children: [
              if (widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else if (_surfaceOutput) ...[
                const ColoredBox(color: Colors.black),
                _videoSurfaceHost(settled),
                layeredControls,
              ] else
                Video(
                  controller: _video!,
                  fit: BoxFit.contain,
                  wakelock: false,
                  controls: (_) => layeredControls,
                ),
              if (_error != null && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black,
                  child: StatusPanel(
                    title: '暂时无法播放',
                    message: _error!,
                    onRetry: () => _retry(),
                    action: _localFailure ? '重试本地播放' : '重试播放',
                    secondaryAction: PlayerFailureActions(
                      onReport: _showPlaybackReport,
                      onRoutes: _manualRoutesAvailable
                          ? () => _television
                                ? _televisionSettings(context)
                                : _openPanel(PlayerMenuSection.quality)
                          : null,
                      onSearch: widget.mediaId == null
                          ? () => showCrossSourceSearch(
                              context,
                              drama: widget.detail.drama,
                              repository: widget.repository,
                              store: widget.store,
                            )
                          : null,
                      onSwitchOnline:
                          _localFailure && widget.allowOnlineFallback
                          ? _switchOnline
                          : null,
                      sourceDiagnostics:
                          !_localFailure &&
                              !widget.localOnly &&
                              widget.repository.supportsSourceManagement
                          ? SourceDiagnosticsButton(
                              repository: widget.repository,
                              store: widget.store,
                              drama: widget.detail.drama,
                            )
                          : null,
                    ),
                    icon: Icons.play_disabled_rounded,
                  ),
                ),
              if (_error != null &&
                  !hideOverlayForPictureInPicture &&
                  !_television)
                SafeArea(
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: _showFullscreen ? '退出全屏' : '返回',
                          onPressed: _back,
                          style: IconButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.black54,
                          ),
                          icon: Icon(
                            _showFullscreen || !_mobile
                                ? Icons.arrow_back_rounded
                                : Icons.arrow_back_ios_new_rounded,
                          ),
                        ),
                        const Spacer(),
                        if (_showFullscreen)
                          TextButton(
                            onPressed: () =>
                                _openPanel(PlayerMenuSection.episodes),
                            child: const Text('选集'),
                          )
                        else
                          IconButton(
                            tooltip: '旋转与全屏',
                            onPressed: _rotate,
                            style: IconButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.black54,
                            ),
                            icon: const PlayerRotationIcon(),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_saveWarning != null && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _saveWarning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: const Text('重试保存'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _mobilePlaybackPanel() => PlayerContentPanel(
    currentTab: _mobileTab,
    onTabChanged: (value) {
      setState(() => _mobileTab = value);
      if (value == 2) unawaited(_loadRecommendations());
    },
    episodes: _episodePanel(compact: true),
    synopsis: _mobileSynopsis(),
    recommendations: _mobileRecommendations(),
    downloads: _mobileDownload(),
  );

  Widget _mobileRecommendations() {
    final colors = Theme.of(context).colorScheme;
    if (_recommendations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '暂无可推荐的相关剧集',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      );
    }
    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              itemCount: _recommendations.length,
              itemBuilder: (context, index) {
                final drama = _recommendations[index];
                final accent = Theme.of(context).colorScheme.primary;
                return InkWell(
                  key: ValueKey('recommend-${drama.id}'),
                  onTap: () => _openRecommendation(drama),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 58,
                            height: 82,
                            child: DramaCover(
                              drama: drama,
                              repository: widget.repository,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                drama.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _recommendationChip(
                                    SourceSite.byId(drama.source).name,
                                    accent,
                                  ),
                                  if (drama.episodes > 0)
                                    _recommendationChip(
                                      '共 ${drama.episodes} 集',
                                      accent,
                                    ),
                                  if (drama.releaseStatus.isNotEmpty &&
                                      drama.releaseStatus != 'unknown')
                                    _recommendationChip(
                                      drama.releaseLabel,
                                      accent,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _recommendationChip(String label, Color accent) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: accent, height: 1.4),
    ),
  );

  void _openRecommendation(Drama drama) {
    unawaited(
      openPlaybackDirectly(
        context,
        drama: widget.repository.catalogUpdates.current(drama),
        repository: widget.repository,
        store: widget.store,
        searchKeyword: _recommendationKeyword,
      ),
    );
  }

  Future<void> _loadRecommendations() async {
    if (!mounted || _closed || _recommendationLoading) return;
    final source = widget.detail.drama.source;
    final fromSearch = widget.searchKeyword.trim();
    final fallbackKeyword = searchKeyword(widget.detail.drama.title);
    final cached = _cachedRecommendations(allowStale: true);
    if (cached != null) {
      if (cached.fresh ||
          _recommendations.isEmpty ||
          _recommendationKeyword != cached.query) {
        _applyRecommendations(cached.items, keyword: cached.query);
      }
      if (cached.fresh) return;
    }
    final retryAfter = _recommendationRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    final keyword = fromSearch.isNotEmpty
        ? fromSearch
        : cached?.query ?? fallbackKeyword;
    if (keyword.isEmpty) return;
    final generation = ++_recommendationGeneration;
    setState(() {
      _recommendationKeyword = keyword;
      _recommendationLoading = true;
    });
    _startRecommendationPolling(source, keyword, generation);
    try {
      final result = await SearchResultCache.instance.coalesce(
        source,
        keyword,
        () async {
          final page = await widget.repository.catalog(source, query: keyword);
          final cached = SearchCacheEntry(
            source: source,
            query: keyword,
            items: List<Drama>.unmodifiable(page.items),
            total: page.items.length,
            warning: page.warning,
          );
          SearchResultCache.instance.write(cached);
          return cached;
        },
      );
      if (!mounted || _closed || generation != _recommendationGeneration) {
        return;
      }
      final relevant = _relevantRecommendations(result.items, keyword);
      setState(() {
        if (result.warning.isEmpty ||
            relevant.length > _recommendations.length) {
          _recommendations = _sortedRecommendations(relevant);
        }
        _recommendationLoading = false;
        _recommendationRetryAfter = result.warning.isEmpty
            ? null
            : DateTime.now().add(const Duration(minutes: 1));
      });
    } catch (_) {
      if (!mounted || _closed || generation != _recommendationGeneration) {
        return;
      }
      setState(() {
        _recommendationLoading = false;
        _recommendationRetryAfter = DateTime.now().add(
          const Duration(minutes: 1),
        );
      });
    } finally {
      if (generation == _recommendationGeneration) {
        _stopRecommendationPolling();
      }
    }
  }

  void _startRecommendationPolling(
    String source,
    String keyword,
    int generation,
  ) {
    _stopRecommendationPolling();
    var polling = false;
    _recommendationProgressTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) async {
        if (!mounted || _closed || generation != _recommendationGeneration) {
          _stopRecommendationPolling();
          return;
        }
        if (polling || !_recommendationLoading) return;
        polling = true;
        try {
          final page = await widget.repository.searchProgress(source, keyword);
          if (!mounted ||
              _closed ||
              !_recommendationLoading ||
              generation != _recommendationGeneration) {
            return;
          }
          final relevant = _relevantRecommendations(page.items, keyword);
          if (relevant.isEmpty || relevant.length <= _recommendations.length) {
            return;
          }
          setState(() {
            _recommendations = _sortedRecommendations(relevant);
          });
        } catch (_) {
        } finally {
          polling = false;
        }
      },
    );
  }

  void _stopRecommendationPolling() {
    _recommendationProgressTimer?.cancel();
    _recommendationProgressTimer = null;
  }

  List<Drama> _relevantRecommendations(Iterable<Drama> items, String keyword) {
    final needle = _normalizedForMatch(searchKeyword(keyword));
    if (needle.isEmpty) return items.toList();
    final matched = items
        .where(
          (drama) =>
              _normalizedForMatch(searchKeyword(drama.title)).contains(needle),
        )
        .toList();
    return matched.isEmpty ? items.toList() : matched;
  }

  List<Drama> _sortedRecommendations(Iterable<Drama> items) =>
      [...items]..sort((a, b) => naturalTitleCompare(a.title, b.title));

  void _applyRecommendations(List<Drama> items, {required String keyword}) {
    if (!mounted) return;
    setState(() {
      _recommendationKeyword = keyword;
      _recommendations = _sortedRecommendations(
        _relevantRecommendations(items, keyword),
      );
      _recommendationLoading = false;
    });
  }

  Widget _mobileSynopsis() => PlayerSynopsisView(
    detail: widget.detail,
    repository: widget.repository,
    followControl: _mobileFollowControl(widget.detail.drama),
  );

  Widget _mobileFollowControl(Drama drama) {
    final state = widget.store.following(drama.id);
    return Tooltip(
      message: '追剧与观看状态',
      child: Builder(
        builder: (menuContext) => InkWell(
          key: const ValueKey('player-follow-status'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => unawaited(_openFollowMenu(menuContext, drama, state)),
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: state == null
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  state == null
                      ? Icons.bookmark_add_outlined
                      : Icons.bookmark_rounded,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(state?.label ?? '加入追剧'),
                const SizedBox(width: 2),
                const Icon(Icons.expand_more_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFollowMenu(
    BuildContext menuContext,
    Drama drama,
    FollowState? state,
  ) async {
    final anchor = glassMenuAnchor(menuContext);
    if (anchor == null) return;
    final value = await showGlassMenu<String>(
      context: menuContext,
      anchor: anchor,
      autofocusSelected: true,
      entries: [
        for (final status in FollowStatus.values)
          GlassMenuEntry(
            value: status.name,
            label: Text(status.label),
            selected: state?.status == status,
          ),
        if (state != null)
          const GlassMenuEntry(
            value: 'remove',
            label: Text('取消追剧'),
            leading: Icon(Icons.bookmark_remove_outlined),
          ),
      ],
    );
    if (value == null || !mounted || _closed) return;
    if (_profileEpoch != widget.store.profileEpoch) return;
    if (value == 'remove') {
      await saveUserChange(context, () => widget.store.toggleFavorite(drama));
    } else {
      final status = FollowStatus.values.firstWhere(
        (status) => status.name == value,
      );
      await saveUserChange(
        context,
        () => widget.store.setFollowStatus(drama, status),
      );
    }
    if (mounted && !_closed) setState(() {});
  }

  Widget _mobileDownload() {
    final colors = Theme.of(context).colorScheme;
    if (!widget.repository.supportsDownloads || !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surface,
        child: const StatusPanel(
          title: '下载不可用',
          message: '当前用户或当前环境未开放本地下载。',
          icon: Icons.download_outlined,
        ),
      );
    }
    return DownloadPicker(
      detail: widget.detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _episodePanel({bool compact = false}) => AnimatedBuilder(
    animation: Listenable.merge([_series, _preloader]),
    builder: (context, _) => ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          if (!widget.localOnly && widget.mediaId == null)
            PlayerSeriesBar(
              entries: _series.entries,
              currentDramaId: widget.detail.drama.id,
              onSelected: _switchSeason,
              busy: _switchingSeason,
            ),
          Expanded(
            child: PlayerEpisodeGrid(
              episodes: widget.detail.episodes,
              currentIndex: _index,
              compact: compact,
              title: compact ? '剧集' : '选集',
              onSelected: (index) => _play(index),
            ),
          ),
          if (_preloadEnabled && _preloader.active)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                _preloader.status,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    ),
  );
}
