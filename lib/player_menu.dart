import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'episode_browser.dart';
import 'hongguo_series.dart';
import 'player_series.dart';
import 'playback_preferences.dart';
import 'video_enhancement.dart';
import 'video_enhancement_settings.dart';

enum PlayerMenuSection { episodes, speed, quality, settings }

class PlayerMenu extends StatefulWidget {
  const PlayerMenu({
    super.key,
    required this.section,
    required this.episodes,
    required this.currentIndex,
    required this.preferences,
    required this.qualities,
    required this.sourceQuality,
    required this.local,
    required this.favorite,
    required this.mobile,
    required this.onEpisode,
    required this.onPreferences,
    required this.onFavorite,
    this.actualResolution,
    this.showDanmaku = false,
    this.danmakuStatus = '',
    this.onDanmakuSettings,
    this.preloadStatus = '',
    this.enhancement,
    this.onCompareEnhancement,
    this.routeIndex = 0,
    this.routeCount = 0,
    this.routeLabel,
    this.onRoute,
    this.seriesEntries = const [],
    this.currentDramaId = '',
    this.onSeason,
    this.switchingSeason = false,
    this.onDiagnostics,
  });

  final PlayerMenuSection section;
  final List<Episode> episodes;
  final int currentIndex;
  final PlaybackPreferences preferences;
  final List<int> qualities;
  final int sourceQuality;
  final String? actualResolution;
  final bool local;
  final bool favorite;
  final bool mobile;
  final bool showDanmaku;
  final String danmakuStatus;
  final VoidCallback? onDanmakuSettings;
  final String preloadStatus;
  final VideoEnhancementController? enhancement;
  final VoidCallback? onCompareEnhancement;
  final int routeIndex;
  final int routeCount;
  final String Function(int)? routeLabel;
  final ValueChanged<int>? onRoute;
  final List<HongguoSeriesEntry> seriesEntries;
  final String currentDramaId;
  final ValueChanged<Drama>? onSeason;
  final bool switchingSeason;
  final VoidCallback? onDiagnostics;
  final ValueChanged<int> onEpisode;
  final Future<void> Function(PlaybackPreferences) onPreferences;
  final Future<void> Function() onFavorite;

  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<PlayerMenu> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '未能保存设置，请检查存储空间后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final colors = Theme.of(context).colorScheme;
    final title = switch (widget.section) {
      PlayerMenuSection.episodes => '选集 · 共 ${widget.episodes.length} 集',
      PlayerMenuSection.speed => '播放倍速',
      PlayerMenuSection.quality => '清晰度',
      PlayerMenuSection.settings => '播放设置',
    };
    return Dialog(
      key: const ValueKey('player-menu'),
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: colors.surface,
      child: SizedBox(
        width: landscape ? math.min(440, size.width * .6) : 600,
        height: landscape ? size.height : size.height * .72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭菜单',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFFB4A8)),
                ),
              ),
            Expanded(
              child: widget.section == PlayerMenuSection.episodes
                  ? Column(
                      children: [
                        PlayerSeriesBar(
                          entries: widget.seriesEntries,
                          currentDramaId: widget.currentDramaId,
                          onSelected: widget.onSeason,
                          busy: widget.switchingSeason,
                        ),
                        Expanded(
                          child: PlayerEpisodeGrid(
                            episodes: widget.episodes,
                            currentIndex: widget.currentIndex,
                            keyPrefix: 'menu-episode',
                            onSelected: widget.onEpisode,
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
                      child: _settings(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settings() {
    final preferences = widget.preferences;
    final all = widget.section == PlayerMenuSection.settings;
    final colors = Theme.of(context).colorScheme;
    final helperStyle = TextStyle(
      fontSize: 13,
      color: colors.onSurfaceVariant,
      height: 1.5,
    );
    final qualities = {
      0,
      ...widget.qualities.where((quality) => quality > 0),
    }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (all || widget.section == PlayerMenuSection.speed) ...[
          const Text('倍速'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                ChoiceChip(
                  key: ValueKey('menu-speed-$speed'),
                  label: Text('${speed}x'),
                  selected: speed == preferences.speed,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(speed: speed),
                          ),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        if (all || widget.section == PlayerMenuSection.quality) ...[
          if (widget.onRoute != null && widget.routeCount > 1) ...[
            const Text('播放线路'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var route = 0; route < widget.routeCount; route++)
                  ChoiceChip(
                    key: ValueKey('menu-route-$route'),
                    label: Text(
                      widget.routeLabel?.call(route) ?? '线路 ${route + 1}',
                    ),
                    selected: route == widget.routeIndex,
                    onSelected: _busy ? null : (_) => widget.onRoute!(route),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          const Text('清晰度'),
          const SizedBox(height: 8),
          Text(
            widget.actualResolution == null
                ? '实际分辨率待识别'
                : '实际播放：${widget.actualResolution}',
            style: helperStyle,
          ),
          if (widget.local || widget.sourceQuality > 0)
            Text(
              widget.local
                  ? '本集正在播放本地文件，画质偏好用于后续在线播放。'
                  : '源站档位：${widget.sourceQuality}P',
              style: helperStyle,
            ),
          const SizedBox(height: 8),
          Text(
            '画质偏好：${preferences.quality == 0 ? '自动（优先高清）' : '${preferences.quality}P'}',
            style: helperStyle,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final quality in qualities)
                ChoiceChip(
                  key: ValueKey('menu-quality-$quality'),
                  label: Text(quality == 0 ? '自动（优先高清）' : '${quality}P'),
                  selected: quality == preferences.quality,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(quality: quality),
                          ),
                        ),
                ),
            ],
          ),
          if (!qualities.contains(preferences.quality))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.qualities.any((quality) => quality > 0)
                    ? '已保存 ${preferences.quality}P 偏好，本集暂无此画质。'
                    : '已保存 ${preferences.quality}P 偏好，本集未提供可切换的清晰度档位。',
                style: helperStyle,
              ),
            ),
          const SizedBox(height: 20),
        ],
        if ((all || widget.section == PlayerMenuSection.quality) &&
            widget.enhancement != null)
          VideoEnhancementSettings(
            controller: widget.enhancement!,
            busy: _busy,
            onChanged: (enhancement) => _run(
              () => widget.onPreferences(
                preferences.copyWith(enhancement: enhancement),
              ),
            ),
            onCompare: widget.onCompareEnhancement ?? () {},
          ),
        if (widget.onDiagnostics != null &&
            (all || widget.section == PlayerMenuSection.quality))
          ListTile(
            key: const ValueKey('player-diagnostics'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.troubleshoot_rounded),
            title: const Text('播放诊断报告'),
            subtitle: const Text('查看播放记录、复制报告或扫码获取摘要'),
            onTap: widget.onDiagnostics,
          ),
        if (all && widget.showDanmaku) ...[
          ListTile(
            key: const ValueKey('player-menu-danmaku-settings'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.subtitles_outlined),
            title: const Text('弹幕设置'),
            subtitle: Text(widget.danmakuStatus),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _busy ? null : widget.onDanmakuSettings,
          ),
          const SizedBox(height: 8),
        ],
        if (all) ...[
          SwitchListTile.adaptive(
            key: const ValueKey('player-preload-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('下一集预加载'),
            subtitle: Text(widget.local ? '本地播放不预取网络视频' : widget.preloadStatus),
            value: preferences.preload,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.onPreferences(
                      preferences.copyWith(preload: value),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            key: const ValueKey('player-auto-advance'),
            contentPadding: EdgeInsets.zero,
            title: const Text('自动连播'),
            subtitle: const Text('关闭后，播放结束停在当前集'),
            value: preferences.autoAdvance,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.onPreferences(
                      preferences.copyWith(autoAdvance: value),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('player-favorite'),
            onPressed: _busy ? null : () => _run(widget.onFavorite),
            icon: Icon(
              widget.favorite
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
            ),
            label: Text(widget.favorite ? '取消追剧' : '加入追剧'),
          ),
          const SizedBox(height: 20),
          Text(
            widget.mobile
                ? '左侧上下滑调亮度，右侧上下滑调音量；左右滑动预览进度，松开定位。\n左侧双击后退 10 秒，右侧双击前进 10 秒，中间双击播放 / 暂停；轻点显示或隐藏控制栏。\n长按画面临时 ${speedLabel(preferences.holdSpeed)} 倍速，松开恢复；手势操作在顶部显示图标与数值提示。'
                : '空格：播放 / 暂停\n左右键：后退 / 快进 5 秒\n长按右键或画面：临时 ${speedLabel(preferences.holdSpeed)} 倍速\n上下键：音量 ±5%，M：静音\nF、F11、Ctrl+F：全屏\nEsc：先关闭菜单，再退出全屏',
            style: helperStyle.copyWith(height: 1.6),
          ),
        ],
      ],
    );
  }
}

class PlayerEpisodeGrid extends StatelessWidget {
  const PlayerEpisodeGrid({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelected,
    this.keyPrefix = 'play-episode',
    this.compact = false,
    this.title = '选集',
  });
  final List<Episode> episodes;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final String keyPrefix;
  final bool compact;
  final String title;
  @override
  Widget build(BuildContext context) => EpisodeBrowser(
    episodes: episodes,
    currentNumber: episodes.isEmpty
        ? null
        : episodes[currentIndex.clamp(0, episodes.length - 1)].number,
    onSelected: onSelected,
    keyPrefix: keyPrefix,
    compact: compact,
    title: title,
  );
}
