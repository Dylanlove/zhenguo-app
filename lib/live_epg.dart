import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'core_bridge.dart';
import 'live_models.dart';

const liveEpgSources = [
  (name: 'EPG', url: 'https://epg.zsdc.eu.org/t.xml.gz'),
  (name: 'EPG.PW', url: 'https://epg.pw/xmltv/epg_CN.xml.gz'),
];

DateTime liveEpgTime(DateTime value) =>
    value.toUtc().add(const Duration(hours: 8));

DateTime liveEpgDate(DateTime value) {
  final local = liveEpgTime(value);
  return DateTime.utc(local.year, local.month, local.day);
}

String liveEpgClock(DateTime value) {
  final local = liveEpgTime(value);
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

DateTime? parseXmltvTime(String? value) {
  final matched = RegExp(
    r'^(\d{12}|\d{14})(?:\s*([+-])(\d{2})(\d{2})|\s*Z)?$',
  ).firstMatch(value?.trim() ?? '');
  if (matched == null) return null;
  final digits = matched[1]!;
  final year = int.parse(digits.substring(0, 4));
  final month = int.parse(digits.substring(4, 6));
  final day = int.parse(digits.substring(6, 8));
  final hour = int.parse(digits.substring(8, 10));
  final minute = int.parse(digits.substring(10, 12));
  final second = digits.length == 14 ? int.parse(digits.substring(12, 14)) : 0;
  final result = DateTime.utc(year, month, day, hour, minute, second);
  if (result.year != year ||
      result.month != month ||
      result.day != day ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  final offsetHours = int.parse(matched[3] ?? '0');
  final offsetMinutes = int.parse(matched[4] ?? '0');
  if (offsetHours > 23 || offsetMinutes > 59) return null;
  final offset = Duration(hours: offsetHours, minutes: offsetMinutes);
  return matched[2] == '-' ? result.add(offset) : result.subtract(offset);
}

String normalizeLiveEpgName(String value) {
  var name = value.toUpperCase().replaceAll('＋', '+');
  name = name.replaceAll(RegExp(r'[\s\-_（）()]'), '');
  name = name.replaceAll('中央电视台', 'CCTV').replaceAll('央视', 'CCTV');
  final cctv = RegExp(r'^CCTV\d+(?:PLUS|P|\+)?K?').firstMatch(name);
  if (cctv != null) {
    return cctv[0]!.replaceAll('PLUS', '+').replaceAll(RegExp(r'P$'), '+');
  }
  return name.replaceAll(RegExp(r'高清|频道|HD$'), '');
}

class LiveEpgSnapshot {
  const LiveEpgSnapshot({required this.names, required this.programmes});

  final Map<String, List<String>> names;
  final Map<String, List<LiveProgramme>> programmes;

  List<LiveProgramme> forChannel(LiveChannel channel, DateTime date) {
    final keys = {
      for (final name in [channel.tvgId, channel.name, channel.token])
        if (name.isNotEmpty) normalizeLiveEpgName(name),
    };
    final from = DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).subtract(const Duration(hours: 8));
    final until = from.add(const Duration(days: 1));
    List<LiveProgramme> best = const [];
    var bestCoverage = -1;
    for (final entry in programmes.entries) {
      final aliases = [entry.key, ...?names[entry.key]];
      if (!aliases.any((name) => keys.contains(normalizeLiveEpgName(name)))) {
        continue;
      }
      final items = entry.value
          .where(
            (item) =>
                item.start.isBefore(until) &&
                (item.end?.isAfter(from) ?? !item.start.isBefore(from)),
          )
          .toList(growable: false);
      if (items.isEmpty) continue;
      if (normalizeLiveEpgName(entry.key) ==
          normalizeLiveEpgName(channel.tvgId)) {
        return items;
      }
      var coverage = 0;
      var coveredUntil = from;
      for (final item in items) {
        final begin = item.start.isAfter(coveredUntil)
            ? item.start
            : coveredUntil;
        final stop = item.end;
        if (stop == null) continue;
        final finish = stop.isBefore(until) ? stop : until;
        if (finish.isAfter(begin)) {
          coverage += finish.difference(begin).inSeconds;
          coveredUntil = finish;
        }
      }
      if (coverage > bestCoverage) {
        best = items;
        bestCoverage = coverage;
      }
    }
    return best;
  }
}

LiveEpgSnapshot parseLiveXmltv(Uint8List bytes) {
  final raw = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
      ? gzip.decode(bytes)
      : bytes;
  if (raw.length > 32 << 20) throw const FormatException('节目单数据过大');
  final document = XmlDocument.parse(utf8.decode(raw));
  if (document.rootElement.name.local != 'tv') {
    throw const FormatException('节目单格式无效');
  }
  final names = <String, List<String>>{};
  for (final element in document.rootElement.findElements('channel')) {
    final id = element.getAttribute('id')?.trim() ?? '';
    if (id.isEmpty) continue;
    names[id] = [
      for (final name in element.findElements('display-name')) name.innerText,
    ];
  }
  final grouped = <String, List<LiveProgramme>>{};
  final unique = <String>{};
  for (final element in document.rootElement.findElements('programme')) {
    final id = element.getAttribute('channel')?.trim() ?? '';
    final start = parseXmltvTime(element.getAttribute('start'));
    final rawEnd = element.getAttribute('stop');
    final end = parseXmltvTime(rawEnd);
    final title = element.getElement('title')?.innerText.trim() ?? '';
    if (id.isEmpty ||
        start == null ||
        title.isEmpty ||
        (rawEnd != null && rawEnd.isNotEmpty && end == null) ||
        (end != null && !end.isAfter(start))) {
      continue;
    }
    final item = LiveProgramme(
      channelId: id,
      title: title,
      start: start,
      end: end,
    );
    if (unique.add('${item.key}:${end?.millisecondsSinceEpoch}')) {
      grouped.putIfAbsent(id, () => []).add(item);
    }
  }
  for (final items in grouped.values) {
    items.sort((a, b) => a.start.compareTo(b.start));
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item.end != null) continue;
      for (var next = index + 1; next < items.length; next++) {
        if (items[next].start.isAfter(item.start)) {
          items[index] = LiveProgramme(
            channelId: item.channelId,
            title: item.title,
            start: item.start,
            end: items[next].start,
          );
          break;
        }
      }
    }
  }
  return LiveEpgSnapshot(names: names, programmes: grouped);
}

class LiveEpgSchedule {
  const LiveEpgSchedule({
    required this.items,
    required this.source,
    required this.updated,
    this.stale = false,
  });

  final List<LiveProgramme> items;
  final String source;
  final DateTime updated;
  final bool stale;
}

class _CachedEpg {
  const _CachedEpg(this.snapshot, this.updated);
  final LiveEpgSnapshot snapshot;
  final DateTime updated;
}

class LiveEpgRepository {
  LiveEpgRepository({
    Future<Uint8List> Function(String)? load,
    Future<Directory> Function()? cacheDirectory,
  }) : _load = load,
       _cacheDirectory = cacheDirectory ?? getApplicationSupportDirectory;

  final Future<Uint8List> Function(String)? _load;
  final Future<Directory> Function() _cacheDirectory;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final _memory = <String, _CachedEpg>{};
  final _inflight = <String, Future<_CachedEpg>>{};
  final _failed = <String, DateTime>{};
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _client.close(force: true);
  }

  Future<File> _cacheFile(String url) async => File(
    path.join(
      (await _cacheDirectory()).path,
      'live_epg',
      '${sha256.convert(utf8.encode(url))}.xml',
    ),
  );

  Future<_CachedEpg?> _cached(String url) async {
    final memory = _memory[url];
    if (memory != null) return memory;
    try {
      final file = await _cacheFile(url);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size > 8 << 20) {
        return null;
      }
      final snapshot = await compute(parseLiveXmltv, await file.readAsBytes());
      final result = _CachedEpg(snapshot, stat.modified.toUtc());
      return _memory.putIfAbsent(url, () => result);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _download(String url) async {
    final request = await _client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, liveUserAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AppFailure('节目单服务返回 ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > 8 << 20) throw AppFailure('节目单数据过大');
    }
    return bytes.takeBytes();
  }

  Future<_CachedEpg> _refresh(String url) => _inflight.putIfAbsent(url, () {
    final future = () async {
      try {
        final bytes = await (_load?.call(url) ?? _download(url)).timeout(
          const Duration(seconds: 20),
        );
        if (bytes.length > 8 << 20) throw AppFailure('节目单数据过大');
        final snapshot = await compute(parseLiveXmltv, bytes);
        if (_disposed) throw StateError('节目单已关闭');
        final result = _CachedEpg(snapshot, DateTime.now().toUtc());
        _memory[url] = result;
        _failed.remove(url);
        try {
          final file = await _cacheFile(url);
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
        } catch (_) {
          return result;
        }
        return result;
      } catch (_) {
        _failed[url] = DateTime.now();
        rethrow;
      } finally {
        _inflight.remove(url);
      }
    }();
    return future;
  });

  Future<LiveEpgSchedule> programmes(
    LiveChannel channel,
    DateTime date, {
    bool force = false,
  }) async {
    if (_disposed) throw StateError('节目单已关闭');
    LiveEpgSchedule? stale;
    var available = false;
    for (final source in liveEpgSources) {
      var cached = await _cached(source.url);
      final fresh =
          cached != null &&
          DateTime.now().difference(cached.updated) < const Duration(hours: 4);
      if (force || !fresh) {
        final failed = _failed[source.url];
        if (force ||
            failed == null ||
            DateTime.now().difference(failed) >= const Duration(minutes: 1)) {
          try {
            cached = await _refresh(source.url);
          } catch (_) {
            cached ??= _memory[source.url];
          }
        }
      }
      if (cached == null) continue;
      available = true;
      final items = cached.snapshot.forChannel(channel, date);
      if (items.isEmpty) continue;
      final result = LiveEpgSchedule(
        items: items,
        source: source.name,
        updated: cached.updated,
        stale:
            DateTime.now().difference(cached.updated) >=
            const Duration(hours: 4),
      );
      if (!result.stale) return result;
      stale ??= result;
    }
    if (stale != null) return stale;
    if (!available) throw AppFailure('节目单暂时无法获取，请重试或手动选时');
    return LiveEpgSchedule(
      items: const [],
      source: '',
      updated: DateTime.now().toUtc(),
    );
  }
}
