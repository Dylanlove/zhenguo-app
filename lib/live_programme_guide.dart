import 'dart:async';

import 'package:flutter/material.dart';

import 'app_notice.dart';
import 'live_epg.dart';
import 'live_models.dart';
import 'live_playback.dart';
import 'remote_widgets.dart';

class LiveProgrammeGuide extends StatefulWidget {
  const LiveProgrammeGuide({
    super.key,
    required this.playback,
    required this.onManualTime,
    this.onClose,
    this.now,
  });

  final LivePlaybackController playback;
  final Future<void> Function() onManualTime;
  final VoidCallback? onClose;
  final DateTime Function()? now;

  @override
  State<LiveProgrammeGuide> createState() => _LiveProgrammeGuideState();
}

class _LiveProgrammeGuideState extends State<LiveProgrammeGuide> {
  final _dates = ScrollController();
  final _scroll = ScrollController();
  late DateTime _date;
  late DateTime _now;
  Timer? _timer;
  LiveEpgSchedule? _schedule;
  String? _channelKey;
  String? _error;
  DateTime? _playingStart;
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;

  LivePlaybackController get _playback => widget.playback;

  @override
  void initState() {
    super.initState();
    _now = widget.now?.call() ?? DateTime.now();
    _date = liveEpgDate(_playback.catchupStart ?? _now);
    _channelKey = _playback.channel?.key;
    _playingStart = _playback.catchupStart;
    _playback.addListener(_playbackChanged);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() => _now = widget.now?.call() ?? DateTime.now());
      }
    });
    unawaited(_load());
    _showSelectedDate();
  }

  @override
  void didUpdateWidget(covariant LiveProgrammeGuide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != _playback) {
      oldWidget.playback.removeListener(_playbackChanged);
      _playback.addListener(_playbackChanged);
      _playbackChanged();
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _playback.removeListener(_playbackChanged);
    _dates.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _showSelectedDate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_dates.hasClients) return;
      final today = liveEpgDate(_now);
      final index = _date
          .difference(today.subtract(const Duration(days: 7)))
          .inDays;
      _dates.jumpTo(
        (index * 58.0 - 116).clamp(0.0, _dates.position.maxScrollExtent),
      );
    });
  }

  void _playbackChanged() {
    if (!mounted) return;
    if (_channelKey != _playback.channel?.key) {
      _channelKey = _playback.channel?.key;
      _date = liveEpgDate(_playback.catchupStart ?? _now);
      _schedule = null;
      unawaited(_load());
      _showSelectedDate();
      return;
    }
    setState(() {});
    if (_playingStart != _playback.catchupStart) {
      _playingStart = _playback.catchupStart;
      final start = _playingStart;
      if (start != null && liveEpgDate(start) != _date) {
        _date = liveEpgDate(start);
        _schedule = null;
        unawaited(_load());
        _showSelectedDate();
        return;
      }
      _showRelevantProgramme();
    }
  }

  Future<void> _load({bool force = false}) async {
    final channel = _playback.channel;
    if (channel == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final schedule = await _playback.repository.epg.programmes(
        channel,
        _date,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _schedule = schedule;
        _loading = false;
      });
      _showRelevantProgramme();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  double _rowHeight(BuildContext context) =>
      88 *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
        1.0,
        double.infinity,
      );

  void _showRelevantProgramme() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final items = _schedule?.items ?? const <LiveProgramme>[];
      var index = items.indexWhere(_isPlaying);
      if (index < 0 && liveEpgDate(_now) == _date) {
        index = items.indexWhere(
          (item) =>
              item.stateAt(_now, supportsCatchup: _playback.supportsCatchup) ==
              LiveProgrammeState.live,
        );
      }
      _scroll.jumpTo(
        ((index < 0 ? 0 : index) * _rowHeight(context)).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  bool _isPlaying(LiveProgramme item) =>
      _playback.catchup &&
      _playback.error == null &&
      item.start.isAtSameMomentAs(_playback.catchupStart!) &&
      item.end != null &&
      _playback.catchupEnd != null &&
      item.end!.isAtSameMomentAs(_playback.catchupEnd!);

  Future<void> _play(LiveProgramme? programme) async {
    if (_busy || _playback.loading) return;
    setState(() => _busy = true);
    try {
      if (programme == null) {
        await _playback.returnToLive();
      } else {
        final now = widget.now?.call() ?? DateTime.now();
        if (programme.stateAt(
              now,
              supportsCatchup: _playback.supportsCatchup,
            ) !=
            LiveProgrammeState.replay) {
          setState(() => _now = now);
          return;
        }
        await _playback.playCatchup(
          programme.start,
          programme.end!,
          programme: programme,
        );
      }
    } catch (error) {
      if (mounted) AppNotice.show(context, '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _range(LiveProgramme item) {
    final end = item.end;
    if (end == null) return '${liveEpgClock(item.start)} · 结束时间待更新';
    final nextDay = liveEpgDate(end) != liveEpgDate(item.start) ? '次日 ' : '';
    final minutes = item.duration!.inSeconds / 60;
    final length = minutes < 1 ? '不足 1 分钟' : '${minutes.ceil()} 分钟';
    final day = liveEpgTime(item.start);
    final prefix = liveEpgDate(item.start) != _date
        ? '${day.month}/${day.day} '
        : '';
    return '$prefix${liveEpgClock(item.start)}–$nextDay${liveEpgClock(end)} · $length';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channel = _playback.channel;
    final today = liveEpgDate(_now);
    final items = _schedule?.items ?? const <LiveProgramme>[];
    return Column(
      key: const ValueKey('live-programme-guide'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              if (widget.onClose != null)
                IconButton(
                  tooltip: '返回频道',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  '${channel?.name ?? '央视频'} · 节目单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (_playback.supportsCatchup)
                TextButton(
                  onPressed: _busy ? null : widget.onManualTime,
                  child: const Text('手动选时'),
                ),
            ],
          ),
        ),
        SingleChildScrollView(
          controller: _dates,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              for (var index = 7; index >= 0; index--) ...[
                if (index != 7) const SizedBox(width: 6),
                Builder(
                  builder: (context) {
                    final date = today.subtract(Duration(days: index));
                    final label = index == 0
                        ? '今天'
                        : '周${'一二三四五六日'[date.weekday - 1]}';
                    return ChoiceChip(
                      key: ValueKey('live-epg-date-${date.toIso8601String()}'),
                      showCheckmark: false,
                      selected: date == _date,
                      label: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [Text('${date.day}'), Text(label)],
                      ),
                      onSelected: (_) {
                        if (date == _date) return;
                        setState(() {
                          _date = date;
                          _schedule = null;
                        });
                        unawaited(_load());
                      },
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_date.month} 月 ${_date.day} 日 · 北京时间'
                  '${_schedule?.stale == true ? ' · 缓存' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: '刷新节目单',
                onPressed: _loading
                    ? null
                    : () => unawaited(_load(force: true)),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading && _schedule == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty || _error != null
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      _error ?? '当天暂无节目单，可以刷新或手动选择回看时间。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () => unawaited(_load(force: true)),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                        if (_playback.supportsCatchup)
                          TextButton(
                            onPressed: widget.onManualTime,
                            child: const Text('手动选时'),
                          ),
                      ],
                    ),
                  ],
                )
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowHeight(context),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _programme(context, items[index]),
                ),
        ),
        if (_playback.catchup)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '正在回看：${_playback.catchupProgramme?.title ?? liveEpgClock(_playback.catchupStart!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy || _playback.loading
                      ? null
                      : () => unawaited(_play(null)),
                  icon: const Icon(Icons.live_tv, size: 18),
                  label: const Text('回到直播'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _programme(BuildContext context, LiveProgramme item) {
    final theme = Theme.of(context);
    final state = item.stateAt(
      _now,
      supportsCatchup: _playback.supportsCatchup,
    );
    final playing = _isPlaying(item);
    final enabled =
        state == LiveProgrammeState.replay || state == LiveProgrammeState.live;
    final label = playing
        ? '播放中'
        : switch (state) {
            LiveProgrammeState.replay => '回看',
            LiveProgrammeState.live => '看直播',
            LiveProgrammeState.upcoming => '未播出',
            LiveProgrammeState.expired => '已过期',
            LiveProgrammeState.unavailable => item.end == null ? '待更新' : '无回看',
          };
    return RemoteTarget(
      key: ValueKey('live-programme-${item.key}'),
      radius: 0,
      selected: playing,
      label: '${liveEpgClock(item.start)}，${item.title}，${_range(item)}，$label',
      onPressed: !enabled || _busy || _playback.loading || playing
          ? null
          : () => unawaited(
              _play(state == LiveProgrammeState.live ? null : item),
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  liveEpgClock(item.start),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: enabled
                        ? theme.colorScheme.primary
                        : theme.disabledColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: item.title,
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: playing ? theme.colorScheme.primary : null,
                        fontWeight: playing ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _range(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: enabled
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
