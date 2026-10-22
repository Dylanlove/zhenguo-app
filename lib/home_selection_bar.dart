import 'package:flutter/material.dart';

import 'batch_downloads.dart';
import 'glass_panel.dart';

class HomeSelectionBar extends StatelessWidget {
  const HomeSelectionBar({
    super.key,
    required this.count,
    required this.focusNode,
    required this.onNext,
    this.safeBottom = true,
    this.glass = false,
  });

  final int count;
  final FocusNode focusNode;
  final VoidCallback onNext;
  final bool safeBottom, glass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  count == 0
                      ? '最多 ${BatchDownloads.maxDramas} 部'
                      : '下一步选择分集和画质',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
          final next = FilledButton(
            key: const ValueKey('download-selected-dramas'),
            focusNode: focusNode,
            onPressed: count == 0 ? null : onNext,
            style: FilledButton.styleFrom(
              minimumSize: const Size(96, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text('下一步'),
          );
          if (constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 12), next],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 16),
              next,
            ],
          );
        },
      ),
    );
    if (glass) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassBottomNavigation.sideMargin,
            0,
            GlassBottomNavigation.sideMargin,
            GlassBottomNavigation.bottomMargin,
          ),
          child: GlassPanel(child: content),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(top: false, bottom: safeBottom, child: content),
      ),
    );
  }
}
