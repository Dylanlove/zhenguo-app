import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app_layout.dart';
import 'playback_preferences.dart';
import 'player_feedback.dart';
import 'widgets.dart';

enum SwipeAction { none, seek, episode }

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.holdSpeed,
    required this.swipeSeek,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.onSeek,
    this.seekEnabled = true,
  }) {
    feedback.addListener(notifyListeners);
    _playing = player.stream.playing.listen((playing) {
      if (!playing && !_scrubbing) cancel();
    });
    if (AppDevice.supportsMediaVolume) {
      _mediaVolumeSubscription = AppDevice.mediaVolumeChanges.listen(
        _systemVolumeChanged,
        onError: (Object error) => _volumeFailed(error, feedback: false),
      );
      unawaited(
        AppDevice.getMediaVolume()
            .then<void>((value) {
              if (!_disposed) _systemVolumeChanged(value);
            })
            .catchError(
              (Object error) => _volumeFailed(error, feedback: false),
            ),
      );
    }
  }

  final Player player;
  final bool Function() available;
  final double Function() baseSpeed;
  final double Function() holdSpeed;
  final int Function() swipeSeek;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final Future<void> Function(Duration)? onSeek;
  bool seekEnabled;
  final feedback = PlayerFeedbackController();
  late final StreamSubscription<bool> _playing;
  StreamSubscription<double>? _mediaVolumeSubscription;
  double? _systemVolume;
  double? _pendingSystemVolume;
  bool _changingSystemVolume = false;
  Timer? _holdTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  bool _swipeEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  DateTime _ignoreTapUntil = DateTime(2000);
  SwipeAction _swipeAction = SwipeAction.none;
  bool _episodeFired = false;
  double _viewWidth = 0.0;
  double _viewHeight = 0.0;
  Timer? _previewTimer;
  Future<void> _scrubOperations = Future<void>.value();
  int _scrubSequence = 0;
  bool _scrubbing = false;
  bool _scrubEnding = false;
  bool _previewQueued = false;
  bool _resumeAfterScrub = false;
  Duration _scrubStart = Duration.zero;
  Duration? _scrubTarget;

  bool get scrubbing => _scrubbing;
  Duration? get scrubTarget => _scrubTarget;
  bool get operating =>
      _boosting || _scrubbing || _swipeAction != SwipeAction.none;

  bool get boosting => _boosting;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void _systemVolumeChanged(double value) {
    if (_disposed) return;
    _systemVolume = value * 100;
    if (value > 0) _unmutedVolume = _systemVolume!;
  }

  void _volumeFailed(Object error, {bool feedback = true}) {
    if (_disposed) return;
    if (feedback) {
      hint('系统音量调节失败，请使用音量键重试');
    }
  }

  void _setVolume(double volume) {
    if (_disposed || !available()) return;
    if (AppDevice.supportsMediaVolume) {
      _pendingSystemVolume = volume;
      if (!_changingSystemVolume) unawaited(_flushSystemVolume());
      return;
    }
    unawaited(player.setVolume(volume));
    if (volume > 0) _unmutedVolume = volume;
  }

  Future<void> _flushSystemVolume() async {
    _changingSystemVolume = true;
    try {
      if (player.state.volume != 100) await player.setVolume(100);
      while (!_disposed && available() && _pendingSystemVolume != null) {
        final volume = _pendingSystemVolume!;
        _pendingSystemVolume = null;
        await AppDevice.setMediaVolume(volume / 100);
      }
    } catch (error) {
      _volumeFailed(error);
    } finally {
      _pendingSystemVolume = null;
      _changingSystemVolume = false;
    }
  }

  void hint(String message, {IconData icon = Icons.info_outline_rounded}) {
    if (_disposed) return;
    feedback.show(message, icon: icon);
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!seekEnabled && holdSpeed() == 1) return;
    if (!available() || _scrubbing || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      unawaited(_setRate(holdSpeed()));
      hint('${speedLabel(holdSpeed())} X', icon: Icons.fast_forward_rounded);
    });
  }

  void _endHold({bool tap = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      feedback.clear();
      notifyListeners();
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel({bool resumeScrub = false}) {
    if (_disposed) return;
    _pendingSystemVolume = null;
    final resume = resumeScrub && _scrubbing && _resumeAfterScrub;
    _previewTimer?.cancel();
    _previewTimer = null;
    final ticket = ++_scrubSequence;
    _scrubbing = resume;
    _scrubEnding = resume;
    _scrubTarget = null;
    _previewQueued = false;
    if (resume) {
      _scrubOperations = _scrubOperations
          .catchError((Object _) {})
          .then((_) async {
            if (_disposed || ticket != _scrubSequence) return;
            try {
              if (available()) await player.play();
            } finally {
              if (!_disposed && ticket == _scrubSequence) {
                _scrubbing = _scrubEnding = false;
                notifyListeners();
              }
            }
          })
          .catchError((Object _) {});
    }
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _swipeAction = SwipeAction.none;
    _endHold();
    feedback.clear();
    notifyListeners();
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    double width = 0.0,
    required double height,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel(resumeScrub: true);
      return;
    }
    if (!available() || _scrubbing || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _viewWidth = width;
    _viewHeight = height;
    _moved = _held = false;
    _swipeAction = SwipeAction.none;
    _episodeFired = false;
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final diff = event.localPosition - _origin!;
    if (diff.distance > 12) {
      _moved = true;
      _endHold();
    }
    if (!_swipeEnabled ||
        !_moved ||
        _held ||
        _viewHeight <= 0 ||
        _viewWidth <= 0) {
      return;
    }

    if (_swipeAction == SwipeAction.none) {
      if (diff.dx.abs() > diff.dy.abs() * 1.5) {
        if (!seekEnabled || player.state.duration <= Duration.zero) return;
        _swipeAction = SwipeAction.seek;
        beginScrub();
      } else if (diff.dy.abs() > diff.dx.abs() * 1.5) {
        _swipeAction = SwipeAction.episode;
      } else {
        return;
      }
    }

    if (_swipeAction == SwipeAction.seek) {
      final span = math.min(
        swipeSeek() * 1000,
        player.state.duration.inMilliseconds,
      );
      updateScrub(
        Duration(
          milliseconds:
              _scrubStart.inMilliseconds +
              (diff.dx / _viewWidth * span).round(),
        ),
      );
      return;
    }

    if (_swipeAction == SwipeAction.episode) {
      final dy = _origin!.dy - event.localPosition.dy;
      if (!_episodeFired && dy.abs() > 40) {
        _episodeFired = true;
        hint(
          onEpisode(dy > 0 ? 1 : -1),
          icon: dy > 0 ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
        );
      }
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    if (_swipeAction == SwipeAction.seek) {
      endScrub();
    }

    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _swipeAction = SwipeAction.none;
    _endHold();
    notifyListeners();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel(resumeScrub: true);
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void doubleTap(double x, double width, {required bool mobile}) {
    if (!available() || suppressTap || _scrubbing) return;
    if (mobile && width > 0 && x < width / 3) {
      seek(-10);
    } else if (mobile && width > 0 && x > width * 2 / 3) {
      seek(10);
    } else {
      onTogglePlayback();
    }
  }

  void beginScrub() {
    if (_disposed ||
        _scrubbing ||
        !seekEnabled ||
        !available() ||
        player.state.duration <= Duration.zero) {
      return;
    }
    _endHold();
    _scrubbing = true;
    _scrubEnding = false;
    _previewQueued = false;
    _resumeAfterScrub = player.state.playing;
    _scrubTarget = _scrubStart = player.state.position;
    _updateScrubFeedback(begin: true);
    final ticket = ++_scrubSequence;
    _scrubOperations = _scrubOperations
        .catchError((Object _) {})
        .then((_) async {
          if (!_disposed && ticket == _scrubSequence && available()) {
            await player.pause();
          }
        })
        .catchError((Object _) {
          if (!_disposed && ticket == _scrubSequence) {
            cancel();
            hint('进度预览失败，请重试');
          }
        });
    notifyListeners();
  }

  void updateScrub(Duration target) {
    if (_disposed || !_scrubbing || _scrubEnding) return;
    _scrubTarget = Duration(
      milliseconds: target.inMilliseconds.clamp(
        0,
        player.state.duration.inMilliseconds,
      ),
    );
    _updateScrubFeedback();
    notifyListeners();
    _previewTimer ??= Timer(const Duration(milliseconds: 120), () {
      _previewTimer = null;
      if (_previewQueued || !_scrubbing || _scrubEnding) return;
      _previewQueued = true;
      final ticket = _scrubSequence;
      _scrubOperations = _scrubOperations
          .catchError((Object _) {})
          .then((_) async {
            if (_disposed || ticket != _scrubSequence) return;
            _previewQueued = false;
            final target = _scrubTarget;
            if (!_scrubEnding && available() && target != null) {
              await (onSeek ?? player.seek)(target);
            }
          })
          .catchError((Object _) {
            if (!_disposed && ticket == _scrubSequence) hint('预览暂不可用，松开后跳转');
          });
    });
  }

  void _updateScrubFeedback({bool begin = false}) {
    final target = _scrubTarget;
    if (target == null) return;
    final icon = target < _scrubStart
        ? Icons.fast_rewind_rounded
        : Icons.fast_forward_rounded;
    final message =
        '${formatPosition(target.inMilliseconds / 1000)} / ${formatPosition(player.state.duration.inMilliseconds / 1000)}';
    if (begin) {
      feedback.show(message, icon: icon);
    } else {
      feedback.update(message, icon: icon);
    }
  }

  void endScrub() {
    if (_disposed || !_scrubbing || _scrubEnding) return;
    _previewTimer?.cancel();
    _previewTimer = null;
    _scrubEnding = true;
    final ticket = _scrubSequence;
    final target = _scrubTarget;
    _scrubOperations = _scrubOperations.catchError((Object _) {}).then((
      _,
    ) async {
      if (_disposed || ticket != _scrubSequence) return;
      try {
        if (!available()) return;
        if (target != null) await (onSeek ?? player.seek)(target);
        if (!_disposed &&
            ticket == _scrubSequence &&
            available() &&
            _resumeAfterScrub) {
          await player.play();
        }
      } catch (_) {
        if (!_disposed && ticket == _scrubSequence) hint('跳转失败，请重试');
      } finally {
        if (!_disposed && ticket == _scrubSequence) {
          _scrubbing = _scrubEnding = false;
          _scrubTarget = null;
          notifyListeners();
        }
      }
    });
  }

  void seek(int seconds, {bool repeat = false}) {
    if (!available() ||
        !seekEnabled ||
        _scrubbing ||
        player.state.duration <= Duration.zero) {
      return;
    }
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    final message = '${seconds > 0 ? '前进' : '后退'} ${seconds.abs()} 秒';
    final icon = seconds > 0
        ? Icons.fast_forward_rounded
        : Icons.fast_rewind_rounded;
    if (repeat) {
      feedback.update(message, icon: icon);
    } else {
      hint(message, icon: icon);
    }
  }

  void changeVolume(double delta, {bool repeat = false}) {
    if (!available()) return;
    if (AppDevice.supportsMediaVolume) {
      unawaited(_changeSystemVolume(delta: delta, repeat: repeat));
      return;
    }
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    _setVolume(volume);
  }

  void toggleMute() {
    if (!available()) return;
    if (AppDevice.supportsMediaVolume) {
      unawaited(_changeSystemVolume(mute: true));
      return;
    }
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _setVolume(target);
  }

  Future<void> _changeSystemVolume({
    double delta = 0,
    bool mute = false,
    bool repeat = false,
  }) async {
    try {
      final current = await AppDevice.getMediaVolume();
      if (_disposed || !available()) return;
      _systemVolumeChanged(current);
      final volume = current * 100;
      final target = mute
          ? volume > 0
                ? 0.0
                : _unmutedVolume
          : (volume + delta).clamp(0.0, 100.0);
      _setVolume(target);
    } catch (error) {
      _volumeFailed(error);
    }
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5, repeat: event is KeyRepeatEvent);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5, repeat: event is KeyRepeatEvent);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5, repeat: event is KeyRepeatEvent);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingSystemVolume = null;
    _mediaVolumeSubscription?.cancel();
    _holdTimer?.cancel();
    feedback.removeListener(notifyListeners);
    feedback.dispose();
    _previewTimer?.cancel();
    _scrubSequence++;
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
