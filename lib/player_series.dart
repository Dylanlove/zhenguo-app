import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'local_store.dart';
import 'models.dart';

class PlayerSeriesController extends ChangeNotifier {
  PlayerSeriesController({
    required this.repository,
    required this.store,
    required this.anchor,
    List<HongguoSeriesEntry>? initialEntries,
  }) : _ownerEpoch = store.profileEpoch {
    entries = hongguoSeriesEntries(anchor, [
      ...?initialEntries?.map((entry) => entry.drama),
      ...store.seriesDramasFor(anchor),
    ]);
  }

  final AppRepository repository;
  final LocalStore store;
  final Drama anchor;
  final int _ownerEpoch;
  List<HongguoSeriesEntry> entries = const [];
  bool loading = false;
  bool _closed = false;
  int _generation = 0;

  Future<void> discover() async {
    if (_closed ||
        loading ||
        anchor.source != SourceSite.hongguo.id ||
        !store.allowsSource(anchor.source))
      return;
    final generation = ++_generation;
    loading = true;
    notifyListeners();
    try {
      final info = hongguoSeriesInfo(anchor);
      final query = info?.baseTitle ?? anchor.title.trim();
      if (query.length < 2) return;
      final page = await repository.catalog(anchor.source, query: query);
      if (_closed ||
          generation != _generation ||
          store.profileEpoch != _ownerEpoch ||
          store.locked ||
          !store.allowsSource(anchor.source))
        return;
      final candidates = page.items
          .where((drama) => drama.source == anchor.source)
          .toList();
      final discovered = hongguoSeriesEntries(anchor, [
        ...entries.map((entry) => entry.drama),
        ...store.seriesDramasFor(anchor),
        ...candidates,
      ]);
      if (discovered.isNotEmpty) entries = discovered;
    } catch (_) {
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    super.dispose();
  }
}

class PlayerSeriesBar extends StatelessWidget {
  const PlayerSeriesBar({
    super.key,
    required this.entries,
    required this.currentDramaId,
    this.onSelected,
    this.busy = false,
  });

  final List<HongguoSeriesEntry> entries;
  final String currentDramaId;
  final ValueChanged<Drama>? onSelected;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (entries.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            busy ? '正在准备所选季…' : '同系列 · 选择季',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: entry.drama.title,
                      child: ChoiceChip(
                        key: ValueKey('player-season-${entry.drama.id}'),
                        label: Text(entry.label),
                        selected: entry.drama.id == currentDramaId,
                        onSelected:
                            busy ||
                                onSelected == null ||
                                entry.drama.id == currentDramaId
                            ? null
                            : (_) => onSelected!(entry.drama),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
