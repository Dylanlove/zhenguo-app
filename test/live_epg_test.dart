import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duanju_app/live_epg.dart';
import 'package:duanju_app/live_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = LiveChannel(
  key: 'ysp-cctv2',
  name: 'CCTV-2 财经',
  urls: ['ysp://cctv2'],
  source: 'ysp',
  token: 'cctv2',
  tvgId: 'CCTV2',
  catchup: true,
);

const _xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="CCTV2"><display-name>CCTV-2 财经</display-name><icon src="https://images.invalid/logo.jpg"/></channel>
  <channel id="CCTV12"><display-name>CCTV-12 社会与法</display-name></channel>
  <programme channel="CCTV2" start="20261018234000 +0800" stop="20261019002500 +0800"><title>跨日节目</title></programme>
  <programme channel="CCTV2" start="20261019090000 +0800" stop="20261019100000 +0800"><title>交易 &amp; 时间</title></programme>
  <programme channel="CCTV2" start="20261019090000 +0800" stop="20261019100000 +0800"><title>交易 &amp; 时间</title></programme>
  <programme channel="CCTV2" start="20261019100000 +0800"><title>待补结束</title></programme>
  <programme channel="CCTV2" start="20261019103000 +0800" stop="20261019110000 +0800"><title>经济半小时</title></programme>
  <programme channel="CCTV2" start="20261019110000 +0800"><title>最后一条</title></programme>
  <programme channel="CCTV2" start="20261319090000 +0800" stop="20261319100000 +0800"><title>无效日期</title></programme>
  <programme channel="CCTV12" start="20261019090000 +0800" stop="20261019100000 +0800"><title>不能串台</title></programme>
</tv>
''';

Uint8List _bytes(String value, {bool compressed = false}) => Uint8List.fromList(
  compressed ? gzip.encode(utf8.encode(value)) : utf8.encode(value),
);

void main() {
  test('XMLTV 时区按偏移转换，缺省时区遵循 UTC', () {
    final expected = DateTime.utc(2026, 10, 19, 1, 59);
    expect(parseXmltvTime('20261019095900 +0800'), expected);
    expect(parseXmltvTime('20261019015900 +0000'), expected);
    expect(parseXmltvTime('20261018185900 -0700'), expected);
    expect(parseXmltvTime('202610190159'), expected);
    expect(parseXmltvTime('20261019015900Z'), expected);
    expect(parseXmltvTime('20260230015900 +0000'), isNull);
    expect(parseXmltvTime('20261019245900 +0800'), isNull);
    expect(parseXmltvTime('20261019015900 +2460'), isNull);
    expect(liveEpgClock(expected), '09:59');
  });

  test('支持压缩节目单、跨日、去重、实体和缺少结束时间', () {
    final snapshot = parseLiveXmltv(_bytes(_xml, compressed: true));
    final items = snapshot.forChannel(_channel, DateTime.utc(2026, 10, 19));
    expect(items.map((item) => item.title), [
      '跨日节目',
      '交易 & 时间',
      '待补结束',
      '经济半小时',
      '最后一条',
    ]);
    expect(items[0].duration, const Duration(minutes: 45));
    expect(items[2].end, items[3].start);
    expect(items.last.end, isNull);
    expect(snapshot.forChannel(_channel, DateTime.utc(2026, 10, 20)), isEmpty);
  });

  test('频道匹配保留编号和 4K 区别，兼容数字 ID 和别名', () {
    expect(normalizeLiveEpgName('CCTV-5 PLUS 体育赛事'), 'CCTV5+');
    expect(normalizeLiveEpgName('cctv5p'), 'CCTV5+');
    expect(
      normalizeLiveEpgName('CCTV-16 4K'),
      isNot(normalizeLiveEpgName('CCTV16')),
    );
    final snapshot = parseLiveXmltv(
      _bytes('''
<tv>
  <channel id="short"><display-name>CCTV2</display-name></channel>
  <channel id="full"><display-name>CCTV-2 财经</display-name></channel>
  <channel id="other"><display-name>CCTV12</display-name></channel>
  <programme channel="short" start="20261019090000 +0800" stop="20261019100000 +0800"><title>短覆盖</title></programme>
  <programme channel="full" start="20261019080000 +0800" stop="20261019110000 +0800"><title>完整覆盖</title></programme>
  <programme channel="other" start="20261019000000 +0800" stop="20261020000000 +0800"><title>不能串台</title></programme>
</tv>
'''),
    );
    expect(
      snapshot.forChannel(_channel, DateTime.utc(2026, 10, 19)).single.title,
      '完整覆盖',
    );
  });

  test('未来、正在播出、已播出、过期及结束未知分别判断', () {
    final now = DateTime.utc(2026, 10, 19, 2, 59);
    final items = parseLiveXmltv(
      _bytes(_xml),
    ).forChannel(_channel, liveEpgDate(now));
    expect(
      items[1].stateAt(now, supportsCatchup: true),
      LiveProgrammeState.replay,
    );
    expect(
      items[3].stateAt(now, supportsCatchup: true),
      LiveProgrammeState.live,
    );
    expect(
      items.last.stateAt(now, supportsCatchup: true),
      LiveProgrammeState.upcoming,
    );
    expect(
      items.last.stateAt(
        now.add(const Duration(hours: 2)),
        supportsCatchup: true,
      ),
      LiveProgrammeState.unavailable,
    );
    expect(
      items[1].stateAt(now, supportsCatchup: false),
      LiveProgrammeState.unavailable,
    );
    expect(
      items[1].stateAt(now.add(const Duration(days: 7)), supportsCatchup: true),
      LiveProgrammeState.expired,
    );
  });

  test('主源格式错误时使用备用源，并合并并发下载', () async {
    final root = await Directory.systemTemp.createTemp('live-epg-');
    addTearDown(() => root.delete(recursive: true));
    final gate = Completer<void>();
    final calls = <String, int>{};
    final repository = LiveEpgRepository(
      cacheDirectory: () async => root,
      load: (url) async {
        calls[url] = (calls[url] ?? 0) + 1;
        await gate.future;
        return _bytes(
          url == liveEpgSources.first.url ? '<html>invalid</html>' : _xml,
        );
      },
    );
    addTearDown(repository.dispose);
    final first = repository.programmes(_channel, DateTime.utc(2026, 10, 19));
    final second = repository.programmes(_channel, DateTime.utc(2026, 10, 19));
    gate.complete();
    final results = await Future.wait([first, second]);
    expect(
      results.every(
        (item) => item.source == 'EPG.PW' && item.items.length == 5,
      ),
      isTrue,
    );
    expect(calls.values, everyElement(1));
  });

  test('重启读取本地缓存，断网可继续使用过期缓存', () async {
    final root = await Directory.systemTemp.createTemp('live-epg-');
    addTearDown(() => root.delete(recursive: true));
    final first = LiveEpgRepository(
      cacheDirectory: () async => root,
      load: (_) async => _bytes(_xml),
    );
    await first.programmes(_channel, DateTime.utc(2026, 10, 19));
    first.dispose();
    var calls = 0;
    Future<Uint8List> offline(String _) async {
      calls++;
      throw const SocketException('offline');
    }

    final fresh = LiveEpgRepository(
      cacheDirectory: () async => root,
      load: offline,
    );
    final restored = await fresh.programmes(
      _channel,
      DateTime.utc(2026, 10, 19),
    );
    expect(restored.stale, isFalse);
    expect(calls, 0);
    fresh.dispose();
    await for (final file in Directory('${root.path}/live_epg').list()) {
      if (file is File)
        await file.setLastModified(
          DateTime.now().subtract(const Duration(hours: 8)),
        );
    }
    final stale = LiveEpgRepository(
      cacheDirectory: () async => root,
      load: offline,
    );
    addTearDown(stale.dispose);
    final cached = await stale.programmes(_channel, DateTime.utc(2026, 10, 19));
    expect(cached.stale, isTrue);
    expect(cached.items, hasLength(5));
    expect(calls, 2);
  });
}
