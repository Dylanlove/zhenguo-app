import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'danmaku_models.dart';
import 'danmaku_preferences.dart';

class DanmakuApiException implements Exception {
  const DanmakuApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class DanmakuCancelled implements Exception {
  const DanmakuCancelled();
}

class DanmakuCancellation {
  bool _cancelled = false;
  final _done = Completer<void>();
  final _callbacks = <void Function()>[];
  bool get cancelled => _cancelled;
  void check() {
    if (_cancelled) throw const DanmakuCancelled();
  }

  void add(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void remove(void Function() callback) => _callbacks.remove(callback);
  Future<T> bind<T>(Future<T> work) {
    check();
    return Future.any([
      work,
      _done.future.then<T>((_) => throw const DanmakuCancelled()),
    ]);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _done.complete();
    for (final callback in _callbacks.toList()) {
      callback();
    }
    _callbacks.clear();
  }
}

abstract class DanmakuService {
  Future<List<DanmakuAnime>> search(
    DanmakuSource source,
    String keyword,
    DanmakuCancellation cancel,
  );
  Future<List<DanmakuMatch>> episodes(
    DanmakuSource source,
    DanmakuAnime anime,
    DanmakuCancellation cancel,
  );
  Future<DanmakuMatch?> match(
    DanmakuSource source,
    DanmakuSubject subject,
    DanmakuCancellation cancel, {
    bool force = false,
  });
  Future<List<DanmakuItem>> comments(
    DanmakuSource source,
    DanmakuMatch match,
    DanmakuCancellation cancel,
  );
  Future<void> probe(DanmakuSource source, DanmakuCancellation cancel) async {
    await search(source, '弹幕', cancel);
  }

  void dispose() {}
}

class DanmakuApiClient extends DanmakuService {
  DanmakuApiClient({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  final _active = <HttpClient>{};
  final _cache = <String, ({DateTime expires, List<DanmakuItem> items})>{};
  final _matches = <String, ({DateTime expires, DanmakuMatch? match})>{};
  bool _disposed = false;

  Future<String> _request(
    Uri uri,
    DanmakuCancellation cancel, {
    Map<String, dynamic>? body,
  }) async {
    cancel.check();
    if (_disposed) throw const DanmakuCancelled();
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 8);
    _active.add(client);
    void abort() => client.close(force: true);
    cancel.add(abort);
    try {
      return await cancel.bind(
        () async {
          final request = await client.openUrl(
            body == null ? 'GET' : 'POST',
            uri,
          );
          cancel.check();
          request.headers.set(
            HttpHeaders.acceptHeader,
            'application/json, application/xml, text/xml',
          );
          if (body != null) {
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
          }
          final response = await request.close();
          cancel.check();
          if (response.statusCode != HttpStatus.ok) {
            throw DanmakuApiException(
              '弹幕 API 返回 HTTP ${response.statusCode}',
              statusCode: response.statusCode,
            );
          }
          const limit = 16 * 1024 * 1024;
          if (response.contentLength > limit)
            throw const DanmakuApiException('弹幕响应超过 16 MB');
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response) {
            cancel.check();
            bytes.add(chunk);
            if (bytes.length > limit)
              throw const DanmakuApiException('弹幕响应超过 16 MB');
          }
          return utf8
              .decode(bytes.takeBytes())
              .replaceFirst(RegExp(r'^\uFEFF'), '');
        }().timeout(const Duration(seconds: 15)),
      );
    } on DanmakuCancelled {
      rethrow;
    } on DanmakuApiException {
      rethrow;
    } on TimeoutException {
      throw const DanmakuApiException('弹幕 API 响应超时，请检查地址或稍后重试');
    } on FormatException {
      throw const DanmakuApiException('弹幕 API 响应编码无效');
    } catch (_) {
      cancel.check();
      if (_disposed) throw const DanmakuCancelled();
      throw const DanmakuApiException('无法连接弹幕 API，请检查网络和地址');
    } finally {
      cancel.remove(abort);
      _active.remove(client);
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _json(
    Uri uri,
    DanmakuCancellation cancel, {
    Map<String, dynamic>? body,
  }) async {
    final raw = await _request(uri, cancel, body: body);
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (value['success'] == false)
        throw const DanmakuApiException('弹幕 API 拒绝了请求，请检查服务配置');
      return value;
    } on FormatException {
      throw const DanmakuApiException('响应不是兼容弹弹play的 JSON 格式');
    }
  }

  @override
  Future<List<DanmakuAnime>> search(
    DanmakuSource source,
    String keyword,
    DanmakuCancellation cancel,
  ) async {
    final value = await _json(
      source.endpoint('search/anime', {'keyword': keyword.trim()}),
      cancel,
    );
    final rows = value['animes'];
    if (rows is! List)
      throw const DanmakuApiException('响应缺少 animes 列表，请检查 API 协议');
    return [
      for (final row in rows.take(100))
        if (row is Map &&
            _id(row['animeId']).isNotEmpty &&
            row['animeTitle'] is String)
          DanmakuAnime(
            id: _id(row['animeId']),
            title: row['animeTitle'] as String,
            description: row['typeDescription'] as String? ?? '',
          ),
    ];
  }

  @override
  Future<List<DanmakuMatch>> episodes(
    DanmakuSource source,
    DanmakuAnime anime,
    DanmakuCancellation cancel,
  ) async {
    final uri = source
        .endpoint('bangumi')
        .replace(
          pathSegments: [...source.endpoint('bangumi').pathSegments, anime.id],
        );
    final value = await _json(uri, cancel);
    final bangumi = value['bangumi'];
    if (bangumi is! Map || bangumi['episodes'] is! List) {
      throw const DanmakuApiException('响应缺少 bangumi.episodes 分集列表');
    }
    return [
      for (final row in (bangumi['episodes'] as List).take(5000))
        if (row is Map && _id(row['episodeId']).isNotEmpty)
          DanmakuMatch(
            sourceId: source.id,
            episodeId: _id(row['episodeId']),
            animeId: anime.id,
            animeTitle: anime.title,
            episodeTitle: '${row['episodeTitle'] ?? row['title'] ?? '未命名分集'}',
          ),
    ];
  }

  @override
  Future<DanmakuMatch?> match(
    DanmakuSource source,
    DanmakuSubject subject,
    DanmakuCancellation cancel, {
    bool force = false,
  }) async {
    cancel.check();
    if (_disposed) throw const DanmakuCancelled();
    final key =
        '${source.id}|${source.baseUrl}|${subject.title}|${subject.season}|${subject.episode}';
    final cached = _matches.remove(key);
    if (!force && cached != null && cached.expires.isAfter(DateTime.now())) {
      _matches[key] = cached;
      return cached.match;
    }
    final result = await _match(source, subject, cancel);
    cancel.check();
    _matches[key] = (
      expires: DateTime.now().add(Duration(minutes: result == null ? 1 : 20)),
      match: result,
    );
    while (_matches.length > 100) {
      _matches.remove(_matches.keys.first);
    }
    return result;
  }

  Future<DanmakuMatch?> _match(
    DanmakuSource source,
    DanmakuSubject subject,
    DanmakuCancellation cancel,
  ) async {
    try {
      final value = await _json(
        source.endpoint('match'),
        cancel,
        body: {'fileName': subject.fileName, 'matchMode': 'fileNameOnly'},
      );
      final matches = value['matches'];
      if (matches is! List)
        throw const DanmakuApiException('匹配响应缺少 matches 列表');
      if (value['isMatched'] == false || matches.length != 1) return null;
      final row = matches.single;
      if (row is! Map || _id(row['episodeId']).isEmpty)
        throw const DanmakuApiException('匹配响应缺少分集 ID');
      return DanmakuMatch(
        sourceId: source.id,
        episodeId: _id(row['episodeId']),
        animeId: _id(row['animeId']),
        animeTitle: '${row['animeTitle'] ?? subject.title}',
        episodeTitle: '${row['episodeTitle'] ?? '第${subject.episode}集'}',
      );
    } on DanmakuApiException catch (error) {
      if (error.statusCode != 404 && error.statusCode != 405) rethrow;
      final shows = await search(source, subject.title, cancel);
      final exact = shows
          .where((show) => _title(show.title) == _title(subject.title))
          .toList();
      if (subject.season != 1 || exact.length != 1) return null;
      final entries = await episodes(source, exact.single, cancel);
      final found = entries
          .where(
            (entry) => _episodeNumber(entry.episodeTitle) == subject.episode,
          )
          .toList();
      return found.length == 1 ? found.single : null;
    }
  }

  @override
  Future<List<DanmakuItem>> comments(
    DanmakuSource source,
    DanmakuMatch match,
    DanmakuCancellation cancel,
  ) async {
    cancel.check();
    final key = '${source.baseUrl}|${match.episodeId}';
    final cached = _cache.remove(key);
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      _cache[key] = cached;
      return cached.items;
    }
    final raw = await _request(source.commentEndpoint(match.episodeId), cancel);
    List<DanmakuItem> parsed;
    try {
      parsed = await cancel.bind(compute(parseDanmakuDocument, raw));
    } on FormatException catch (error) {
      throw DanmakuApiException(error.message);
    }
    cancel.check();
    final items = List<DanmakuItem>.unmodifiable(parsed);
    _cache[key] = (
      expires: DateTime.now().add(const Duration(minutes: 10)),
      items: items,
    );
    while (_cache.length > 6 ||
        _cache.values.fold<int>(0, (sum, entry) => sum + entry.items.length) >
            40000) {
      _cache.remove(_cache.keys.first);
    }
    return items;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
    _cache.clear();
    _matches.clear();
  }
}

String _id(Object? value) => value is int || value is String ? '$value' : '';
String _title(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
int? _episodeNumber(String value) {
  final match = RegExp(
    r'第\s*([\d零一二三四五六七八九十百两]+)\s*[集话]|(?:EP?|#)\s*(\d+)|^(\d+)(?:\D|$)',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null
      ? null
      : danmakuNumber(match.group(1) ?? match.group(2) ?? match.group(3)!);
}

List<DanmakuItem> parseDanmakuDocument(String document) {
  final raw = document.trim();
  final output = <DanmakuItem>[];
  final seen = <String>{};
  void append(
    Object? timestamp,
    Object? modeValue,
    Object? colorValue,
    Object? content,
    Object? id,
    int index,
  ) {
    final seconds = double.tryParse('$timestamp');
    if (seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds * 1000 >= danmakuMaxDurationMs ||
        content is! String ||
        content.length > 16384)
      return;
    final clean = content
        .replaceAll(
          RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]'),
          ' ',
        )
        .trim();
    if (clean.isEmpty) return;
    final text = trimDanmakuText(clean, 100);
    final modeNumber = int.tryParse('$modeValue');
    if (modeNumber != null && modeNumber >= 7) return;
    final mode = switch (modeNumber) {
      4 => DanmakuMode.bottom,
      5 => DanmakuMode.top,
      _ => DanmakuMode.scroll,
    };
    final color = (int.tryParse('$colorValue') ?? 0xffffff) & 0xffffff;
    final time = (seconds * 1000).round();
    if (!seen.add('$time|${mode.name}|$color|$text')) return;
    output.add(
      DanmakuItem(
        id: '${_id(id).length <= 128 ? _id(id) : ''}:$index',
        text: text,
        timeMs: time,
        color: color,
        mode: mode,
      ),
    );
  }

  if (raw.startsWith('<')) {
    if (raw.toUpperCase().contains('<!DOCTYPE') ||
        raw.toUpperCase().contains('<!ENTITY'))
      throw const FormatException('XML 弹幕不支持 DTD 或实体声明');
    final document = XmlDocument.parse(raw);
    if (document.rootElement.name.local != 'i')
      throw const FormatException('响应不是标准 Bilibili XML 弹幕');
    final rows = document.rootElement.findElements('d').toList();
    final stride = (rows.length / danmakuMaxItems).ceil().clamp(1, 1000000);
    for (
      var i = 0;
      i < rows.length && output.length < danmakuMaxItems;
      i += stride
    ) {
      final row = rows[i],
          fields = (rows[i].getAttribute('p') ?? '').split(',');
      if (fields.length < 4) continue;
      append(
        fields[0],
        fields[1],
        fields[3],
        row.innerText,
        fields.length > 7 ? fields[7] : '',
        i,
      );
    }
  } else {
    final value = jsonDecode(raw);
    final rows = value is Map ? value['comments'] : null;
    if (value is! Map || value['success'] == false || rows is! List)
      throw const FormatException('响应缺少兼容弹弹play的 comments 列表');
    final stride = (rows.length / danmakuMaxItems).ceil().clamp(1, 1000000);
    for (
      var i = 0;
      i < rows.length && output.length < danmakuMaxItems;
      i += stride
    ) {
      final row = rows[i];
      if (row is! Map) continue;
      final p = row['p'];
      if (p is String) {
        final fields = p.split(',');
        if (fields.isEmpty) continue;
        append(
          fields[0],
          fields.length > 1 ? fields[1] : null,
          fields.length > 2 ? fields[2] : null,
          row['m'],
          row['cid'],
          i,
        );
      } else {
        append(
          row['time'],
          row['mode'],
          row['color'],
          row['text'],
          row['id'],
          i,
        );
      }
    }
  }
  output.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return output;
}
