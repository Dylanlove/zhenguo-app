import 'models.dart';

DateTime? sourceTime(Object? value) {
  final time = DateTime.tryParse('$value');
  return time != null && time.year >= 2000 ? time.toLocal() : null;
}

class SourceHealthStep {
  SourceHealthStep.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String? ?? '',
      state = json['state'] as String? ?? '',
      message = json['message'] as String? ?? '',
      host = json['host'] as String? ?? '',
      httpStatus = intValue(json['httpStatus']),
      elapsedMs = intValue(json['elapsedMs']),
      cfRay = json['cfRay'] as String? ?? '',
      code = json['code'] as String? ?? '';

  final String name, state, message, host, cfRay, code;
  final int httpStatus, elapsedMs;
}

class SourceHealth {
  SourceHealth.fromJson(Map<String, dynamic> json)
    : checkedAt = sourceTime(json['checkedAt']),
      state = json['state'] as String? ?? '',
      sample = json['sample'] as String? ?? '',
      steps = [
        for (final step in json['steps'] as List? ?? [])
          SourceHealthStep.fromJson(Map<String, dynamic>.from(step as Map)),
      ];

  final DateTime? checkedAt;
  final String state, sample;
  final List<SourceHealthStep> steps;
  String get label => switch (state) {
    'ok' => '连接检测通过',
    'catalogOnly' => '目录正常 · 播放未检测',
    'checking' => '检测中',
    'failed' => '检测未通过',
    _ => '尚未检测',
  };
}

class SourceCatalogFeed {
  SourceCatalogFeed.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String? ?? '',
      offset = intValue(json['offset']),
      pages = intValue(json['pages']),
      initialized = json['initialized'] == true,
      exhausted = json['exhausted'] == true,
      reason = json['reason'] as String? ?? '',
      updatedAt = sourceTime(json['updatedAt']);

  final String name, reason;
  final int offset, pages;
  final bool initialized, exhausted;
  final DateTime? updatedAt;
}

class SourceCatalogScan {
  SourceCatalogScan.fromJson(Map<String, dynamic> json)
    : state = json['state'] as String? ?? 'not_started',
      startedAt = sourceTime(json['startedAt']),
      feeds = [
        for (final row in (json['feeds'] as List? ?? const []).take(3))
          if (row is Map)
            SourceCatalogFeed.fromJson(Map<String, dynamic>.from(row)),
      ];

  final String state;
  final DateTime? startedAt;
  final List<SourceCatalogFeed> feeds;

  int get pages => feeds.fold(0, (total, feed) => total + feed.pages);
}

class SourceStatus {
  SourceStatus.fromJson(Map<String, dynamic> json)
    : source = json['source'] as String? ?? '',
      count = intValue(json['count']),
      unknownVip = intValue(json['unknownVip']),
      page = intValue(json['page']),
      hasMore = json['hasMore'] == true,
      updatedAt = sourceTime(json['updatedAt']),
      running = json['running'] == true,
      operation = json['operation'] as String? ?? '',
      stage = json['stage'] as String? ?? '',
      completed = intValue(json['completed']),
      total = intValue(json['total']),
      added = intValue(json['added']),
      error = json['error'] as String? ?? '',
      storageError = json['storageError'] as String? ?? '',
      startedAt = sourceTime(json['startedAt']),
      deadlineAt = sourceTime(json['deadlineAt']),
      finishedAt = sourceTime(json['finishedAt']),
      retryAt = sourceTime(json['retryAt']),
      catalogScan = json['catalogScan'] is Map
          ? SourceCatalogScan.fromJson(
              Map<String, dynamic>.from(json['catalogScan'] as Map),
            )
          : null,
      health = json['health'] is Map
          ? SourceHealth.fromJson(
              Map<String, dynamic>.from(json['health'] as Map),
            )
          : null;

  final String source, operation, stage, error, storageError;
  final int count, page, completed, total, added, unknownVip;
  final bool hasMore, running;
  final DateTime? updatedAt, startedAt, deadlineAt, finishedAt, retryAt;
  final SourceHealth? health;
  final SourceCatalogScan? catalogScan;

  bool get scanningCatalog =>
      source == 'hongguo' &&
      running &&
      const ['update', 'more', 'rescan'].contains(operation) &&
      catalogScan?.state == 'scanning' &&
      stage != '补齐剧集资料';

  String get catalogSummary {
    if (source != 'hongguo') {
      return '已加载至第 $page 页${hasMore ? ' · 可继续加载' : ' · 当前分页已加载完'}';
    }
    if (storageError.isNotEmpty) {
      return '已收录 $count 部 · 有更新内容尚未保存，请重试保存';
    }
    final state = catalogScan?.state ?? (hasMore ? 'ready' : 'complete');
    final message = switch (state) {
      'complete' => '本轮扫描结束，可重新扫描',
      'scanning' => '本轮扫描中，进度逐页保存',
      'interrupted' => '扫描中断，进度已保存，可继续',
      'not_started' => '可更新或重新扫描目录',
      _ => '本轮尚未结束，可继续扫描',
    };
    return '已收录 $count 部 · $message';
  }

  int get retrySeconds {
    if (retryAt == null) return 0;
    return ((retryAt!.difference(DateTime.now()).inMilliseconds / 1000).ceil())
        .clamp(0, 3600);
  }
}
