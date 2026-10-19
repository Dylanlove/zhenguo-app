import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_notice.dart';
import 'ysp_live.dart';

class YspSettingsScreen extends StatefulWidget {
  const YspSettingsScreen({super.key, required this.client});

  final YspLiveClient client;

  @override
  State<YspSettingsScreen> createState() => _YspSettingsScreenState();
}

class _YspSettingsScreenState extends State<YspSettingsScreen> {
  Map<String, dynamic>? _status;
  String? _error;
  bool _busy = false;
  final _port = TextEditingController(text: '8767');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Map get _settings => _status?['settings'] as Map? ?? const {};

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.client.status();
      if (!mounted) return;
      setState(() {
        _status = result;
        _port.text = '${(result['settings'] as Map?)?['port'] ?? 8767}';
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({String? quality, bool? share}) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      AppNotice.show(context, '端口须为 1024–65535');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.client.configure(
        quality: quality ?? _settings['quality'] as String? ?? 'auto',
        share: share ?? _settings['share'] == true,
        port: port,
      );
      if (mounted) setState(() => _status = result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) AppNotice.show(context, '已复制');
  }

  Future<void> _copyRules(bool module) async {
    try {
      final result = await widget.client.rules();
      await _copy(result[module ? 'module' : 'list'] as String? ?? '');
    } catch (error) {
      if (mounted) AppNotice.show(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final addresses = (status?['subscriptions'] as List? ?? const [])
        .whereType<String>();
    final playing = (status?['playing'] as List? ?? const []).whereType<Map>();
    final events = (status?['events'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('央视频 · 分享与诊断'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(_error!),
                  trailing: TextButton(
                    onPressed: _busy ? null : _refresh,
                    child: const Text('重试'),
                  ),
                ),
              const ListTile(
                leading: Icon(Icons.live_tv),
                title: Text('YSP Live 9.5'),
                subtitle: Text('64 路频道 · 四层取流兜底 · 高清 / 4K · 7 天回看'),
              ),
              if (status != null) ...[
                ListTile(
                  title: const Text('订阅默认画质'),
                  trailing: DropdownButton<String>(
                    value: _settings['quality'] as String? ?? 'auto',
                    items: [
                      for (final quality in const ['auto', 'best', 'hd'])
                        DropdownMenuItem(
                          value: quality,
                          child: Text(yspQualityLabel(quality)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) _save(quality: value);
                          },
                  ),
                ),
                SwitchListTile.adaptive(
                  title: const Text('局域网订阅分享'),
                  subtitle: const Text(
                    '开启后，同一局域网的其他播放器可访问此设备的电视直播订阅。请保持 App 运行。',
                  ),
                  value: _settings['share'] == true,
                  onChanged: _busy ? null : (value) => _save(share: value),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _port,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '服务端口'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: _busy ? null : () => _save(),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ),
                const ListTile(
                  subtitle: Text('改变分享范围或端口会重启直播服务，返回播放页后可重新打开当前频道。'),
                ),
                for (final address in addresses)
                  ListTile(
                    leading: const Icon(Icons.playlist_play),
                    title: SelectableText(address),
                    trailing: IconButton(
                      tooltip: '复制订阅地址',
                      onPressed: () => _copy(address),
                      icon: const Icon(Icons.copy),
                    ),
                  ),
                const Divider(),
                ListTile(
                  title: const Text('运行状态'),
                  subtitle: Text(
                    '频道 ${status['channels']} · 运行 ${status['uptimeSeconds']} 秒\n'
                    '${status['deviceBusy'] == true ? '设备协议处理中' : '设备连接 ${status['deviceLinks']} / 6 · 心跳 ${status['heartbeatCount']}'}\n'
                    '分片缓存 ${((status['segmentCacheBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB',
                  ),
                ),
                for (final row in playing)
                  ListTile(
                    title: Text('${row['name']} · ${row['quality'] ?? ''}'),
                    subtitle: Text(
                      '${row['engine'] ?? ''}'
                      '${row['catchup'] == true ? ' · 回看' : ''}'
                      '${row['upgrading'] == true ? ' · 正在尝试高码率' : ''}'
                      '${row['lastError'] == '' ? '' : '\n${row['lastError'] ?? ''}'}',
                    ),
                  ),
                ExpansionTile(
                  title: const Text('诊断记录'),
                  children: [
                    if (events.isEmpty) const ListTile(title: Text('暂无异常记录')),
                    for (final event in events.reversed)
                      ListTile(
                        dense: true,
                        title: Text('${event['time']} · ${event['channel']}'),
                        subtitle: SelectableText('${event['message']}'),
                      ),
                  ],
                ),
              ],
              const Divider(),
              const ListTile(
                title: Text('代理工具分流规则'),
                subtitle: Text('原包的直连规则可复制到支持规则集或模块的代理工具，适用于部分网络下的分片 403 问题。'),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copyRules(false),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制通用规则集'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _copyRules(true),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制小火箭模块'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('YSP Live 原作：Gary’s Club。央视频取流在本设备完成。'),
            ],
          ),
        ),
      ),
    );
  }
}
