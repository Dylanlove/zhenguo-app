import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'danmaku_controller.dart';
import 'danmaku_models.dart';
import 'danmaku_preferences.dart';

class DanmakuFlight {
  const DanmakuFlight(
    this.item,
    this.text,
    this.lane,
    this.width, {
    required this.startMs,
    required this.durationMs,
  });
  final DanmakuItem item;
  final String text;
  final int lane;
  final double width;
  final int startMs;
  final int durationMs;
  int get endMs => startMs + durationMs;
  double x(double viewport, double time) => item.mode == DanmakuMode.scroll
      ? viewport - (viewport + width) * ((time - startMs) / durationMs)
      : (viewport - width) / 2;
}

List<DanmakuFlight> planDanmaku(
  List<DanmakuItem> items, {
  required double width,
  required int rows,
  required double Function(String) measure,
  int? scrollingRows,
  DanmakuPreferences preferences = const DanmakuPreferences(),
  List<DanmakuFlight> previous = const [],
}) {
  if (!width.isFinite || width < 24 || rows < 1) return const [];
  final count = rows.clamp(1, 128),
      scrollCount = (scrollingRows ?? rows).clamp(0, rows.clamp(1, 128));
  final lanes = List<DanmakuFlight?>.filled(count, null);
  final flights = <DanmakuFlight>[...previous];
  final active = <DanmakuFlight>[...previous];
  final seen = previous.map((flight) => flight.item.id).toSet();
  for (final flight in previous) {
    if (flight.lane < count) lanes[flight.lane] = flight;
  }
  final sorted = items.toList()..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final gap = switch (preferences.density) {
    DanmakuDensity.low => 64.0,
    DanmakuDensity.medium => 36.0,
    DanmakuDensity.high => 22.0,
  };
  final capacity = math.max(
    1,
    math.max(1, scrollCount) * (preferences.density.index + 1),
  );
  final blocked = preferences.keywords
      .map((word) => word.toLowerCase())
      .toList();
  final widths = <String, double>{};
  double measured(String text) =>
      widths.putIfAbsent(text, () => measure(text).ceilToDouble() + 6);
  for (final item in sorted) {
    if (item.id.isEmpty ||
        item.timeMs < 0 ||
        item.text.trim().isEmpty ||
        !seen.add(item.id))
      continue;
    if ((item.mode == DanmakuMode.scroll && !preferences.scroll) ||
        (item.mode == DanmakuMode.top && !preferences.top) ||
        (item.mode == DanmakuMode.bottom && !preferences.bottom) ||
        blocked.any((word) => item.text.toLowerCase().contains(word)))
      continue;
    final start = item.timeMs + (preferences.offsetSeconds * 1000).round();
    final duration = item.mode == DanmakuMode.scroll
        ? preferences.lifetimeMs
        : 4000;
    if (start + duration <= 0) continue;
    active.removeWhere((flight) => flight.endMs <= start);
    if (active.length >= capacity) continue;
    final candidates = item.mode == DanmakuMode.bottom
        ? List.generate(
            math.max(1, math.min(count, math.max(1, scrollCount ~/ 3))),
            (i) => count - i - 1,
          )
        : List.generate(scrollCount, (i) => i);
    if (!candidates.any(
      (lane) =>
          lanes[lane] == null ||
          lanes[lane]!.endMs <= start ||
          (item.mode == DanmakuMode.scroll &&
              lanes[lane]!.item.mode == DanmakuMode.scroll &&
              (width + lanes[lane]!.width) *
                          (start - lanes[lane]!.startMs) /
                          lanes[lane]!.durationMs -
                      lanes[lane]!.width >=
                  gap),
    ))
      continue;
    final characters = item.text.characters.take(64).toList();
    var text =
        characters.join() + (item.text.characters.length > 64 ? '…' : '');
    final maxWidth = math.max(12.0, width - 16);
    var size = measured(text);
    if (size > maxWidth) {
      var low = 0, high = characters.length;
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (measured('${characters.take(middle).join()}…') <= maxWidth) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      if (low == 0) continue;
      text = '${characters.take(low).join()}…';
      size = measured(text);
    }
    if (!size.isFinite || size <= 0) continue;
    final lane = candidates.where((lane) {
      final previous = lanes[lane];
      if (previous == null || previous.endMs <= start) return true;
      if (item.mode != DanmakuMode.scroll ||
          previous.item.mode != DanmakuMode.scroll)
        return false;
      final elapsed = start - previous.startMs;
      final previousSpeed = (width + previous.width) / previous.durationMs;
      final nextSpeed = (width + size) / duration;
      return previousSpeed * elapsed - previous.width >= gap &&
          width - nextSpeed * (previous.endMs - start) >= gap;
    }).firstOrNull;
    if (lane == null) continue;
    final flight = DanmakuFlight(
      item,
      text,
      lane,
      size,
      startMs: start,
      durationMs: duration,
    );
    lanes[lane] = flight;
    active.add(flight);
    flights.add(flight);
  }
  return flights;
}

Rect danmakuVideoRect(Size viewport, double aspectRatio) {
  final aspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
  final width = math.min(viewport.width, viewport.height * aspect);
  final height = math.min(viewport.height, viewport.width / aspect);
  return Rect.fromLTWH(
    (viewport.width - width) / 2,
    (viewport.height - height) / 2,
    width,
    height,
  );
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.television = false,
  });
  final DanmakuController controller;
  final double aspectRatio;
  final bool television;
  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  final _paint = ValueNotifier<int>(0);
  _DanmakuTextCache? _text;
  Object? _layout;
  List<DanmakuFlight> _schedule = const [];
  int _cursor = 0, _plannedUntil = -1;
  double _lastTime = -1, _width = 0, _rowHeight = 0, _top = 0;
  int _rows = 0, _scrollRows = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _layout = null;
    }
  }

  void _changed() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  void _syncTicker() {
    if (widget.controller.moving) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  int _lowerBound(int time) {
    final items = widget.controller.items;
    var low = 0, high = items.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (items[mid].timeMs < time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _resetSchedule(double time) {
    final settings = widget.controller.preferences;
    _schedule = const [];
    _cursor = _lowerBound(
      (time -
              math.max(settings.lifetimeMs, 4000) -
              settings.offsetSeconds * 1000)
          .floor(),
    );
    _plannedUntil = time.floor() - 1;
    _lastTime = time;
  }

  void _extend(double time) {
    if (_text == null || _rows == 0) return;
    final controller = widget.controller, settings = controller.preferences;
    final horizon = time.floor() + 12000;
    final end = math.min(
      _lowerBound(horizon - (settings.offsetSeconds * 1000).round()),
      _cursor + 600,
    );
    _schedule = planDanmaku(
      controller.items.sublist(_cursor, end),
      width: _width,
      rows: _rows,
      scrollingRows: _scrollRows,
      preferences: settings,
      measure: _text!.measure,
      previous: _schedule.where((flight) => flight.endMs > time - 250).toList(),
    );
    _cursor = end;
    _plannedUntil =
        end < controller.items.length &&
            controller.items[end].timeMs + settings.offsetSeconds * 1000 <
                horizon
        ? (controller.items[end].timeMs + settings.offsetSeconds * 1000).floor()
        : horizon;
    if (!controller.moving && _plannedUntil < time + 4000) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.visible) {
          _extend(widget.controller.timelinePositionMs);
          _paint.value++;
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  void _tick() {
    if (!mounted || !widget.controller.visible) return;
    final time = widget.controller.timelinePositionMs;
    if (time < _lastTime - 250 || (time - _lastTime).abs() > 2000)
      _resetSchedule(time);
    if (time + 4000 >= _plannedUntil) _extend(time);
    _lastTime = time;
    _paint.value++;
  }

  @override
  Widget build(BuildContext context) {
    _syncTicker();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                constraints.maxWidth <= 0 ||
                constraints.maxHeight <= 0)
              return const SizedBox.shrink();
            final controller = widget.controller;
            if (!controller.visible) return const SizedBox.shrink();
            final viewport = constraints.biggest;
            final rect = danmakuVideoRect(viewport, widget.aspectRatio);
            final settings = controller.preferences;
            final scaler = MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: 1.6);
            final safe = MediaQuery.paddingOf(context);
            final top = math.max(8.0, safe.top - rect.top + 4);
            final bottom = math.max(
              settings.subtitleSafe ? rect.height * .12 : 8.0,
              safe.bottom - (viewport.height - rect.bottom) + 4,
            );
            final fontSize = settings.fontSize * (widget.television ? 1.35 : 1);
            final fontFamily = Theme.of(
              context,
            ).textTheme.bodyMedium?.fontFamily;
            final key = (
              controller,
              controller.dataRevision,
              rect.size,
              top,
              bottom,
              fontSize,
              fontFamily,
              scaler,
              settings,
            );
            final time = controller.timelinePositionMs;
            if (_layout != key) {
              _layout = key;
              _text?.dispose();
              _text = _DanmakuTextCache(fontSize, scaler, settings, fontFamily);
              _width = rect.width;
              _rowHeight = math.max(
                scaler.scale(fontSize) * 1.45,
                _text!.height + 8,
              );
              _top = top;
              _rows = ((rect.height - top - bottom) / _rowHeight).floor().clamp(
                0,
                128,
              );
              _scrollRows = ((rect.height * settings.area - top) / _rowHeight)
                  .floor()
                  .clamp(0, _rows);
              _resetSchedule(time);
              _extend(time);
            } else if ((time - _lastTime).abs() > 500 || time < _lastTime) {
              _resetSchedule(time);
              _extend(time);
            }
            _lastTime = time;
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: ClipRect(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('danmaku-canvas'),
                        painter: _DanmakuPainter(
                          repaint: _paint,
                          controller: controller,
                          flights: () => _schedule,
                          text: _text!,
                          rowHeight: _rowHeight,
                          top: _top,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _ticker.dispose();
    _paint.dispose();
    _text?.dispose();
    super.dispose();
  }
}

class _DanmakuTextCache {
  _DanmakuTextCache(this.fontSize, this.scaler, this.settings, this.fontFamily);
  final double fontSize;
  final TextScaler scaler;
  final DanmakuPreferences settings;
  final String? fontFamily;
  final _cache = <(String, int), (TextPainter, TextPainter?)>{};
  TextStyle get style => TextStyle(
    fontSize: fontSize,
    fontFamily: fontFamily,
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Noto Color Emoji',
    ],
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  double get height => _obtain('弹幕 Aa 👨‍👩‍👧‍👦', 0xffffff).$1.height;
  double measure(String value) => _obtain(value, 0xffffff).$1.width;
  (TextPainter, TextPainter?) _obtain(String value, int color) {
    final key = (value, color);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    TextPainter make(TextStyle textStyle) => TextPainter(
      text: TextSpan(text: value, style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final fill = make(
      style.copyWith(
        color: Color(0xff000000 | color).withValues(alpha: settings.opacity),
        shadows: settings.shadow
            ? [
                Shadow(
                  color: Colors.black.withValues(alpha: settings.opacity * .7),
                  blurRadius: 1.5,
                  offset: const Offset(.6, .8),
                ),
              ]
            : null,
      ),
    );
    final stroke = settings.outline
        ? make(
            style.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2
                ..strokeJoin = StrokeJoin.round
                ..color = Colors.black.withValues(
                  alpha: settings.opacity * .85,
                ),
            ),
          )
        : null;
    _cache[key] = (fill, stroke);
    while (_cache.length > 768) {
      final old = _cache.remove(_cache.keys.first)!;
      old.$1.dispose();
      old.$2?.dispose();
    }
    return (fill, stroke);
  }

  void paint(Canvas canvas, DanmakuFlight flight, Offset offset) {
    final color = settings.blockColored
        ? 0xffffff
        : settings.useOriginalColor
        ? flight.item.color
        : settings.color;
    final painters = _obtain(flight.text, color);
    painters.$2?.paint(canvas, offset);
    painters.$1.paint(canvas, offset);
  }

  void dispose() {
    for (final entry in _cache.values) {
      entry.$1.dispose();
      entry.$2?.dispose();
    }
    _cache.clear();
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required Listenable repaint,
    required this.controller,
    required this.flights,
    required this.text,
    required this.rowHeight,
    required this.top,
  }) : super(repaint: repaint);
  final DanmakuController controller;
  final List<DanmakuFlight> Function() flights;
  final _DanmakuTextCache text;
  final double rowHeight;
  final double top;
  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.visible) return;
    final time = controller.timelinePositionMs;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final flight in flights()) {
      if (time < flight.startMs || time >= flight.endMs) continue;
      text.paint(
        canvas,
        flight,
        Offset(flight.x(size.width, time) + 3, top + flight.lane * rowHeight),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) => true;
}
