import 'dart:math';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'glass_panel.dart';
import 'models.dart';
import 'remote_widgets.dart';

class CatalogFilters extends StatefulWidget {
  const CatalogFilters({
    super.key,
    required this.categories,
    this.category = '',
    this.selected,
    required this.onCategory,
    required this.onRetry,
    this.error,
    this.trailing,
    this.remoteKey,
    this.remoteAutofocus = false,
    this.onExitUp,
    this.onExitDown,
  });

  final List<CatalogCategory> categories;
  final String category;
  final Set<String>? selected;
  final String? error;
  final ValueChanged<String> onCategory;
  final VoidCallback onRetry;
  final Widget? trailing;
  final GlobalKey<RemoteRowState>? remoteKey;
  final bool remoteAutofocus;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;

  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  final _anchors = <String, GlobalKey>{};

  bool _isSelected(String id) =>
      widget.selected?.contains(id) ??
      id == CatalogCategory.baseId(widget.category);

  int get _selectedIndex {
    final index = widget.categories.indexWhere(
      (entry) => entry.id == CatalogCategory.baseId(widget.category),
    );
    return index < 0 ? 0 : index;
  }

  @override
  void didUpdateWidget(covariant CatalogFilters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final anchor =
            _anchors[CatalogCategory.baseId(widget.category)]?.currentContext;
        if (mounted && anchor != null) {
          Scrollable.ensureVisible(
            anchor,
            alignment: .4,
            duration: const Duration(milliseconds: 180),
          );
        }
      });
    }
  }

  Future<void> _showFilters(CatalogCategory category) async {
    var values = category.filterValues(widget.category);
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .85,
        child: StatefulBuilder(
          builder: (context, update) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${category.name}筛选',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => update(
                          () => values = category.filterValues(category.id),
                        ),
                        child: const Text('重置'),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final filter in category.filters)
                            if (filter.active(values)) ...[
                              Text(
                                filter.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final option in filter.values)
                                    ChoiceChip(
                                      label: Text(option.name),
                                      selected: values[filter.key] == option.id,
                                      onSelected: (_) => update(() {
                                        values[filter.key] = option.id;
                                        for (final dependent
                                            in category.filters) {
                                          if (dependent.parentKey ==
                                              filter.key) {
                                            values.remove(dependent.key);
                                          }
                                        }
                                        values = category.filterValues(
                                          category.selection(values),
                                        );
                                      }),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 20),
                            ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, category.selection(values)),
                    child: const Text('应用筛选'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && result != null) widget.onCategory(result);
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final current = widget.categories
        .where(
          (category) => category.id == CatalogCategory.baseId(widget.category),
        )
        .firstOrNull;
    return SizedBox(
      height: television
          ? 64
          : max(52, MediaQuery.textScalerOf(context).scale(14) + 28),
      child: Row(
        children: [
          Expanded(
            child: television
                ? RemoteRow(
                    key: widget.remoteKey,
                    itemKeys: [
                      for (final entry in widget.categories) entry.id,
                      if (current != null && current.filters.isNotEmpty)
                        'category-filter',
                    ],
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    initialIndex: _selectedIndex,
                    autofocus: widget.remoteAutofocus,
                    onExitUp: widget.onExitUp,
                    onExitDown: widget.onExitDown,
                    itemBuilder: (_, index, node, onFocus) {
                      if (index == widget.categories.length &&
                          current != null) {
                        return RemoteButton(
                          key: const ValueKey('remote-category-filter'),
                          label: '筛选',
                          focusNode: node,
                          onFocus: onFocus,
                          onPressed: () => _showFilters(current),
                        );
                      }
                      final entry = widget.categories[index];
                      return KeyedSubtree(
                        key: _anchors.putIfAbsent(entry.id, GlobalKey.new),
                        child: RemoteButton(
                          key: ValueKey('category-${entry.id}'),
                          label: entry.name,
                          selected: _isSelected(entry.id),
                          focusNode: node,
                          onFocus: onFocus,
                          onPressed: () => widget.onCategory(entry.id),
                        ),
                      );
                    },
                  )
                : SingleChildScrollView(
                    key: const ValueKey('catalog-categories'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        for (final entry in widget.categories)
                          Padding(
                            key: _anchors.putIfAbsent(entry.id, GlobalKey.new),
                            padding: const EdgeInsets.only(right: 6),
                            child: PressScale(
                              scale: .94,
                              child: ChoiceChip(
                                key: ValueKey('category-${entry.id}'),
                                label: Text(entry.name),
                                selected: _isSelected(entry.id),
                                showCheckmark: false,
                                onSelected: (_) => widget.onCategory(entry.id),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          if (!television && current != null && current.filters.isNotEmpty)
            IconButton(
              tooltip: '分类筛选',
              onPressed: () => _showFilters(current),
              icon: Icon(
                CatalogCategory.query(widget.category).isEmpty
                    ? Icons.filter_alt_outlined
                    : Icons.filter_alt_rounded,
              ),
            ),
          if (widget.error != null)
            IconButton(
              tooltip: widget.error,
              onPressed: widget.onRetry,
              icon: Icon(
                Icons.refresh_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}
