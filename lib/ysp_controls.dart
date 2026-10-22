import 'package:flutter/material.dart';

import 'live_epg.dart';
import 'live_playback.dart';
import 'live_programme_guide.dart';
import 'playback_preferences.dart';
import 'ysp_live.dart';

Future<String?> showYspPlaybackMenu(
  BuildContext context,
  LivePlaybackController playback, {
  String catchupLabel = '7 天回看',
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.high_quality),
            title: const Text('画质选择'),
            onTap: () => Navigator.pop(context, 'quality'),
          ),
          if (playback.supportsCatchup)
            ListTile(
              leading: const Icon(Icons.replay),
              title: Text(catchupLabel),
              onTap: () => Navigator.pop(context, 'catchup'),
            ),
          if (playback.catchup)
            ListTile(
              leading: const Icon(Icons.live_tv),
              title: const Text('回到直播'),
              onTap: () => Navigator.pop(context, 'live'),
            ),
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('订阅分享与诊断'),
            onTap: () => Navigator.pop(context, 'settings'),
          ),
        ],
      ),
    ),
  ),
);

Future<void> showYspQualitySheet(
  BuildContext context,
  LivePlaybackController playback,
) async {
  final selected = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          const ListTile(title: Text('央视频画质')),
          for (final quality in const ['auto', 'best', 'hd'])
            ListTile(
              selected: playback.quality == quality,
              leading: Icon(
                playback.quality == quality
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(yspQualityLabel(quality)),
              subtitle: Text(switch (quality) {
                'best' => '优先高码率，取流失败时自动使用备用线路',
                'hd' => '优先高清线路，适合快速换台或较慢网络',
                _ => '先播放高清，停留 10 秒后尝试高码率',
              }),
              onTap: () => Navigator.pop(context, quality),
            ),
        ],
      ),
    ),
  );
  if (selected != null) await playback.setQuality(selected);
}

Future<void> showYspSpeedSheet(
  BuildContext context,
  LivePlaybackController playback,
) async {
  final selected = await showModalBottomSheet<double>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final speed in playbackSpeeds)
              ChoiceChip(
                label: Text('${speedLabel(speed)}x'),
                selected: playback.speed == speed,
                onSelected: (_) => Navigator.pop(context, speed),
              ),
          ],
        ),
      ),
    ),
  );
  if (selected != null) await playback.setSpeed(selected);
}

Future<void> showYspCatchupSheet(
  BuildContext context,
  LivePlaybackController playback,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (context) => FractionallySizedBox(
    heightFactor: .88,
    child: SafeArea(
      top: false,
      child: LiveProgrammeGuide(
        playback: playback,
        onClose: () => Navigator.pop(context),
        onManualTime: () => showYspManualCatchupSheet(context, playback),
      ),
    ),
  ),
);

Future<void> showYspManualCatchupSheet(
  BuildContext context,
  LivePlaybackController playback,
) async {
  final selected = await showModalBottomSheet<({DateTime start, DateTime end})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _YspCatchupPicker(playback: playback),
  );
  if (selected != null) {
    await playback.playCatchup(selected.start, selected.end);
  }
}

class _YspCatchupPicker extends StatefulWidget {
  const _YspCatchupPicker({required this.playback});

  final LivePlaybackController playback;

  @override
  State<_YspCatchupPicker> createState() => _YspCatchupPickerState();
}

class _YspCatchupPickerState extends State<_YspCatchupPicker> {
  late DateTime _start =
      widget.playback.catchupStart ??
      DateTime.now().subtract(const Duration(hours: 1));
  late DateTime _end = widget.playback.catchupEnd ?? DateTime.now();
  String? _error;

  String _label(DateTime value) {
    final local = liveEpgTime(value);
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} ${liveEpgClock(value)}';
  }

  Future<void> _pick({required bool start}) async {
    final current = liveEpgTime(start ? _start : _end);
    final now = liveEpgTime(DateTime.now());
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: now.subtract(const Duration(days: 7)),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;
    final selected = DateTime.utc(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ).subtract(const Duration(hours: 8));
    setState(() {
      if (start) {
        _start = selected;
      } else {
        _end = selected;
      }
      _error = null;
    });
  }

  void _play() {
    final now = DateTime.now();
    if (!_end.isAfter(_start) ||
        _start.isBefore(now.subtract(const Duration(days: 7))) ||
        _end.isAfter(now.add(const Duration(minutes: 1)))) {
      setState(() => _error = '请选择最近 7 天内的时间，结束时间须晚于开始时间。');
      return;
    }
    Navigator.pop(context, (start: _start, end: _end));
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.playback.channel?.name ?? '央视频'} · 手动选时',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text('按北京时间选择最近 7 天内的起止时间。回看支持进度和倍速。'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _pick(start: true),
            icon: const Icon(Icons.schedule),
            label: Text('开始：${_label(_start)}'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _pick(start: false),
            icon: const Icon(Icons.schedule),
            label: Text('结束：${_label(_end)}'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _play,
            icon: const Icon(Icons.replay),
            label: const Text('播放回看'),
          ),
        ],
      ),
    ),
  );
}
