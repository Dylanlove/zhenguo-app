import 'dart:convert';

import 'app_build.dart';
import 'source_capabilities.dart';

class SourceSite {
  const SourceSite(this.id, this.name, this.description, {this.adult = false});
  final String id;
  final String name;
  final String description;

  /// 成人站源。绿色模式开启时不出现在站源管理与选择列表里。
  final bool adult;
  static Map<String, SourceCapabilities> _nativeCapabilities = const {};
  SourceCapabilities? get capabilities => _nativeCapabilities[id];
  String get adapterFingerprint => capabilities?.fingerprint ?? '未加载';

  static void installCapabilities(Object? raw, Object? schema) {
    if (schema != 1 || raw is! List)
      throw const FormatException('原生核心缺少站源能力描述，请更新完整安装包');
    final items = <String, SourceCapabilities>{};
    for (final entry in raw) {
      if (entry is! Map || entry['id'] is! String)
        throw const FormatException('站源能力描述无效');
      final id = entry['id'] as String;
      if (!isAvailable(id) || items.containsKey(id))
        throw const FormatException('站源能力描述与当前版本不一致');
      items[id] = SourceCapabilities.fromJson(Map<String, dynamic>.from(entry));
    }
    if (values.any((source) => !items.containsKey(source.id)))
      throw const FormatException('原生核心的站源能力描述不完整');
    _nativeCapabilities = Map.unmodifiable(items);
  }

  bool get onlineSearch =>
      capabilities?.onlineSearch ??
      (id == 'hongguo' || filmSource || pagedSearch);
  bool get filmSource =>
      capabilities?.film ??
      (id == 'ikanbot' ||
          id == 'a123' ||
          id == 'xiaopingguo' ||
          id == 'miguo-honey');
  bool get pagedSearch =>
      capabilities?.searchPaging ??
      (id == 'hongguo' ||
          id == 'huangguoai' ||
          id == 'huangju' ||
          id == 'yeguo' ||
          id == 'dsd' ||
          id == 'xiaopingguo' ||
          id == 'miguo-honey' ||
          duanjuPaged);
  bool get duanjuPaged => const {
    'yaguo',
    'huaguo',
    'wuguo',
    'maoguo',
    'heguo',
    'xingguo',
    'chaoguo',
    'miguo',
    'shuangguo',
    'yanguo',
    'taoguo',
    'youguo',
    'liuguo',
    'meiguo',
    'chengguo',
    'xiaoguo',
  }.contains(id);
  bool get searchSuggestions => capabilities?.suggestions ?? (id == 'hongguo');
  String get groupId => switch (id) {
    'huangguo-video' || 'huangguoai' || 'cloudfront' => 'huangguo',
    _ => id,
  };
  String get groupName => groupId == 'huangguo' ? '黄果' : name;
  String get entryName => switch (id) {
    'huangguo-video' => '视频',
    'huangguoai' => 'AI',
    'cloudfront' => '旧版',
    _ => name,
  };

  static const hongguo = SourceSite('hongguo', '红果', '短剧 · 漫剧 · AI 剧');
  static const ikanbot = SourceSite('ikanbot', '爱看机器人', '电影 · 剧集 · 多线路');
  static const a123 = SourceSite('a123', 'A123TV', '电影 · 连续剧 · 综艺 · 动漫');
  static const xiaopingguo = SourceSite(
    'xiaopingguo',
    '小苹果',
    '电影 · 剧集 · 4K · 奈飞 · 多线路',
  );
  static const miguoHoney = SourceSite(
    'miguo-honey',
    '蜜果',
    '视频 · 短剧 · 动漫 · 直播 · 多线路',
    adult: true,
  );
  static const dsd = SourceSite('dsd', '帝果', '懂色帝 · AV 网页目录', adult: true);
  static const duanjuValues = [
    SourceSite('yaguo', '芽果', '星芽短剧 · 登录接口'),
    SourceSite('maoguo', '猫果', '七猫短剧 · 签名接口'),
    SourceSite('heguo', '河果', '河马剧场 · 网页接口'),
    SourceSite('xingguo', '星果', '星星短剧 · 连载接口'),
    SourceSite('huaguo', '花果', '花生短剧 · 网页目录'),
    SourceSite('wuguo', '伍果', '五五短剧 · 网页目录'),
    SourceSite('chaoguo', '超果', '超短剧 · AI 成人短剧', adult: true),
    SourceSite('miguo', '米果', '大米星球 · 网页目录'),
    SourceSite('shuangguo', '爽果', '短剧网 · 网页目录'),
    SourceSite('yanguo', '艳果', 'AV星球 · 网页目录', adult: true),
    SourceSite('taoguo', '桃果', '撸鸡鸡 · 网页目录', adult: true),
    SourceSite('youguo', '柚果', 'Youavhub · 网页目录', adult: true),
    SourceSite('liuguo', '榴果', '榴莲视频 · 网页目录', adult: true),
    SourceSite('meiguo', '美果', '唯美精品 · 网页目录', adult: true),
    SourceSite('chengguo', '城果', '不夜城 · 网页目录', adult: true),
    SourceSite('xiaoguo', '宵果', '夜色 · 网页目录', adult: true),
    SourceSite('yingguo', '樱果', 'MissAV · 网页目录', adult: true),
    SourceSite('luguo', '露果', '撸一天 · 网页目录', adult: true),
    SourceSite('liguo', '荔果', '日日撸 · 网页目录', adult: true),
    SourceSite('juguo', '橘果', '海角乱伦 · 网页目录', adult: true),
    SourceSite('zaoguo', '枣果', '银河视频 · 网页目录', adult: true),
    SourceSite('ningguo', '柠果', '愛豆AV · 网页目录', adult: true),
    SourceSite('mangguo', '芒果', '真实人妻 · 网页目录', adult: true),
  ];
  static const allValues = [
    hongguo,
    SourceSite('huangdou', '豆果', '魔改短剧 · 网页目录', adult: true),
    SourceSite('huangju', '剧果', '红果黄剧 · AI 成人短剧', adult: true),
    SourceSite('yeguo', '野果', '野果短剧 · AI 成人短剧', adult: true),
    dsd,
    SourceSite('huangguo-video', '黄果视频', '黄果 · AI 成人短剧', adult: true),
    SourceSite('huangguoai', '黄果 AI', '黄果 · AI 成人短剧', adult: true),
    SourceSite('cloudfront', '黄果旧版', '黄果 · 旧 API 剧库', adult: true),
    ...duanjuValues,
    ikanbot,
    a123,
    xiaopingguo,
    miguoHoney,
  ];
  static final knownValues = List<SourceSite>.unmodifiable([
    ...allValues.where((site) => !site.adult),
    ...allValues.where((site) => site.adult),
  ]);
  // 默认版本保持红果单站源；全站源版再开放已知站源集合。
  static final values = allSourcesEnabled ? knownValues : [hongguo];
  static bool isAvailable(String id) => values.any((site) => site.id == id);
  static bool isKnown(String id) => allValues.any((site) => site.id == id);
  static bool isAdult(String id) =>
      allValues.any((site) => site.id == id && site.adult);
  static SourceSite byId(String id) =>
      allValues.firstWhere((site) => site.id == id, orElse: () => hongguo);
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(
    this.id,
    this.name, {
    this.local = false,
    this.filters = const [],
  });
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  final List<CatalogCategoryFilter> filters;
  static String baseId(String selection) => selection.split('?').first;
  static Map<String, String> query(String selection) {
    final position = selection.indexOf('?');
    if (position < 0) return {};
    try {
      return Uri.splitQueryString(selection.substring(position + 1));
    } on FormatException {
      return {};
    }
  }

  Map<String, String> filterValues(String selection) {
    final selected = query(selection);
    final values = <String, String>{};
    for (final filter in filters) {
      if (!filter.active(values)) continue;
      final candidate = selected[filter.key] ?? filter.defaultValue;
      values[filter.key] = filter.values.any((value) => value.id == candidate)
          ? candidate
          : filter.defaultValue;
    }
    return values;
  }

  String selection(Map<String, String> values) {
    final active = <String, String>{};
    final query = <String, String>{};
    for (final filter in filters) {
      if (!filter.active(active)) continue;
      final value = values[filter.key] ?? filter.defaultValue;
      active[filter.key] = value;
      if (value != filter.defaultValue) query[filter.key] = value;
    }
    return query.isEmpty ? id : '$id?${Uri(queryParameters: query).query}';
  }

  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
        filters: [
          for (final filter in json['filters'] as List? ?? const [])
            if (filter is Map)
              CatalogCategoryFilter.fromJson(Map<String, dynamic>.from(filter)),
        ],
      );
}

class CatalogCategoryFilter {
  const CatalogCategoryFilter({
    required this.key,
    required this.name,
    this.defaultValue = '',
    required this.values,
    this.parentKey = '',
    this.parentValues = const [],
  });

  final String key, name, defaultValue, parentKey;
  final List<CatalogCategory> values;
  final List<String> parentValues;

  bool active(Map<String, String> selected) =>
      parentKey.isEmpty || parentValues.contains(selected[parentKey]);

  factory CatalogCategoryFilter.fromJson(Map<String, dynamic> json) =>
      CatalogCategoryFilter(
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        defaultValue: json['default'] as String? ?? '',
        parentKey: json['parentKey'] as String? ?? '',
        parentValues: (json['parentValues'] as List? ?? const [])
            .cast<String>(),
        values: [
          for (final value in json['values'] as List? ?? const [])
            if (value is Map)
              CatalogCategory.fromJson(Map<String, dynamic>.from(value)),
        ],
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, {this.warning = ''});
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.routeNames = const [],
    this.local = false,
  });
  final String url;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final List<String> routeNames;
  final bool local;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  String routeLabel(int index) =>
      index >= 0 && index < routeNames.length && routeNames[index].isNotEmpty
      ? routeNames[index]
      : '线路 ${index + 1}';
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
    routeNames: (json['routeNames'] as List? ?? [])
        .map((value) => value?.toString() ?? '')
        .toList(),
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
