import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'local_store.dart';
import 'playback_diagnostics.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.store,
    required this.report,
    required this.profileEpoch,
  });

  final LocalStore store;
  final DiagnosticReport report;
  final int profileEpoch;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _qr = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    ensureTelevisionFocus(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _qr = AppLayout.isTelevision(context);
      _initialized = true;
    }
  }

  bool get _allowed =>
      widget.store.profileEpoch == widget.profileEpoch &&
      !widget.store.locked &&
      widget.store.allowsSource(widget.report.source);

  Future<void> _copy() async {
    if (!_allowed) return;
    await Clipboard.setData(ClipboardData(text: widget.report.text));
    if (mounted && _allowed) AppNotice.show(context, '诊断报告已复制');
  }

  Widget _qrImage(double size) => QrImageView(
    data: widget.report.qrText,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.L,
    size: size,
    backgroundColor: Colors.white,
    padding: const EdgeInsets.all(24),
    semanticsLabel: '脱敏诊断摘要二维码',
    errorStateBuilder: (_, _) => const Padding(
      padding: EdgeInsets.all(24),
      child: Text('二维码暂时无法显示，请复制完整报告。'),
    ),
  );

  Widget _qrPanel() => LayoutBuilder(
    builder: (context, constraints) {
      const explanation = Text(
        '仅包含版本、站源、检测与目录扫描状态和最多最近 8 条简要记录，不含媒体地址或鉴权信息。扫码后由你手动反馈。',
        textAlign: TextAlign.center,
      );
      if (constraints.maxWidth >= 640) {
        final size = math
            .min(
              500.0,
              math.min(
                constraints.maxWidth * .6 - 32,
                constraints.maxHeight - 32,
              ),
            )
            .clamp(1.0, 500.0)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _qrImage(size),
              const SizedBox(width: 24),
              const Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('使用手机扫码读取诊断摘要', textAlign: TextAlign.center),
                      SizedBox(height: 16),
                      explanation,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
      final size = math
          .min(constraints.maxWidth - 32, constraints.maxHeight - 140)
          .clamp(100.0, 500.0)
          .toDouble();
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('使用手机扫码读取诊断摘要', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Center(child: _qrImage(size)),
            const SizedBox(height: 16),
            explanation,
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('诊断报告'),
          actions: [
            if (_allowed)
              IconButton(
                tooltip: '复制报告',
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded),
              ),
          ],
        ),
        body: !_allowed
            ? const StatusPanel(
                title: '报告已锁定',
                message: '当前用户或站源权限已变化，请返回重新打开报告。',
                icon: Icons.lock_outline,
              )
            : SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                autofocus: AppLayout.isTelevision(context),
                                onPressed: () => setState(() => _qr = !_qr),
                                icon: Icon(
                                  _qr
                                      ? Icons.description_outlined
                                      : Icons.qr_code_rounded,
                                ),
                                label: Text(_qr ? '查看完整报告' : '扫码获取摘要'),
                              ),
                              TextButton.icon(
                                onPressed: _copy,
                                icon: const Icon(Icons.copy_rounded),
                                label: const Text('复制完整报告'),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _qr
                              ? _qrPanel()
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.all(20),
                                  child: SelectableText(widget.report.text),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    ),
  );
}
