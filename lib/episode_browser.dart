import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'models.dart';
import 'remote_widgets.dart';

const episodePageSize = 50;

class EpisodeRangeBar extends StatelessWidget {
  const EpisodeRangeBar({
    super.key,
    required this.episodes,
    required this.page,
    required this.onLocate,
    this.currentNumber,
    this.title = '选集',
  });
  final List<Episode> episodes;
  final int page;
  final ValueChanged<int> onLocate;
  final int? currentNumber;
  final String title;

  Future<void> _jump(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    final index = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          void submit() {
            final number = int.tryParse(controller.text.trim());
            final found = episodes.indexWhere(
              (episode) => episode.number == number,
            );
            if (found < 0) {
              setState(() => error = '没有找到这一集，请输入已有集数');
            } else {
              Navigator.pop(context, found);
            }
          }

          return AlertDialog(
            title: const Text('跳转到指定集数'),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: '集数', errorText: error),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('定位')),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (index != null && context.mounted) onLocate(index);
  }

  @override
  Widget build(BuildContext context) {
    final count = (episodes.length / episodePageSize).ceil();
    final current = episodes.indexWhere(
      (episode) => episode.number == currentNumber,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$title · ${episodes.length} 集',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (current >= 0)
                TextButton(
                  onPressed: () => onLocate(current),
                  child: const Text('定位当前'),
                ),
              IconButton(
                tooltip: '跳转集数',
                onPressed: episodes.isEmpty ? null : () => _jump(context),
                icon: const Icon(Icons.pin_outlined),
              ),
            ],
          ),
          if (count > 1)
            Row(
              children: [
                IconButton(
                  tooltip: '上一组选集',
                  onPressed: page > 0
                      ? () => onLocate((page - 1) * episodePageSize)
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      key: const ValueKey('episode-range'),
                      isExpanded: true,
                      value: page.clamp(0, count - 1),
                      items: [
                        for (var i = 0; i < count; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '第 ${episodes[i * episodePageSize].number}–${episodes[min((i + 1) * episodePageSize, episodes.length) - 1].number} 集',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) onLocate(value * episodePageSize);
                      },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一组选集',
                  onPressed: page + 1 < count
                      ? () => onLocate((page + 1) * episodePageSize)
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class EpisodeBrowser extends StatefulWidget {
  const EpisodeBrowser({
    super.key,
    required this.episodes,
    required this.onSelected,
    this.currentNumber,
    this.selectedNumbers,
    this.keyPrefix = 'episode',
    this.title = '选集',
    this.compact = false,
    this.dense = false,
    this.onExitUp,
    this.onExitDown,
  });
  final List<Episode> episodes;
  final ValueChanged<int> onSelected;
  final int? currentNumber;
  final Set<int>? selectedNumbers;
  final String keyPrefix;
  final String title;
  final bool compact;
  final bool dense;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;
  @override
  State<EpisodeBrowser> createState() => _EpisodeBrowserState();
}

class _EpisodeBrowserState extends State<EpisodeBrowser> {
  final _scroll = ScrollController();
  String _layout = '';
  int get _pageSize => episodePageSize;
  late int _page =
      max(
        0,
        widget.episodes.indexWhere((e) => e.number == widget.currentNumber),
      ) ~/
      _pageSize;
  int? _located;

  @override
  void didUpdateWidget(EpisodeBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentNumber != widget.currentNumber) {
      _page =
          max(
            0,
            widget.episodes.indexWhere(
              (episode) => episode.number == widget.currentNumber,
            ),
          ) ~/
          _pageSize;
      _located = null;
    }
    _page = _page.clamp(0, max(0, (widget.episodes.length - 1) ~/ _pageSize));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) return _continuousGrid(context);
    final pageSize = _pageSize;
    _page = _page.clamp(0, max(0, (widget.episodes.length - 1) ~/ pageSize));
    final start = _page * pageSize;
    final visible = widget.episodes.skip(start).take(pageSize).toList();
    final television = AppLayout.isTelevision(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EpisodeRangeBar(
          episodes: widget.episodes,
          page: _page,
          title: widget.title,
          currentNumber: widget.currentNumber,
          onLocate: (index) => setState(() {
            _page = index ~/ episodePageSize;
            _located = widget.episodes[index].number;
          }),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final digits = visible.fold<int>(
                1,
                (value, episode) =>
                    max(value, episode.number.toString().length),
              );
              final scale = MediaQuery.textScalerOf(context);
              final dense = widget.dense && !television;
              final compact = widget.compact;
              final double fontSize;
              final double gap;
              final double inset;
              final double baseline;
              final double textPad;
              final int minColumns;
              final int maxColumns;
              final double minExtent;
              final double extentPad;
              final EdgeInsets padding;
              if (dense) {
                fontSize = 14;
                gap = 6;
                inset = 16;
                baseline = 36;
                textPad = 12;
                minColumns = 4;
                maxColumns = 8;
                minExtent = 38;
                extentPad = 18;
                padding = const EdgeInsets.fromLTRB(8, 2, 8, 12);
              } else if (compact) {
                fontSize = 18;
                gap = 6;
                inset = 8;
                baseline = 64;
                textPad = 28;
                minColumns = 4;
                maxColumns = 12;
                minExtent = 46;
                extentPad = 24;
                padding = const EdgeInsets.fromLTRB(4, 4, 4, 12);
              } else {
                fontSize = 20;
                gap = 8;
                inset = 36;
                baseline = television ? 100 : 82;
                textPad = 40;
                minColumns = 1;
                maxColumns = 12;
                minExtent = 56;
                extentPad = 30;
                padding = const EdgeInsets.fromLTRB(18, 2, 18, 18);
              }
              final fitted =
                  ((constraints.maxWidth - inset) /
                          (max(
                                baseline,
                                scale.scale(fontSize) * digits * .65 + textPad,
                              ) +
                              gap))
                      .floor();
              final columns = fitted.clamp(minColumns, maxColumns);
              final extent = max(minExtent, scale.scale(fontSize) + extentPad);
              final target = max(
                0,
                visible.indexWhere(
                  (episode) =>
                      episode.number == (_located ?? widget.currentNumber),
                ),
              );
              final layout =
                  '$_page:$_located:${widget.currentNumber}:$columns:$extent:${constraints.maxHeight}';
              if (layout != _layout) {
                _layout = layout;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_scroll.hasClients || _layout != layout) {
                    return;
                  }
                  _scroll.jumpTo(
                    ((dense ? 2 : 18) +
                            target ~/ columns * (extent + gap) -
                            constraints.maxHeight / 2 +
                            extent / 2)
                        .clamp(0.0, _scroll.position.maxScrollExtent),
                  );
                });
              }
              return RemoteGrid(
                key: ValueKey('episode-page-$_page-$_located'),
                controller: _scroll,
                autofocus: television && _located != null,
                initialIndex: target,
                onExitUp: widget.onExitUp,
                onExitDown: widget.onExitDown,
                itemKeys: visible
                    .map((episode) => '${episode.number}')
                    .toList(),
                columns: columns,
                itemExtent: extent,
                spacing: gap,
                padding: padding,
                itemBuilder: (_, index, node, onFocus) {
                  final episode = visible[index];
                  return RemoteEpisodeButton(
                    key: ValueKey('${widget.keyPrefix}-${episode.number}'),
                    number: episode.number,
                    vip: episode.vip,
                    compact: widget.compact,
                    dense: dense,
                    current:
                        widget.selectedNumbers?.contains(episode.number) ??
                        episode.number == widget.currentNumber,
                    focusNode: node,
                    onFocus: onFocus,
                    onPressed: () => widget.onSelected(start + index),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _compactRangeSelector({required int target, required int pageCount}) {
    if (pageCount <= 1) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final selectedPage = (target ~/ episodePageSize).clamp(0, pageCount - 1);
    return SizedBox(
      height: 34,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 3),
        scrollDirection: Axis.horizontal,
        itemCount: pageCount,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, page) {
          final start = page * episodePageSize;
          final end = min(start + episodePageSize, widget.episodes.length) - 1;
          final selected = page == selectedPage;
          return OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foregroundColor: selected ? colors.onPrimary : colors.onSurface,
              backgroundColor: selected ? colors.primary : Colors.transparent,
              side: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
              ),
              textStyle: const TextStyle(fontSize: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            onPressed: () {
              setState(() {
                _located = widget.episodes[start].number;
              });
            },
            child: Text(
              '${widget.episodes[start].number}-${widget.episodes[end].number}',
            ),
          );
        },
      ),
    );
  }

  Widget _continuousGrid(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final television = AppLayout.isTelevision(context);
      final scale = MediaQuery.textScalerOf(context);
      final digits = widget.episodes.fold<int>(
        1,
        (value, episode) => max(value, episode.number.toString().length),
      );
      final minimum = max(40.0, scale.scale(14) * digits * .62 + 22);
      final columns = ((constraints.maxWidth - 12) / minimum).floor().clamp(
        5,
        television ? 12 : 10,
      );
      final extent = max(34.0, scale.scale(14) + 18);
      final target = max(
        0,
        widget.episodes.indexWhere(
          (episode) => episode.number == (_located ?? widget.currentNumber),
        ),
      );
      final pageCount = (widget.episodes.length / episodePageSize).ceil();
      final layout =
          'compact:${widget.episodes.length}:$_located:${widget.currentNumber}:$columns:$extent:${constraints.maxHeight}';
      if (layout != _layout) {
        _layout = layout;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || _layout != layout) return;
          _scroll.jumpTo(
            (target ~/ columns * (extent + 6) -
                    constraints.maxHeight / 2 +
                    extent / 2)
                .clamp(0.0, _scroll.position.maxScrollExtent),
          );
        });
      }
      return Column(
        children: [
          _compactRangeSelector(target: target, pageCount: pageCount),
          Expanded(
            child: RemoteGrid(
              key: ValueKey('episode-continuous-$_located'),
              controller: _scroll,
              autofocus: television && _located != null,
              initialIndex: target,
              itemKeys: widget.episodes
                  .map((episode) => '${episode.number}')
                  .toList(),
              columns: columns,
              itemExtent: extent,
              spacing: 5,
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
              itemBuilder: (_, index, node, onFocus) {
                final episode = widget.episodes[index];
                return RemoteEpisodeButton(
                  key: ValueKey('${widget.keyPrefix}-${episode.number}'),
                  number: episode.number,
                  vip: episode.vip,
                  compact: true,
                  current:
                      widget.selectedNumbers?.contains(episode.number) ??
                      episode.number == widget.currentNumber,
                  focusNode: node,
                  onFocus: onFocus,
                  onPressed: () => widget.onSelected(index),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
