import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'danmaku_api.dart';
import 'danmaku_controller.dart';
import 'danmaku_models.dart';
import 'danmaku_preferences.dart';
import 'local_store.dart';

class DanmakuSettingsPanel extends StatefulWidget {
  const DanmakuSettingsPanel({
    super.key,
    required this.store,
    this.controller,
    this.television = false,
    this.apiClient,
  });
  final LocalStore store;
  final DanmakuController? controller;
  final bool television;
  final DanmakuService? apiClient;
  @override
  State<DanmakuSettingsPanel> createState() => _DanmakuSettingsPanelState();
}

class _DanmakuSettingsPanelState extends State<DanmakuSettingsPanel> {
  late DanmakuPreferences _settings =
      widget.store.playbackPreferences.danmakuSettings;
  late final int _epoch = widget.store.profileEpoch;
  late final _client = widget.apiClient ?? DanmakuApiClient();
  Future<void> _writes = Future.value();
  String? _error;
  bool get _allowed =>
      !widget.store.locked && _epoch == widget.store.profileEpoch;

  void _preview(DanmakuPreferences value) {
    if (!_allowed) return;
    widget.controller?.configure(value);
    setState(() {
      _settings = value;
      _error = null;
    });
  }

  Future<void> _save(DanmakuPreferences value) {
    _preview(value);
    final next = _writes.catchError((Object _) {}).then((_) async {
      if (!_allowed) return;
      await widget.store.setPlaybackPreferences(
        widget.store.playbackPreferences.copyWith(danmakuSettings: value),
      );
    });
    _writes = next;
    return next.catchError((Object _) {
      if (mounted) setState(() => _error = '设置未能保存，请重试');
    });
  }

  Future<void> _toggle(bool enabled) async {
    if (!_allowed) return;
    widget.controller?.setEnabled(enabled);
    try {
      await widget.store.setPlaybackPreferences(
        widget.store.playbackPreferences.copyWith(danmaku: enabled),
      );
    } catch (_) {
      if (mounted) {
        widget.controller?.setEnabled(widget.store.playbackPreferences.danmaku);
        setState(() => _error = '弹幕开关未能保存，请重试');
      }
    }
  }

  Future<void> _manageSources() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _DanmakuSourcesDialog(
        initial: _settings,
        client: _client,
        onChanged: _save,
      ),
    );
  }

  Future<void> _manualSearch() async {
    final source = _settings.source, controller = widget.controller;
    if (source == null ||
        controller == null ||
        !controller.supported ||
        !_allowed)
      return;
    final subjectKey = controller.subject!.key;
    final match = await showDialog<DanmakuMatch>(
      context: context,
      builder: (_) => _DanmakuSearchDialog(
        source: source,
        client: _client,
        keyword: controller.subject!.title,
      ),
    );
    if (match == null ||
        !mounted ||
        !_allowed ||
        controller.subject?.key != subjectKey ||
        _settings.source?.id != source.id)
      return;
    try {
      await controller.selectMatch(match);
      if (mounted && _allowed) {
        final value = _settings.remember(subjectKey, match);
        if (controller.onRememberMatch == null) {
          await _save(value);
        } else {
          setState(() => _settings = value);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '匹配已应用，保存记录失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height && size.width >= 640;
    final colors = Theme.of(context).colorScheme;
    final panel = Dialog(
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: widget.television
            ? 680
            : landscape
            ? 440
            : 620,
        height: math.min(
          820,
          size.height - MediaQuery.paddingOf(context).vertical - 24,
        ),
        child: DefaultTabController(
          length: 3,
          child: FocusTraversalGroup(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                  child: Row(
                    children: [
                      Icon(Icons.subtitles_outlined, color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '弹幕',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      AnimatedBuilder(
                        animation: widget.store,
                        builder: (_, _) => Switch.adaptive(
                          key: const ValueKey('danmaku-panel-enabled'),
                          value: widget.store.playbackPreferences.danmaku,
                          onChanged: _allowed ? _toggle : null,
                        ),
                      ),
                      IconButton(
                        autofocus: widget.television,
                        tooltip: '关闭弹幕设置',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () async {
                          await _writes.catchError((Object _) {});
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: '数据源'),
                    Tab(text: '显示'),
                    Tab(text: '高级'),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!, style: TextStyle(color: colors.error)),
                  ),
                Expanded(
                  child: !_allowed
                      ? const Center(child: Text('当前用户已变更，请重新打开设置'))
                      : TabBarView(
                          children: [_sources(), _display(), _advanced()],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return widget.television
        ? MediaQuery.withClampedTextScaling(minScaleFactor: 1.15, child: panel)
        : panel;
  }

  Widget _list(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
    children: children,
  );
  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget _card(Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: child,
  );
  Widget _sources() => _list([
    _card(
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const Icon(Icons.dns_outlined),
        title: Text(_settings.source?.name ?? '添加你的弹幕 API'),
        subtitle: Text(
          _settings.source == null
              ? '配置兼容弹弹play的服务后即可加载弹幕'
              : '默认数据源 · ${DanmakuSource.validateUrl(_settings.source!.baseUrl).host}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _manageSources,
      ),
    ),
    OutlinedButton.icon(
      key: const ValueKey('danmaku-api-management'),
      onPressed: _manageSources,
      icon: const Icon(Icons.tune_rounded),
      label: Text('API 管理 · ${_settings.sources.length} 个数据源'),
    ),
    _caption('匹配作品与分集'),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('自动匹配'),
      subtitle: const Text('根据剧名、季数和集数查找；多个候选时由你选择'),
      value: _settings.autoMatch,
      onChanged: (value) => _save(_settings.copyWith(autoMatch: value)),
    ),
    const SizedBox(height: 12),
    if (widget.controller != null)
      AnimatedBuilder(
        animation: widget.controller!,
        builder: (_, _) {
          final controller = widget.controller!;
          return _card(
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        controller.currentMatch == null
                            ? Icons.manage_search_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '当前匹配',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (controller.currentMatch != null) ...[
                    Text(controller.currentMatch!.label),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    controller.status,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (controller.loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('danmaku-manual-search'),
                        onPressed:
                            _settings.source != null && controller.supported
                            ? _manualSearch
                            : null,
                        icon: const Icon(Icons.search_rounded),
                        label: const Text('手动搜索'),
                      ),
                      TextButton.icon(
                        onPressed:
                            _settings.source != null &&
                                controller.supported &&
                                controller.enabled &&
                                !controller.loading &&
                                _settings.autoMatch
                            ? () => controller.retry(rematch: true)
                            : null,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重新匹配'),
                      ),
                      if (controller.canRetry)
                        TextButton(
                          onPressed: controller.retry,
                          child: const Text('重试加载'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      )
    else
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('播放在线剧集时，可在此查看匹配结果并手动选择分集。'),
      ),
  ]);

  Widget _slider({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required DanmakuPreferences Function(double) change,
  }) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            valueLabel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: valueLabel,
        onChanged: (value) => _preview(change(value)),
        onChangeEnd: (_) => _save(_settings),
      ),
    ],
  );

  Widget _choices<T>(
    List<T> choices,
    T selected,
    String Function(T) label,
    DanmakuPreferences Function(T) change,
  ) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      for (final value in choices)
        ChoiceChip(
          label: Text(label(value)),
          selected: selected == value,
          onSelected: (_) => _save(change(value)),
        ),
    ],
  );

  Widget _display() => _list([
    _card(
      Container(
        height: 92,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xff26394b), Color(0xff10171e)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: ClipRect(
          child: Text(
            '弹幕预览',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _settings.fontSize,
              fontWeight: FontWeight.w600,
              color: Color(
                0xff000000 |
                    (_settings.blockColored || _settings.useOriginalColor
                        ? 0xffffff
                        : _settings.color),
              ).withValues(alpha: _settings.opacity),
              shadows: [
                if (_settings.outline)
                  const Shadow(
                    color: Colors.black,
                    blurRadius: 1,
                    offset: Offset(1, 0),
                  ),
                if (_settings.shadow)
                  const Shadow(
                    color: Colors.black87,
                    blurRadius: 2,
                    offset: Offset(.6, .8),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
    _slider(
      label: '字体大小',
      valueLabel: '${_settings.fontSize.round()}',
      value: _settings.fontSize,
      min: 12,
      max: 36,
      divisions: 24,
      change: (value) => _settings.copyWith(fontSize: value),
    ),
    _slider(
      label: '不透明度',
      valueLabel: '${(_settings.opacity * 100).round()}%',
      value: _settings.opacity,
      min: .1,
      max: 1,
      divisions: 18,
      change: (value) => _settings.copyWith(opacity: value),
    ),
    _caption('文字颜色'),
    _choices(
      [true, false],
      _settings.useOriginalColor,
      (value) => value ? 'API 原色' : '统一颜色',
      (value) => _settings.copyWith(useOriginalColor: value),
    ),
    if (!_settings.useOriginalColor && !_settings.blockColored) ...[
      const SizedBox(height: 8),
      _choices(
        [0xffffff, 0xffe6a7, 0xa5e8ff, 0xc7f4c2, 0xffc8dd],
        _settings.color,
        (value) => switch (value) {
          0xffe6a7 => '柔黄',
          0xa5e8ff => '浅蓝',
          0xc7f4c2 => '薄荷',
          0xffc8dd => '浅粉',
          _ => '白色',
        },
        (value) => _settings.copyWith(color: value),
      ),
    ],
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('细描边'),
      subtitle: const Text('复杂背景下保持轮廓清晰'),
      value: _settings.outline,
      onChanged: (value) => _save(_settings.copyWith(outline: value)),
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('柔和阴影'),
      value: _settings.shadow,
      onChanged: (value) => _save(_settings.copyWith(shadow: value)),
    ),
    _caption('画面布局'),
    const Text('滚动与顶部弹幕区域'),
    const SizedBox(height: 10),
    _choices(
      [.25, .4, .5, .75, 1.0],
      _settings.area,
      (value) => value == 1 ? '全屏' : '${(value * 100).round()}%',
      (value) => _settings.copyWith(area: value),
    ),
    const SizedBox(height: 16),
    const Text('弹幕密度'),
    const SizedBox(height: 10),
    _choices(
      DanmakuDensity.values,
      _settings.density,
      (value) => switch (value) {
        DanmakuDensity.low => '低 · 舒适',
        DanmakuDensity.medium => '中 · 均衡',
        DanmakuDensity.high => '高 · 热闹',
      },
      (value) => _settings.copyWith(density: value),
    ),
    const SizedBox(height: 20),
    _slider(
      label: '滚动速度',
      valueLabel: '${(8 / _settings.speed).toStringAsFixed(1)} 秒 / 屏',
      value: _settings.speed,
      min: .5,
      max: 2,
      divisions: 15,
      change: (value) => _settings.copyWith(speed: value),
    ),
    _caption('显示类型'),
    Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        FilterChip(
          label: const Text('滚动'),
          selected: _settings.scroll,
          onSelected: (value) => _save(_settings.copyWith(scroll: value)),
        ),
        FilterChip(
          label: const Text('顶部固定'),
          selected: _settings.top,
          onSelected: (value) => _save(_settings.copyWith(top: value)),
        ),
        FilterChip(
          label: const Text('底部固定'),
          selected: _settings.bottom,
          onSelected: (value) => _save(_settings.copyWith(bottom: value)),
        ),
      ],
    ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('字幕避让'),
      subtitle: const Text('为底部字幕预留画面空间'),
      value: _settings.subtitleSafe,
      onChanged: (value) => _save(_settings.copyWith(subtitleSafe: value)),
    ),
  ]);

  Widget _advanced() => _list([
    _caption('时间同步'),
    _slider(
      label: '弹幕时间偏移',
      valueLabel:
          '${_settings.offsetSeconds > 0 ? '+' : ''}${_settings.offsetSeconds.toStringAsFixed(1)} 秒',
      value: _settings.offsetSeconds,
      min: -120,
      max: 120,
      divisions: 480,
      change: (value) => _settings.copyWith(offsetSeconds: value),
    ),
    Text(
      '正数延后，负数提前。只调整弹幕，不改变视频进度。',
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      children: [
        OutlinedButton(
          onPressed: () => _save(
            _settings.copyWith(
              offsetSeconds: (_settings.offsetSeconds - 1).clamp(-120, 120),
            ),
          ),
          child: const Text('−1 秒'),
        ),
        TextButton(
          onPressed: () => _save(_settings.copyWith(offsetSeconds: 0)),
          child: const Text('归零'),
        ),
        OutlinedButton(
          onPressed: () => _save(
            _settings.copyWith(
              offsetSeconds: (_settings.offsetSeconds + 1).clamp(-120, 120),
            ),
          ),
          child: const Text('+1 秒'),
        ),
      ],
    ),
    _caption('内容过滤'),
    _card(
      ListTile(
        title: const Text('屏蔽关键词'),
        subtitle: Text('${_settings.keywords.length} 个关键词 · 点击编辑'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: _editKeywords,
      ),
    ),
    if (_settings.keywords.isNotEmpty)
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final keyword in _settings.keywords)
            InputChip(
              label: Text(keyword),
              onDeleted: () => _save(
                _settings.copyWith(
                  keywords: _settings.keywords
                      .where((value) => value != keyword)
                      .toList(),
                ),
              ),
            ),
        ],
      ),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('屏蔽彩色弹幕'),
      subtitle: const Text('统一以白色显示所有文字'),
      value: _settings.blockColored,
      onChanged: (value) => _save(_settings.copyWith(blockColored: value)),
    ),
    const SizedBox(height: 20),
    OutlinedButton.icon(
      onPressed: () => _save(_settings.resetDisplay()),
      icon: const Icon(Icons.restart_alt_rounded),
      label: const Text('恢复默认显示与高级设置'),
    ),
    const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Text('数据源和手动匹配记录会保留。', style: TextStyle(fontSize: 12)),
    ),
  ]);

  Future<void> _editKeywords() async {
    final input = TextEditingController(text: _settings.keywords.join('\n'));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('屏蔽关键词'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: input,
            minLines: 3,
            maxLines: 8,
            maxLength: 6000,
            decoration: const InputDecoration(hintText: '每行一个，最多 100 个关键词'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (result != null && mounted && _allowed)
      await _save(
        _settings.copyWith(
          keywords: result
              .split(RegExp(r'[\n\r]+'))
              .map((word) => trimDanmakuText(word.trim(), 60))
              .where((word) => word.isNotEmpty)
              .toSet()
              .take(100)
              .toList(),
        ),
      );
  }

  @override
  void dispose() {
    if (widget.apiClient == null) _client.dispose();
    super.dispose();
  }
}

enum _SourceAction { probe, edit, delete }

class _DanmakuSourcesDialog extends StatefulWidget {
  const _DanmakuSourcesDialog({
    required this.initial,
    required this.client,
    required this.onChanged,
  });
  final DanmakuPreferences initial;
  final DanmakuService client;
  final Future<void> Function(DanmakuPreferences) onChanged;
  @override
  State<_DanmakuSourcesDialog> createState() => _DanmakuSourcesDialogState();
}

class _DanmakuSourcesDialogState extends State<_DanmakuSourcesDialog> {
  late DanmakuPreferences _settings = widget.initial;
  final _messages = <String, String>{};
  final _checks = <String, DanmakuCancellation>{};
  Future<void> _save(DanmakuPreferences value) async {
    setState(() => _settings = value);
    await widget.onChanged(value);
  }

  Future<void> _edit([DanmakuSource? source]) async {
    final result = await showDialog<DanmakuSource>(
      context: context,
      builder: (_) => _DanmakuSourceEditor(source: source),
    );
    if (result == null || !mounted) return;
    _checks.remove(result.id)?.cancel();
    _messages.remove(result.id);
    final sources =
        _settings.sources.where((value) => value.id != result.id).toList()
          ..add(result);
    await _save(
      _settings.copyWith(
        sources: sources,
        defaultSourceId: _settings.defaultSourceId.isEmpty ? result.id : null,
      ),
    );
  }

  Future<void> _probe(DanmakuSource source) async {
    _checks.remove(source.id)?.cancel();
    final cancel = DanmakuCancellation();
    _checks[source.id] = cancel;
    setState(() => _messages[source.id] = '正在检测连接与响应格式…');
    try {
      await widget.client.probe(source, cancel);
      if (mounted && !cancel.cancelled)
        setState(() => _messages[source.id] = '连接与搜索格式正常');
    } catch (error) {
      if (mounted && !cancel.cancelled)
        setState(
          () => _messages[source.id] = error is DanmakuApiException
              ? error.message
              : '检测失败，请检查服务',
        );
    } finally {
      if (_checks[source.id] == cancel) _checks.remove(source.id);
    }
  }

  void _delete(DanmakuSource source) {
    _checks.remove(source.id)?.cancel();
    final sources = _settings.sources
        .where((value) => value.id != source.id)
        .toList();
    unawaited(
      _save(
        _settings.copyWith(
          sources: sources,
          defaultSourceId: _settings.defaultSourceId == source.id
              ? sources.firstOrNull?.id ?? ''
              : null,
          matches: Map.fromEntries(
            _settings.matches.entries.where(
              (value) => value.value.sourceId != source.id,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('弹幕 API 管理'),
    content: SizedBox(
      width: 520,
      height: math.min(440, MediaQuery.sizeOf(context).height * .55),
      child: _settings.sources.isEmpty
          ? const Center(
              child: Text(
                '添加你自己的 API\n支持服务根地址、Token 前缀或 /api/v2 地址',
                textAlign: TextAlign.center,
              ),
            )
          : ListView(
              children: [
                for (final source in _settings.sources)
                  Card(
                    elevation: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          title: Text(source.name),
                          subtitle: Text(
                            DanmakuSource.validateUrl(source.baseUrl).host,
                          ),
                          leading: Icon(
                            source.id == _settings.defaultSourceId
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: source.id == _settings.defaultSourceId
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onTap: () => _save(
                            _settings.copyWith(defaultSourceId: source.id),
                          ),
                          trailing: PopupMenuButton<_SourceAction>(
                            tooltip: '管理 ${source.name}',
                            onSelected: (action) {
                              switch (action) {
                                case _SourceAction.probe:
                                  unawaited(_probe(source));
                                case _SourceAction.edit:
                                  unawaited(_edit(source));
                                case _SourceAction.delete:
                                  _delete(source);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: _SourceAction.probe,
                                child: Text('检测连接'),
                              ),
                              PopupMenuItem(
                                value: _SourceAction.edit,
                                child: Text('编辑 API'),
                              ),
                              PopupMenuItem(
                                value: _SourceAction.delete,
                                child: Text('删除 API'),
                              ),
                            ],
                          ),
                        ),
                        if (source.id == _settings.defaultSourceId)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              '默认数据源',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        if (_messages[source.id] != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Text(
                              _messages[source.id]!,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
      FilledButton.icon(
        key: const ValueKey('danmaku-add-api'),
        onPressed: _settings.sources.length < 16 ? () => _edit() : null,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加 API'),
      ),
    ],
  );
  @override
  void dispose() {
    for (final cancel in _checks.values) {
      cancel.cancel();
    }
    super.dispose();
  }
}

class _DanmakuSourceEditor extends StatefulWidget {
  const _DanmakuSourceEditor({this.source});
  final DanmakuSource? source;
  @override
  State<_DanmakuSourceEditor> createState() => _DanmakuSourceEditorState();
}

class _DanmakuSourceEditorState extends State<_DanmakuSourceEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.source?.name ?? '我的弹幕');
  late final _url = TextEditingController(text: widget.source?.baseUrl ?? '');
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.source == null ? '添加弹幕 API' : '编辑弹幕 API'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('danmaku-source-name'),
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('danmaku-source-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 2048,
                decoration: const InputDecoration(
                  labelText: 'API 地址',
                  hintText: 'https://example.com/token/api/v2',
                  helperText: '保留服务要求的 Token 或路径前缀',
                ),
                validator: (value) {
                  try {
                    DanmakuSource.validateUrl(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate())
            Navigator.pop(
              context,
              DanmakuSource(
                id:
                    widget.source?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: _name.text.trim(),
                baseUrl: _url.text.trim(),
              ),
            );
        },
        child: const Text('保存'),
      ),
    ],
  );
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }
}

class _DanmakuSearchDialog extends StatefulWidget {
  const _DanmakuSearchDialog({
    required this.source,
    required this.client,
    required this.keyword,
  });
  final DanmakuSource source;
  final DanmakuService client;
  final String keyword;
  @override
  State<_DanmakuSearchDialog> createState() => _DanmakuSearchDialogState();
}

class _DanmakuSearchDialogState extends State<_DanmakuSearchDialog> {
  late final _input = TextEditingController(text: widget.keyword);
  DanmakuCancellation? _cancel;
  List<DanmakuAnime> _shows = const [];
  List<DanmakuMatch>? _episodes;
  DanmakuAnime? _show;
  bool _busy = false, _searched = false;
  String? _error;
  Future<void> _run(Future<void> Function(DanmakuCancellation) load) async {
    _cancel?.cancel();
    final cancel = DanmakuCancellation();
    _cancel = cancel;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await load(cancel);
    } catch (error) {
      if (mounted && !cancel.cancelled)
        setState(
          () => _error = error is DanmakuApiException
              ? error.message
              : '搜索失败，请重试',
        );
    } finally {
      if (mounted && !cancel.cancelled) setState(() => _busy = false);
    }
  }

  Future<void> _search() async {
    if (_input.text.trim().isEmpty) return;
    setState(() {
      _episodes = null;
      _show = null;
      _shows = const [];
      _searched = true;
    });
    await _run((cancel) async {
      final shows = await widget.client.search(
        widget.source,
        _input.text.trim(),
        cancel,
      );
      if (mounted && !cancel.cancelled) setState(() => _shows = shows);
    });
  }

  Future<void> _open(DanmakuAnime show) => _run((cancel) async {
    final episodes = await widget.client.episodes(widget.source, show, cancel);
    if (mounted && !cancel.cancelled)
      setState(() {
        _show = show;
        _episodes = episodes;
      });
  });
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_show?.title ?? '手动匹配弹幕'),
    content: SizedBox(
      width: 540,
      height: math.min(520, MediaQuery.sizeOf(context).height * .6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    labelText: '搜索作品',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '搜索',
                onPressed: _search,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _episodes != null
                ? _episodes!.isEmpty
                      ? const Center(child: Text('该作品暂无分集'))
                      : ListView.builder(
                          itemCount: _episodes!.length,
                          itemBuilder: (_, index) => ListTile(
                            title: Text(_episodes![index].episodeTitle),
                            leading: const Icon(Icons.playlist_play_rounded),
                            onTap: () =>
                                Navigator.pop(context, _episodes![index]),
                          ),
                        )
                : _shows.isEmpty
                ? Center(
                    child: Text(
                      _busy
                          ? '正在搜索…'
                          : _searched
                          ? '未找到作品，请尝试其他名称'
                          : '输入剧名，选择作品后再选择分集',
                    ),
                  )
                : ListView.builder(
                    itemCount: _shows.length,
                    itemBuilder: (_, index) => ListTile(
                      title: Text(_shows[index].title),
                      subtitle: _shows[index].description.isEmpty
                          ? null
                          : Text(_shows[index].description),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _open(_shows[index]),
                    ),
                  ),
          ),
        ],
      ),
    ),
    actions: [
      if (_episodes != null)
        TextButton(
          onPressed: () => setState(() {
            _episodes = null;
            _show = null;
          }),
          child: const Text('返回作品'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
  @override
  void dispose() {
    _cancel?.cancel();
    _input.dispose();
    super.dispose();
  }
}
