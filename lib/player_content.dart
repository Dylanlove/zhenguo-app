import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'widgets.dart';

class PlayerContentPanel extends StatelessWidget {
  const PlayerContentPanel({
    super.key,
    required this.currentTab,
    required this.onTabChanged,
    required this.episodes,
    required this.synopsis,
    required this.recommendations,
    required this.downloads,
  });

  final int currentTab;
  final ValueChanged<int> onTabChanged;
  final Widget episodes, synopsis, recommendations, downloads;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tabs = ['选集', '简介', '推荐', '下载'];
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
              child: SizedBox(
                height: 42,
                child: Row(
                  children: [
                    for (var index = 0; index < tabs.length; index++)
                      Expanded(
                        child: InkWell(
                          onTap: () => onTabChanged(index),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: currentTab == index
                                      ? colors.primary
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Text(
                              tabs[index],
                              style: TextStyle(
                                color: currentTab == index
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant,
                                fontSize: 13,
                                fontWeight: currentTab == index
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: switch (currentTab) {
                    0 => episodes,
                    1 => synopsis,
                    2 => recommendations,
                    _ => downloads,
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerSynopsisView extends StatelessWidget {
  const PlayerSynopsisView({
    super.key,
    required this.detail,
    required this.repository,
    required this.followControl,
  });

  final DramaDetail detail;
  final AppRepository repository;
  final Widget followControl;

  @override
  Widget build(BuildContext context) {
    final drama = detail.drama;
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
      if (drama.category.isNotEmpty) drama.category,
    ];
    final body = drama.description.trim().isEmpty ? '暂无简介' : drama.description;
    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            '${drama.onlineDate} 上线',
                          if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                          if (drama.views.isNotEmpty) '播放 ${drama.views}',
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          followControl,
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  Chip(label: Text(tag), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.55)),
          if (detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }
}

class PlayerFailureActions extends StatelessWidget {
  const PlayerFailureActions({
    super.key,
    required this.onReport,
    this.onRoutes,
    this.onSearch,
    this.onSwitchOnline,
    this.sourceDiagnostics,
  });

  final VoidCallback? onReport, onRoutes, onSearch, onSwitchOnline;
  final Widget? sourceDiagnostics;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    runSpacing: 4,
    children: [
      if (onRoutes != null)
        TextButton.icon(
          key: const ValueKey('player-error-routes'),
          onPressed: onRoutes,
          icon: const Icon(Icons.alt_route_rounded),
          label: const Text('选择播放线路'),
        ),
      if (onSearch != null)
        TextButton.icon(
          onPressed: onSearch,
          icon: const Icon(Icons.travel_explore_rounded),
          label: const Text('其他站源'),
        ),
      if (onSwitchOnline != null)
        TextButton.icon(
          onPressed: onSwitchOnline,
          icon: const Icon(Icons.cloud_outlined),
          label: const Text('改为在线播放'),
        ),
      ?sourceDiagnostics,
      if (onReport != null)
        TextButton.icon(
          key: const ValueKey('player-error-report'),
          onPressed: onReport,
          icon: const Icon(Icons.troubleshoot_rounded),
          label: const Text('播放记录 / 报告'),
        ),
    ],
  );
}
