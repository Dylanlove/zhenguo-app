import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'lan_controller.dart';
import 'player_chrome.dart';
import 'player_danmaku_icon.dart';
import 'player_feedback.dart';
import 'player_interactions.dart';
import 'player_rotation_icon.dart';
import 'widgets.dart';
import 'video_enhancement.dart';

class PlayerStatusMessage extends StatelessWidget {
  const PlayerStatusMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              shadows: [
                Shadow(color: Colors.black87, blurRadius: 6),
                Shadow(color: Colors.black54, blurRadius: 12),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    required this.onFullscreen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.title,
    required this.onTogglePlayback,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onQuality,
    required this.speed,
    required this.qualityLabel,
    required this.onFocusSurface,
    this.showBufferingMessage = true,
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.danmakuStatus = '',
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.onSeek,
    this.onDanmakuMenu,
    this.onPush,
    this.onPictureInPicture,
    this.onRotate,
    this.onSleepTimer,
    this.sleepTimerLabel = '',
    this.onCatchup,
    this.catchupActive = false,
    this.autoHideDelay,
    this.showProgress = true,
    this.showMiniProgress = true,
    this.enhancement,
    this.subtitle,
    this.episodeNumber,
    this.episodeCount,
  });

  final Player player;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String title;
  final String? subtitle;
  final int? episodeNumber;
  final int? episodeCount;
  final VoidCallback onTogglePlayback;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSpeed;
  final Future<void> Function() onQuality;

  /// 垂直布局下也常驻的旋转入口。直播页整屏都是播放器，没有「退出全屏」
  /// 这个中间状态可用来暴露旋转按钮，必须单独给一个入口。
  final VoidCallback? onRotate;
  final Future<void> Function()? onSleepTimer;
  final String sleepTimerLabel;
  final Future<void> Function()? onCatchup;
  final bool catchupActive;
  final Duration? autoHideDelay;
  final bool showProgress;
  final bool showMiniProgress;
  final double speed;
  final String qualityLabel;
  final VoidCallback onFocusSurface;
  final bool showBufferingMessage;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final String danmakuStatus;
  final bool swipeEnabled;
  final bool panelOpen;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function(BuildContext)? onDanmakuMenu;
  final Future<void> Function()? onPush;
  final Future<void> Function()? onPictureInPicture;
  final VideoEnhancementController? enhancement;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  bool _visible = true;
  bool _suppressAutoPlaybackStart = false;
  bool _lastPlaying = false;
  bool _panelActive = false;
  double _doubleTapX = 0;
  Timer? _progressTimer;
  DateTime? _progressPaintedAt;

  @override
  void initState() {
    super.initState();
    _visible = widget.showOnPlaybackReady;
    _suppressAutoPlaybackStart = !widget.showOnPlaybackReady;
    _lastPlaying = widget.player.state.playing;
    for (final stream in [
      widget.player.stream.duration,
      widget.player.stream.playing,
      widget.player.stream.volume,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      widget.player.stream.buffering.distinct().listen((_) {
        if (!mounted) return;
        setState(() {});
        _scheduleHide();
      }),
    );
    for (final stream in [
      widget.player.stream.position,
      widget.player.stream.buffer,
    ]) {
      _subscriptions.add(stream.listen((_) => _tickProgress()));
    }
    _subscriptions.add(
      widget.player.stream.playing.listen((playing) {
        final wasPlaying = _lastPlaying;
        _lastPlaying = playing;
        if (!mounted || !widget.enabled) return;
        if (widget.interactions.operating) return;
        if (!playing) {
          _show();
        } else if (!wasPlaying) {
          if (_suppressAutoPlaybackStart) {
            _suppressAutoPlaybackStart = false;
            _scheduleHide();
          } else {
            _show();
          }
        }
      }),
    );
    widget.interactions.addListener(_interactionChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.autoHideDelay != oldWidget.autoHideDelay ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      widget.interactions.cancel(resumeScrub: true);
      if (widget.showOnPlaybackReady) {
        _suppressAutoPlaybackStart = false;
      } else if (widget.enabled && !oldWidget.enabled) {
        _suppressAutoPlaybackStart = !widget.player.state.playing;
      } else if (!widget.enabled && oldWidget.enabled) {
        _suppressAutoPlaybackStart = true;
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        if (widget.showOnPlaybackReady || !widget.player.state.playing) {
          _visible = true;
        } else {
          _visible = false;
        }
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      _scheduleHide();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    if (widget.interactions.operating || widget.interactions.feedback.visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      setState(() {});
      _scheduleHide();
    }
  }

  bool get _canAutoHide =>
      _visible &&
      widget.enabled &&
      !widget.panelOpen &&
      !_panelActive &&
      widget.player.state.playing &&
      !widget.player.state.buffering &&
      !widget.interactions.operating &&
      !widget.interactions.feedback.visible;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_canAutoHide) return;
    final delay =
        widget.autoHideDelay ?? Duration(seconds: widget.fullscreen ? 4 : 3);
    _hideTimer = Timer(delay, () {
      _hideTimer = null;
      if (mounted && _canAutoHide) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!mounted ||
        widget.interactions.operating ||
        widget.interactions.feedback.visible) {
      return;
    }
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _tap() {
    if (widget.interactions.suppressTap || widget.interactions.scrubbing)
      return;
    widget.onFocusSurface();
    widget.interactions.feedback.clear();
    setState(() => _visible = !_visible);
    _scheduleHide();
  }

  Future<void> _panel(Future<void> Function() open) async {
    if (_panelActive) return;
    _panelActive = true;
    _hideTimer?.cancel();
    widget.interactions.cancel(resumeScrub: true);
    try {
      await open();
    } finally {
      _panelActive = false;
      _show();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    widget.interactions.removeListener(_interactionChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  static const _progressInterval = Duration(milliseconds: 240);

  void _tickProgress() {
    if (!mounted || (!_chromeVisible && !_miniProgressVisible)) return;
    final now = DateTime.now();
    final paintedAt = _progressPaintedAt;
    if (paintedAt == null || now.difference(paintedAt) >= _progressInterval) {
      _progressPaintedAt = now;
      _progressTimer?.cancel();
      _progressTimer = null;
      setState(() {});
      return;
    }
    if (_progressTimer?.isActive ?? false) return;
    _progressTimer = Timer(_progressInterval - now.difference(paintedAt), () {
      _progressTimer = null;
      if (!mounted || (!_chromeVisible && !_miniProgressVisible)) return;
      _progressPaintedAt = DateTime.now();
      setState(() {});
    });
  }

  bool get _miniProgressVisible =>
      widget.showProgress &&
      widget.showMiniProgress &&
      !_chromeVisible &&
      widget.player.state.duration > Duration.zero;

  bool get _chromeVisible {
    if (widget.panelOpen || _panelActive) return true;
    if (widget.interactions.operating || widget.interactions.feedback.visible) {
      return false;
    }
    final state = widget.player.state;
    if (!widget.showOnPlaybackReady &&
        (!widget.enabled || !state.playing || state.buffering)) {
      return _visible || widget.panelOpen;
    }
    return !widget.enabled ||
        _visible ||
        !state.playing ||
        state.buffering ||
        widget.panelOpen;
  }

  bool get _episodeChrome => widget.subtitle != null;

  bool get _portraitLayout =>
      _episodeChrome &&
      widget.swipeEnabled &&
      MediaQuery.orientationOf(context) == Orientation.portrait;

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position = state.position.inMilliseconds / 1000;
    final buffered = state.buffer.inMilliseconds / 1000;
    final visible = _chromeVisible;
    final episodeChrome = _episodeChrome;
    final compactCenter =
        episodeChrome &&
        widget.swipeEnabled &&
        !_portraitLayout &&
        widget.onPictureInPicture == null &&
        widget.onCatchup == null;
    final centerBottomInset = compactCenter ? 96.0 : 126.0;
    final safePadding = MediaQuery.paddingOf(context);
    return MouseRegion(
      onHover: (_) => _show(),
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('player-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                widget.onFocusSurface();
                widget.interactions.pointerDown(
                  event,
                  swipeEnabled: widget.swipeEnabled,
                  height: constraints.maxHeight,
                  width: constraints.maxWidth,
                );
              },
              onPointerMove: widget.interactions.pointerMove,
              onPointerUp: widget.interactions.pointerUp,
              onPointerCancel: widget.interactions.pointerCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTapDown: (details) =>
                    _doubleTapX = details.localPosition.dx,
                onDoubleTap: () {
                  if (!widget.enabled || widget.interactions.suppressTap) {
                    return;
                  }
                  widget.interactions.doubleTap(
                    _doubleTapX,
                    constraints.maxWidth,
                    mobile: widget.swipeEnabled,
                  );
                  _show();
                },
              ),
            ),
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: episodeChrome
                                ? playerChromeGradient(
                                    height: constraints.maxHeight,
                                    topInset: _topChromeInset(),
                                    bottomInset: _bottomChromeInset(),
                                  )
                                : const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xAA000000),
                                      Colors.transparent,
                                      Color(0xE6000000),
                                    ],
                                    stops: [0, .45, 1],
                                  ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          episodeChrome ? safePadding.left + 8 : 8,
                          _topChromeInset(),
                          episodeChrome ? safePadding.right + 8 : 8,
                          _bottomChromeInset(),
                        ),
                        child: Stack(
                          children: [
                            if (widget.fullscreen ||
                                widget.swipeEnabled ||
                                episodeChrome)
                              _topBar(),
                            if (!state.buffering &&
                                !widget.interactions.scrubbing &&
                                widget.enabled &&
                                constraints.maxHeight >=
                                    (episodeChrome
                                        ? _topChromeInset() +
                                              _bottomChromeInset() +
                                              centerBottomInset +
                                              122
                                        : widget.swipeEnabled
                                        ? 168
                                        : 220))
                              Padding(
                                padding: episodeChrome
                                    ? EdgeInsets.only(
                                        top: 60,
                                        bottom: centerBottomInset,
                                      )
                                    : EdgeInsets.zero,
                                child: _centerPlayback(
                                  state.playing,
                                  showSkip: true,
                                ),
                              ),
                            if (widget.enabled) ...[
                              _sideDanmakuControl(),
                              _bottomControls(
                                constraints: constraints,
                                volume: state.volume,
                                duration: duration,
                                position: position,
                                buffered: buffered,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _miniProgress(position, duration),
            _gestureFeedback(),
          ],
        ),
      ),
    );
  }

  Widget _miniProgress(double position, double duration) {
    if (!_miniProgressVisible) return const SizedBox.shrink();
    final previewPosition =
        (widget.interactions.scrubTarget?.inMilliseconds ??
            (position * 1000).round()) /
        1000;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: SizedBox(
          height: 2.5,
          child: LinearProgressIndicator(
            value: duration > 0
                ? (previewPosition / duration).clamp(0.0, 1.0)
                : 0,
            minHeight: 2.5,
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final compact = widget.swipeEnabled && !widget.fullscreen;
    final episodeChrome = _episodeChrome;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: compact ? 8 : 0),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: widget.fullscreen ? '退出全屏' : '返回',
              onPressed: widget.fullscreen
                  ? widget.onFullscreen
                  : widget.onBack,
              icon: Icon(
                widget.fullscreen || !widget.swipeEnabled
                    ? Icons.arrow_back_rounded
                    : Icons.arrow_back_ios_new_rounded,
              ),
            ),
            if (episodeChrome) const SizedBox(width: 16),
            if (!compact || episodeChrome)
              Expanded(
                child: episodeChrome
                    ? PlayerChromeTitle(
                        title: widget.title,
                        subtitle: widget.subtitle!,
                      )
                    : Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              )
            else
              const Spacer(),
            if (episodeChrome) const SizedBox(width: 12),
            if (compact ||
                widget.onRotate != null ||
                episodeChrome && !widget.fullscreen)
              _overlayIconButton(
                tooltip: '旋转与全屏',
                onPressed: () {
                  (widget.onRotate ?? widget.onFullscreen)();
                  _show();
                },
                icon: const PlayerRotationIcon(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(22),
      ),
      child: IconButton(
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 42, height: 42),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: icon,
      ),
    ),
  );

  Widget _centerPlayback(bool playing, {required bool showSkip}) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSkip) ...[
          IconButton(
            tooltip: '上一集',
            onPressed: widget.onPrevious,
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          const SizedBox(width: 12),
        ],
        IconButton.filledTonal(
          tooltip: playing ? '暂停播放' : '开始播放',
          iconSize: 38,
          style: IconButton.styleFrom(
            backgroundColor: const Color(0x40000000),
            foregroundColor: const Color(0xCCFFFFFF),
            hoverColor: const Color(0x24FFFFFF),
            highlightColor: const Color(0x30FFFFFF),
          ),
          onPressed: () {
            widget.onTogglePlayback();
            _show();
          },
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        if (showSkip) ...[
          const SizedBox(width: 12),
          IconButton(
            tooltip: '下一集',
            onPressed: widget.onNext,
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ],
    ),
  );

  Widget _sideDanmakuControl() {
    if (!widget.showDanmaku) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(right: widget.swipeEnabled ? 0 : 4),
        child: _danmakuTool(),
      ),
    );
  }

  Widget _bottomControls({
    required BoxConstraints constraints,
    required double volume,
    required double duration,
    required double position,
    required double buffered,
  }) {
    final width = constraints.maxWidth;
    final fullscreen = widget.fullscreen;
    final mobile = widget.swipeEnabled;
    final showEpisodes = fullscreen;
    final showSpeedQuality =
        mobile || fullscreen && width >= 720 || !fullscreen && width >= 560;
    final showPush =
        widget.onPush != null &&
        (mobile || fullscreen && width >= 860 || !fullscreen && width >= 680);
    final showCompare = fullscreen && width >= 820;
    final showVolume = !widget.swipeEnabled && width >= 360;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mobile)
            _mobileControlRow(
              fullscreen: fullscreen,
              compact: constraints.maxHeight < 320,
            )
          else
            _desktopControlRow(
              fullscreen: fullscreen,
              compact: constraints.maxHeight < 320,
              showEpisodes: showEpisodes,
              showSpeedQuality: showSpeedQuality,
              showPush: showPush,
              showCompare: showCompare,
              showVolume: showVolume,
              volume: volume,
            ),
          if (widget.showProgress)
            _progressRow(
              duration: duration,
              position: position,
              buffered: buffered,
            ),
        ],
      ),
    );
  }

  double _topChromeInset() {
    if (widget.fullscreen) {
      final top = MediaQuery.paddingOf(context).top;
      if (top <= 0) return 16;
      return (top + 16).clamp(40.0, 80.0);
    }
    if (widget.swipeEnabled) {
      return MediaQuery.paddingOf(context).top + 10;
    }
    if (_episodeChrome) return MediaQuery.paddingOf(context).top + 16;
    return 0;
  }

  double _bottomChromeInset() {
    if (widget.fullscreen) {
      return (MediaQuery.viewPaddingOf(context).bottom + 24).clamp(64.0, 104.0);
    }
    if (_episodeChrome && !widget.swipeEnabled) {
      return MediaQuery.viewPaddingOf(context).bottom + 16;
    }
    return 0;
  }

  Widget _progressRow({
    required double duration,
    required double position,
    required double buffered,
  }) {
    final previewPosition =
        (widget.interactions.scrubTarget?.inMilliseconds ??
            (position * 1000).round()) /
        1000;
    final canSeek =
        widget.enabled && widget.interactions.seekEnabled && duration > 0;
    final timeStyle = TextStyle(
      fontSize: 12,
      color: Colors.white.withValues(alpha: .82),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 43,
              child: Text(
                formatPosition(previewPosition),
                style: timeStyle,
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('player-progress'),
                  value: previewPosition.clamp(0, duration > 0 ? duration : 1),
                  max: duration > 0 ? duration : 1,
                  secondaryTrackValue: buffered.clamp(
                    0,
                    duration > 0 ? duration : 1,
                  ),
                  semanticFormatterCallback: formatPosition,
                  onChangeStart: canSeek
                      ? (_) {
                          widget.interactions.cancel(resumeScrub: true);
                          widget.interactions.beginScrub();
                          _hideTimer?.cancel();
                        }
                      : null,
                  onChanged: !canSeek
                      ? null
                      : (value) {
                          _hideTimer?.cancel();
                          widget.interactions.updateScrub(
                            Duration(milliseconds: (value * 1000).round()),
                          );
                        },
                  onChangeEnd: (value) {
                    if (canSeek) {
                      widget.interactions.updateScrub(
                        Duration(milliseconds: (value * 1000).round()),
                      );
                      widget.interactions.endScrub();
                    }
                  },
                ),
              ),
            ),
            SizedBox(
              width: 43,
              child: Text(formatPosition(duration), style: timeStyle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: Icon(icon, size: 22),
  );

  Widget _toolText({
    required Key key,
    required String tooltip,
    required String label,
    required VoidCallback? onPressed,
    double width = 52,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    visualWidth: width,
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    ),
  );

  Widget _toolButton({
    required Key key,
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
    double visualWidth = 36,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = selected
        ? scheme.primary
        : Colors.white.withValues(alpha: enabled ? .92 : .36);
    final background = selected
        ? scheme.primary.withValues(alpha: .20)
        : Colors.black.withValues(alpha: .22);
    final border = selected
        ? scheme.primary.withValues(alpha: .62)
        : Colors.white.withValues(alpha: .08);
    final targetWidth = visualWidth < 40 ? 48.0 : visualWidth + 8;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: targetWidth,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: visualWidth,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: border),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 22),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13.5,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolGroup(List<Widget> children) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);

  Widget _lanPushTool(Key key) {
    final link = LanController.current;
    if (link == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) => _toolButton(
        key: key,
        tooltip: link.connection == null
            ? '推送'
            : '推送到 ${link.connection!.peer.name}',
        onPressed: widget.enabled ? () => _panel(widget.onPush!) : null,
        child: link.pushing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                link.connection == null
                    ? Icons.cast_rounded
                    : Icons.cast_connected_rounded,
                size: 22,
              ),
      ),
    );
  }

  Widget _clusteredToolRow(List<Widget> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    if (tools.length <= 5) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [_toolGroup(tools)],
      );
    }
    final leftCount = tools.length ~/ 2;
    return Row(
      children: [
        _toolGroup(tools.take(leftCount).toList()),
        const Spacer(),
        _toolGroup(tools.skip(leftCount).toList()),
      ],
    );
  }

  Widget _danmakuTool() {
    final status = widget.danmakuEnabled ? '已开启' : '已关闭';
    return Builder(
      builder: (buttonContext) => Semantics(
        toggled: widget.danmakuEnabled,
        child: IconButton(
          key: const ValueKey('player-danmaku-menu'),
          tooltip: widget.danmakuStatus.isEmpty
              ? '弹幕设置 · $status'
              : '弹幕设置 · $status · ${widget.danmakuStatus}',
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          padding: EdgeInsets.zero,
          color: Colors.white,
          disabledColor: Colors.white38,
          onPressed: widget.enabled && widget.onDanmakuMenu != null
              ? () => _panel(() => widget.onDanmakuMenu!(buttonContext))
              : null,
          icon: PlayerDanmakuIcon(enabled: widget.danmakuEnabled),
        ),
      ),
    );
  }

  Widget _sleepTimerTool() => _toolIcon(
    key: const ValueKey('player-sleep-timer'),
    tooltip: widget.sleepTimerLabel.isEmpty
        ? '睡眠定时'
        : '睡眠定时 · ${widget.sleepTimerLabel}',
    icon: Icons.bedtime_outlined,
    onPressed: () => _panel(widget.onSleepTimer!),
  );

  Widget _catchupTool() => _toolIcon(
    key: const ValueKey('player-live-catchup'),
    tooltip: widget.catchupActive ? '回到直播' : '7 天回看',
    icon: widget.catchupActive ? Icons.live_tv_rounded : Icons.replay_rounded,
    onPressed: widget.enabled ? () => _panel(widget.onCatchup!) : null,
  );

  double get _qualityToolWidth => widget.qualityLabel.contains('×') ? 96 : 52;

  Widget _desktopControlRow({
    required bool fullscreen,
    required bool compact,
    required bool showEpisodes,
    required bool showSpeedQuality,
    required bool showPush,
    required bool showCompare,
    required bool showVolume,
    required double volume,
  }) {
    final tools = [
      if (widget.onSleepTimer != null) _sleepTimerTool(),
      if (widget.onCatchup != null) _catchupTool(),
      if (showSpeedQuality) ...[
        _toolText(
          key: const ValueKey('player-speed'),
          tooltip: '倍速',
          label: '${widget.speed}x',
          onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
          width: 50,
        ),
        _toolText(
          key: const ValueKey('player-quality'),
          tooltip: '清晰度',
          label: widget.qualityLabel,
          onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
          width: _qualityToolWidth,
        ),
      ],
      if (showPush) _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (showEpisodes)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (showCompare) _enhancementCompareButton(),
      if (showVolume)
        _toolIcon(
          key: const ValueKey('player-volume'),
          tooltip: '音量',
          icon: volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          onPressed: widget.enabled
              ? () => _panel(() => _openVolume(volume))
              : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
      _toolButton(
        key: const ValueKey('player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '旋转与全屏',
        child: fullscreen
            ? const Icon(Icons.fullscreen_exit_rounded, size: 22)
            : const PlayerRotationIcon(),
        onPressed: widget.onFullscreen,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: _episodeToolRow(
        tools,
        compact: compact,
        toolsWidth:
            (showSpeedQuality ? 66 + _qualityToolWidth : 0) +
            48.0 *
                ((widget.onSleepTimer != null ? 1 : 0) +
                    (widget.onCatchup != null ? 1 : 0) +
                    (showPush && LanController.current != null ? 1 : 0) +
                    (showEpisodes ? 1 : 0) +
                    (showCompare && widget.enhancement?.canCompare == true
                        ? 1
                        : 0) +
                    (showVolume ? 1 : 0) +
                    (widget.onPictureInPicture != null ? 1 : 0) +
                    1),
      ),
    );
  }

  Widget _mobileControlRow({required bool fullscreen, required bool compact}) {
    final tools = [
      if (widget.onSleepTimer != null) _sleepTimerTool(),
      if (widget.onCatchup != null) _catchupTool(),
      _toolText(
        key: const ValueKey('player-speed'),
        tooltip: '倍速',
        label: '${widget.speed}x',
        onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
        width: 50,
      ),
      _toolText(
        key: const ValueKey('player-quality'),
        tooltip: '清晰度',
        label: widget.qualityLabel,
        onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
        width: _qualityToolWidth,
      ),
      if (widget.onPush != null)
        _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (fullscreen)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: _episodeToolRow(
        tools,
        compact: compact,
        toolsWidth:
            66 +
            _qualityToolWidth +
            48.0 *
                ((widget.onSleepTimer != null ? 1 : 0) +
                    (widget.onCatchup != null ? 1 : 0) +
                    (widget.onPush != null && LanController.current != null
                        ? 1
                        : 0) +
                    (fullscreen ? 1 : 0) +
                    (widget.onPictureInPicture != null ? 1 : 0)),
      ),
    );
  }

  Widget _episodeToolRow(
    List<Widget> tools, {
    required double toolsWidth,
    required bool compact,
  }) {
    if (!_episodeChrome ||
        widget.episodeNumber == null ||
        widget.episodeCount == null) {
      return _clusteredToolRow(tools);
    }
    if (compact) {
      return Row(
        children: [
          SizedBox(width: 80, child: _episodeCounter()),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _toolGroup(tools),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final counterWidth = constraints.maxWidth - toolsWidth - 8;
        if (tools.length <= 5 && counterWidth >= 80) {
          return Row(
            children: [
              SizedBox(width: counterWidth, child: _episodeCounter()),
              const SizedBox(width: 8),
              _toolGroup(tools),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _episodeCounter(),
            ),
            if (toolsWidth > constraints.maxWidth)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _toolGroup(tools),
              )
            else
              _clusteredToolRow(tools),
          ],
        );
      },
    );
  }

  Widget _episodeCounter() => PlayerEpisodeCounter(
    key: const ValueKey('player-episode-counter'),
    number: widget.episodeNumber!,
    count: widget.episodeCount!,
  );

  Future<void> _openVolume(double initialVolume) async {
    var volume = initialVolume.clamp(0.0, 100.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setState) => SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: widget.swipeEnabled ? 12 : 20,
                    bottom: widget.fullscreen ? 88 : 74,
                  ),
                  child: Material(
                    color: Colors.black.withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 62,
                      height: 192,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: volume == 0 ? '恢复音量' : '静音',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              final next = volume == 0 ? 100.0 : 0.0;
                              setState(() => volume = next);
                              unawaited(widget.player.setVolume(next));
                            },
                            icon: Icon(
                              volume == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  value: volume,
                                  max: 100,
                                  divisions: 20,
                                  onChanged: (value) {
                                    setState(() => volume = value);
                                    unawaited(widget.player.setVolume(value));
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: Center(
                              child: Text(
                                '${volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(.04, .08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
              child: child,
            ),
          ),
    );
  }

  Widget _enhancementCompareButton() {
    final enhancement = widget.enhancement;
    if (enhancement == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: enhancement,
      builder: (_, _) {
        if (!enhancement.canCompare) return const SizedBox.shrink();
        return _toolIcon(
          key: const ValueKey('player-enhancement-compare'),
          tooltip: enhancement.comparing ? '原画对比中，点击恢复增强' : '原画对比',
          icon: Icons.compare_rounded,
          onPressed: widget.enabled
              ? () {
                  widget.interactions.cancel();
                  unawaited(enhancement.toggleCompare());
                  _show();
                }
              : null,
          selected: enhancement.comparing,
        );
      },
    );
  }

  Widget _gestureFeedback() =>
      PlayerFeedbackOverlay(feedback: widget.interactions.feedback);
}
