import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'source_status.dart';

String diagnosticText(Object? value, {int limit = 240}) {
  final safe = '$value'
      .replaceAllMapped(
        RegExp(
          r'\b(authorization|cookie|set-cookie)\s*:\s*[^\r\n]*',
          caseSensitive: false,
        ),
        (match) => '${match[1]}=<redacted>',
      )
      .replaceAll(
        RegExp(
          r'''(?:https?|socks5h?|file)://[^\s<>"']+''',
          caseSensitive: false,
        ),
        '<url>',
      )
      .replaceAll(
        RegExp(r'Bearer\s+\S+', caseSensitive: false),
        'Bearer <redacted>',
      )
      .replaceAllMapped(
        RegExp(
          r'''\b(authorization|cookie|set-cookie|token|access_token|refresh_token|device_token|client_secret|password|pin|aesKey|interfaceKey|paramKey|paramIV|key|decryption_key|decryptionKey|contentKey|device_id|install_id|iid|x-gorgon|x-medusa)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;}]+)''',
          caseSensitive: false,
        ),
        (match) => '${match[1]}=<redacted>',
      )
      .replaceAll(RegExp(r'\b[0-9a-fA-F]{32,}\b'), '<redacted>')
      .replaceAll(RegExp(r'\b\d{15,}\b'), '<id>')
      .replaceAll(RegExp(r'''[A-Za-z]:[\\/][^\r\n"']+'''), '<path>')
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .trim();
  return String.fromCharCodes(safe.runes.take(limit));
}

class DiagnosticIssue {
  const DiagnosticIssue(this.code, this.label, this.advice);

  final String code;
  final String label;
  final String advice;

  static DiagnosticIssue classify(
    Object? error, {
    String code = '',
    int status = 0,
  }) {
    final message = '$error'.toLowerCase();
    if (error is TimeoutException ||
        code == 'TIMEOUT' ||
        message.contains('timed out') ||
        message.contains('超时')) {
      return const DiagnosticIssue(
        'TIMEOUT',
        '请求超时',
        '稍后重试，可对照其他网络；请保留失败阶段与耗时。',
      );
    }
    if (code == 'CANCELLED' ||
        message.contains('cancelled') ||
        message.contains('已取消')) {
      return const DiagnosticIssue('CANCELLED', '操作已取消', '如需继续，请重新发起操作。');
    }
    if (code == 'DNS' ||
        message.contains('host lookup') ||
        message.contains('no such host')) {
      return const DiagnosticIssue('DNS', '域名解析失败', '检查网络、DNS 与代理规则，可用其他网络对照。');
    }
    if (error is HandshakeException ||
        error is TlsException ||
        code == 'TLS' ||
        message.contains('handshake') ||
        message.contains('certificate') ||
        message.contains('tls')) {
      return const DiagnosticIssue(
        'TLS',
        '安全连接失败',
        '检查设备时间与代理证书；握手失败也可能由服务器或网络中断引起。',
      );
    }
    if (status > 0 && (status < 200 || status >= 300)) {
      return DiagnosticIssue('HTTP_$status', 'HTTP $status', switch (status) {
        403 => '服务器拒绝访问，请保留报告，稍后或换网络对照。',
        429 => '请求受到限流，请等待冷却后重试。',
        404 => '接口或资源不存在，请更新资料或重新解析。',
        _ => '服务器返回异常状态，请结合失败阶段重试。',
      });
    }
    if (code.startsWith('HTTP_')) {
      final status = int.tryParse(code.substring(5)) ?? 0;
      if (status > 0) return classify(error, status: status);
    }
    if (error is SocketException ||
        code == 'CONNECTION' ||
        message.contains('connection refused') ||
        message.contains('connection reset')) {
      return const DiagnosticIssue(
        'CONNECTION',
        '连接中断',
        '检查网络与代理，稍后重试或切换网络对照。',
      );
    }
    if (code == 'DATA' || error is FormatException) {
      return const DiagnosticIssue(
        'DATA',
        '返回数据异常',
        '接口数据未符合预期，请保留报告，不要反复快速重试。',
      );
    }
    if (code == 'BUSINESS') {
      return const DiagnosticIssue(
        'BUSINESS',
        '源站业务拒绝',
        '源站未允许当前操作，请保留错误说明并稍后重试；权限或试看限制不会因重试自动解除。',
      );
    }
    if (code == 'source_blocked') {
      return const DiagnosticIssue(
        'source_blocked',
        '源站访问受限',
        '等待站源冷却后重试，并保留报告中的失败阶段。',
      );
    }
    if (code == 'local_media') {
      return const DiagnosticIssue(
        'local_media',
        '本地媒体不可用',
        '检查下载文件和存储权限，必要时重新下载或选择在线播放。',
      );
    }
    if (code == 'STALL') {
      return const DiagnosticIssue('STALL', '播放进度停滞', '可尝试备用线路或降低清晰度，并反馈播放记录。');
    }
    if (code == 'MEDIA') {
      return const DiagnosticIssue(
        'MEDIA',
        '媒体播放失败',
        '请结合播放记录与站源检测区分网络、格式及解码问题。',
      );
    }
    return const DiagnosticIssue('SOURCE', '操作失败', '请保留失败阶段、错误说明与播放记录后反馈。');
  }
}

class PlaybackDiagnosticEvent {
  const PlaybackDiagnosticEvent({
    required this.at,
    required this.source,
    required this.trace,
    required this.stage,
    required this.state,
    required this.episode,
    required this.route,
    required this.elapsedMs,
    required this.message,
    required this.code,
  });

  final DateTime at;
  final String source, trace, stage, state, message, code;
  final int episode, route, elapsedMs;

  Map<String, Object> get summary => {
    'stage': stage,
    'state': state,
    'episode': episode,
    'route': route,
    'ms': elapsedMs,
    if (code.isNotEmpty) 'code': code,
  };
}

class PlaybackDiagnostics extends ChangeNotifier {
  static const limit = 120;
  final List<PlaybackDiagnosticEvent> _events = [];
  String _owner = '';
  int _sequence = 0;

  String begin(String owner) {
    if (_owner != owner) {
      _owner = owner;
      _events.clear();
    }
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${++_sequence}';
  }

  void record({
    required String owner,
    required String trace,
    required String source,
    required String stage,
    String state = 'info',
    int episode = 0,
    int route = 0,
    int elapsedMs = 0,
    String message = '',
    String code = '',
  }) {
    if (_owner != owner) return;
    final safeCode = String.fromCharCodes(
      code.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '').runes.take(48),
    );
    _events.add(
      PlaybackDiagnosticEvent(
        at: DateTime.now().toUtc(),
        source: source,
        trace: trace,
        stage: diagnosticText(stage, limit: 48),
        state: state,
        episode: episode,
        route: route,
        elapsedMs: elapsedMs,
        message: diagnosticText(message),
        code: safeCode,
      ),
    );
    if (_events.length > limit) _events.removeRange(0, _events.length - limit);
    notifyListeners();
  }

  List<PlaybackDiagnosticEvent> events(String owner, String source) =>
      _owner == owner
      ? List.unmodifiable(_events.where((event) => event.source == source))
      : const [];
}

class DiagnosticReport {
  DiagnosticReport({
    required this.version,
    required this.source,
    required this.sourceName,
    required this.fingerprint,
    required this.events,
    this.status,
  }) : createdAt = DateTime.now().toUtc();

  final String version, source, sourceName, fingerprint;
  final DateTime createdAt;
  final SourceStatus? status;
  final List<PlaybackDiagnosticEvent> events;

  String get text {
    final result = StringBuffer('诊断报告\n');
    result.writeln(
      '应用 $version · ${Platform.operatingSystem} ${diagnosticText(Platform.operatingSystemVersion)}',
    );
    result.writeln('站源 $sourceName ($source) · 适配指纹 $fingerprint');
    result.writeln('生成时间 ${createdAt.toIso8601String()}');
    final health = status?.health;
    if (status != null)
      result.writeln('缓存 ${status!.count} 部 · 已加载第 ${status!.page} 页');
    result.writeln('站源检测：${health?.label ?? '尚未检测'}');
    if (health?.checkedAt != null)
      result.writeln('检测时间 ${health!.checkedAt!.toUtc().toIso8601String()}');
    result.writeln('连接检测不代表已完成实际播放与解码验收。');
    for (final step in health?.steps ?? <SourceHealthStep>[]) {
      result.writeln('\n${step.name} · ${step.state} · ${step.elapsedMs} ms');
      if (step.host.isNotEmpty)
        result.writeln('主机 ${diagnosticText(step.host)}');
      if (step.httpStatus > 0) result.writeln('HTTP ${step.httpStatus}');
      if (RegExp(r'^[0-9a-fA-F]{16,32}-[A-Z]{3}$').hasMatch(step.cfRay))
        result.writeln('CF Ray ${step.cfRay}');
      result.writeln(diagnosticText(step.message));
      if (step.state == 'failed') {
        final issue = DiagnosticIssue.classify(
          step.message,
          code: step.code,
          status: step.httpStatus,
        );
        result.writeln('${issue.label} (${issue.code}) · ${issue.advice}');
      }
    }
    if (status?.error.isNotEmpty == true)
      result.writeln('\n任务：${diagnosticText(status!.error)}');
    if (status?.storageError.isNotEmpty == true)
      result.writeln('保存：${diagnosticText(status!.storageError)}');
    result.writeln('\n播放记录（${events.length} 条）');
    if (events.isEmpty) result.writeln('暂无当前用户在此站源的播放记录。');
    for (final event in events) {
      result.writeln(
        '${event.at.toIso8601String()} [${event.trace}] ${event.stage} · ${event.state} · 第 ${event.episode} 集 · 线路 ${event.route} · ${event.elapsedMs} ms',
      );
      if (event.message.isNotEmpty) result.writeln(event.message);
      if (event.code.isNotEmpty) {
        final issue = DiagnosticIssue.classify(event.message, code: event.code);
        result.writeln('${event.code} · ${issue.advice}');
      }
    }
    result.writeln('\n播放记录仅保存在当前进程中。报告已过滤媒体地址、常见鉴权字段及内容密钥；复制或扫码后由你手动反馈。');
    return result.toString();
  }

  String get qrText {
    final recent = <Map<String, Object>>[
      for (final step in status?.health?.steps ?? <SourceHealthStep>[])
        {
          'stage': diagnosticText(step.name, limit: 24),
          'state': step.state,
          'http': step.httpStatus,
          'ms': step.elapsedMs,
          if (step.state == 'failed')
            'code': DiagnosticIssue.classify(
              step.message,
              code: step.code,
              status: step.httpStatus,
            ).code,
        },
      for (final event in events) event.summary,
    ];
    if (recent.length > 8) recent.removeRange(0, recent.length - 8);
    while (true) {
      final data = jsonEncode({
        'app': 'guoapp',
        'version': version,
        'os': Platform.operatingSystem,
        'source': source,
        'adapter': fingerprint,
        'at': createdAt.toIso8601String(),
        'health': status?.health?.state ?? 'not_run',
        'recent': recent,
      });
      if (utf8.encode(data).length <= 1800 || recent.isEmpty) return data;
      recent.removeAt(0);
    }
  }
}
