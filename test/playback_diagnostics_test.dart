import 'dart:convert';

import 'package:duanju_app/playback_diagnostics.dart';
import 'package:duanju_app/source_status.dart';
import 'package:duanju_app/player_menu.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('清晰度面板可直接打开播放诊断报告', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerMenu(
            section: PlayerMenuSection.quality,
            episodes: const [],
            currentIndex: 0,
            preferences: const PlaybackPreferences(),
            qualities: const [720],
            actualQuality: 720,
            local: false,
            favorite: false,
            mobile: true,
            onEpisode: (_) {},
            onPreferences: (_) async {},
            onFavorite: () async {},
            onDiagnostics: () => opened = true,
          ),
        ),
      ),
    );
    final report = find.byKey(const ValueKey('player-diagnostics'));
    expect(report, findsOneWidget);
    await tester.ensureVisible(report);
    await tester.tap(report);
    expect(opened, isTrue);
  });

  test('诊断隐藏地址、整行 Cookie、鉴权字段和内容密钥', () {
    final text = diagnosticText(
      'https://media.example.test/video?token=url-secret\nCookie: first=cookie-secret; second=other-secret\nBearer bearer-secret\ndecryption_key=0123456789abcdef0123456789abcdef device_id=7345678901234567890',
      limit: 2000,
    );
    for (final secret in [
      'media.example.test',
      'url-secret',
      'cookie-secret',
      'other-secret',
      'bearer-secret',
      '0123456789abcdef0123456789abcdef',
      '7345678901234567890',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('切换用户清理旧记录并拒绝旧播放会话的迟到事件', () {
    final log = PlaybackDiagnostics();
    addTearDown(log.dispose);
    final old = log.begin('first:0');
    log.record(owner: 'first:0', trace: old, source: 'hongguo', stage: '打开媒体');
    log.begin('second:1');
    log.record(owner: 'first:0', trace: old, source: 'hongguo', stage: '迟到错误');
    expect(log.events('first:0', 'hongguo'), isEmpty);
    expect(log.events('second:1', 'hongguo'), isEmpty);
  });

  test('没有检测记录的报告保持尚未检测', () {
    final report = DiagnosticReport(
      version: 'test',
      source: 'hongguo',
      sourceName: '合成源',
      fingerprint: '0123456789abcdef',
      events: const [],
    );
    expect(report.text, contains('尚未检测'));
    expect(jsonDecode(report.qrText)['health'], 'not_run');
  });

  test('二维码按字节限长且排除播放错误原文', () {
    final events = List.generate(
      120,
      (index) => PlaybackDiagnosticEvent(
        at: DateTime.utc(2026, 10, 20),
        source: 'hongguo',
        trace: 'test',
        stage: '播放恢复${List.filled(24, '阶段').join()}',
        state: 'failed',
        episode: index,
        route: 1,
        elapsedMs: 900,
        message: 'private-message-secret',
        code: 'MEDIA',
      ),
    );
    final report = DiagnosticReport(
      version: 'test',
      source: 'hongguo',
      sourceName: '合成源',
      fingerprint: '0123456789abcdef',
      events: events,
    );
    expect(utf8.encode(report.qrText).length, lessThanOrEqualTo(1800));
    expect(
      (jsonDecode(report.qrText)['recent'] as List).length,
      lessThanOrEqualTo(8),
    );
    expect(report.qrText, isNot(contains('private-message-secret')));
  });

  test('HTTP 403 与 TLS 失败提供不同的建议', () {
    final health = SourceStatus.fromJson({
      'health': {
        'state': 'failed',
        'steps': [
          {
            'name': '播放列表',
            'state': 'failed',
            'message': '访问失败',
            'httpStatus': 403,
            'code': 'HTTP_403',
          },
        ],
      },
    });
    final report = DiagnosticReport(
      version: 'test',
      source: 'hongguo',
      sourceName: '合成源',
      fingerprint: '0123456789abcdef',
      events: const [],
      status: health,
    );
    expect(report.text, contains('HTTP 403'));
    expect(report.text, isNot(contains('证书校验不通过')));
    expect(
      DiagnosticIssue.classify('handshake terminated', code: 'TLS').advice,
      contains('网络中断'),
    );
  });
}
