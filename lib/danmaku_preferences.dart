import 'danmaku_models.dart';

enum DanmakuDensity { low, medium, high }

class DanmakuSource {
  const DanmakuSource({
    required this.id,
    required this.name,
    required this.baseUrl,
  });
  final String id;
  final String name;
  final String baseUrl;

  static Uri validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        value.length > 2048) {
      throw const FormatException('请输入有效的 HTTP / HTTPS API 地址');
    }
    return uri;
  }

  Uri endpoint(String route, [Map<String, String> query = const {}]) {
    final uri = validateUrl(baseUrl);
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length < 2 ||
        segments[segments.length - 2] != 'api' ||
        segments.last != 'v2') {
      segments.addAll(['api', 'v2']);
    }
    return uri.replace(
      pathSegments: [...segments, ...route.split('/')],
      queryParameters: {...uri.queryParameters, ...query},
    );
  }

  Uri commentEndpoint(String episodeId) {
    final uri = endpoint('comment');
    return uri.replace(
      pathSegments: [...uri.pathSegments, episodeId],
      queryParameters: {
        ...uri.queryParameters,
        'format': 'json',
        'withRelated': 'true',
        'chConvert': '0',
      },
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl};
  factory DanmakuSource.fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'], url = json['baseUrl'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 80 ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        url is! String) {
      throw const FormatException('弹幕 API 配置无效');
    }
    validateUrl(url);
    return DanmakuSource(id: id, name: name.trim(), baseUrl: url.trim());
  }
}

class DanmakuPreferences {
  const DanmakuPreferences({
    this.sources = const [],
    this.defaultSourceId = '',
    this.autoMatch = true,
    this.matches = const {},
    this.fontSize = 20,
    this.opacity = .85,
    this.useOriginalColor = true,
    this.color = 0xffffff,
    this.outline = true,
    this.shadow = true,
    this.area = .4,
    this.density = DanmakuDensity.medium,
    this.speed = 1,
    this.scroll = true,
    this.top = true,
    this.bottom = true,
    this.offsetSeconds = 0,
    this.keywords = const [],
    this.blockColored = false,
    this.subtitleSafe = true,
  });
  final List<DanmakuSource> sources;
  final String defaultSourceId;
  final bool autoMatch;
  final Map<String, DanmakuMatch> matches;
  final double fontSize;
  final double opacity;
  final bool useOriginalColor;
  final int color;
  final bool outline;
  final bool shadow;
  final double area;
  final DanmakuDensity density;
  final double speed;
  final bool scroll;
  final bool top;
  final bool bottom;
  final double offsetSeconds;
  final List<String> keywords;
  final bool blockColored;
  final bool subtitleSafe;
  int get lifetimeMs => (danmakuLifetimeMs / speed).round();
  DanmakuSource? get source {
    for (final value in sources) {
      if (value.id == defaultSourceId) return value;
    }
    return null;
  }

  DanmakuPreferences copyWith({
    List<DanmakuSource>? sources,
    String? defaultSourceId,
    bool? autoMatch,
    Map<String, DanmakuMatch>? matches,
    double? fontSize,
    double? opacity,
    bool? useOriginalColor,
    int? color,
    bool? outline,
    bool? shadow,
    double? area,
    DanmakuDensity? density,
    double? speed,
    bool? scroll,
    bool? top,
    bool? bottom,
    double? offsetSeconds,
    List<String>? keywords,
    bool? blockColored,
    bool? subtitleSafe,
  }) => DanmakuPreferences(
    sources: sources == null ? this.sources : List.unmodifiable(sources),
    defaultSourceId: defaultSourceId ?? this.defaultSourceId,
    autoMatch: autoMatch ?? this.autoMatch,
    matches: matches == null ? this.matches : Map.unmodifiable(matches),
    fontSize: fontSize ?? this.fontSize,
    opacity: opacity ?? this.opacity,
    useOriginalColor: useOriginalColor ?? this.useOriginalColor,
    color: color ?? this.color,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
    area: area ?? this.area,
    density: density ?? this.density,
    speed: speed ?? this.speed,
    scroll: scroll ?? this.scroll,
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
    offsetSeconds: offsetSeconds ?? this.offsetSeconds,
    keywords: keywords == null ? this.keywords : List.unmodifiable(keywords),
    blockColored: blockColored ?? this.blockColored,
    subtitleSafe: subtitleSafe ?? this.subtitleSafe,
  );

  DanmakuPreferences remember(String key, DanmakuMatch match) {
    final identity = '${match.sourceId}|$key';
    final saved = Map<String, DanmakuMatch>.of(matches)..remove(identity);
    saved[identity] = match;
    while (saved.length > 200) {
      saved.remove(saved.keys.first);
    }
    return copyWith(matches: saved);
  }

  DanmakuMatch? savedMatch(String key, String sourceId) =>
      matches['$sourceId|$key'];

  DanmakuPreferences resetDisplay() => const DanmakuPreferences().copyWith(
    sources: sources,
    defaultSourceId: defaultSourceId,
    autoMatch: autoMatch,
    matches: matches,
  );

  Map<String, dynamic> toJson() => {
    'sources': sources.map((value) => value.toJson()).toList(),
    'defaultSourceId': defaultSourceId,
    'autoMatch': autoMatch,
    'matches': matches.map((key, value) => MapEntry(key, value.toJson())),
    'fontSize': fontSize,
    'opacity': opacity,
    'useOriginalColor': useOriginalColor,
    'color': color,
    'outline': outline,
    'shadow': shadow,
    'area': area,
    'density': density.name,
    'speed': speed,
    'scroll': scroll,
    'top': top,
    'bottom': bottom,
    'offsetSeconds': offsetSeconds,
    'keywords': keywords,
    'blockColored': blockColored,
    'subtitleSafe': subtitleSafe,
  };

  factory DanmakuPreferences.fromJson(Object? raw) {
    if (raw is! Map) return const DanmakuPreferences();
    double bounded(String key, double fallback, double min, double max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        raw[key] is bool ? raw[key] as bool : fallback;
    final sources = <DanmakuSource>[];
    for (final row
        in (raw['sources'] is List ? raw['sources'] as List : const []).take(
          16,
        )) {
      try {
        final source = DanmakuSource.fromJson(
          Map<String, dynamic>.from(row as Map),
        );
        if (!sources.any((value) => value.id == source.id)) sources.add(source);
      } catch (_) {}
    }
    final saved = <String, DanmakuMatch>{};
    if (raw['matches'] is Map) {
      for (final row in (raw['matches'] as Map).entries.take(200)) {
        try {
          if (row.key is! String || (row.key as String).length > 512) continue;
          final match = DanmakuMatch.fromJson(
            Map<String, dynamic>.from(row.value as Map),
          );
          if (sources.any((source) => source.id == match.sourceId))
            saved[row.key as String] = match;
        } catch (_) {}
      }
    }
    final defaultId = raw['defaultSourceId'];
    final area = bounded('area', .4, .25, 1);
    return DanmakuPreferences(
      sources: List.unmodifiable(sources),
      defaultSourceId: sources.any((value) => value.id == defaultId)
          ? defaultId as String
          : sources.firstOrNull?.id ?? '',
      autoMatch: flag('autoMatch', true),
      matches: Map.unmodifiable(saved),
      fontSize: bounded('fontSize', 20, 12, 36),
      opacity: bounded('opacity', .85, .1, 1),
      useOriginalColor: flag('useOriginalColor', true),
      color: raw['color'] is int ? (raw['color'] as int) & 0xffffff : 0xffffff,
      outline: flag('outline', true),
      shadow: flag('shadow', true),
      area: const [.25, .4, .5, .75, 1.0].contains(area) ? area : .4,
      density:
          DanmakuDensity.values
              .where((value) => value.name == raw['density'])
              .firstOrNull ??
          DanmakuDensity.medium,
      speed: bounded('speed', 1, .5, 2),
      scroll: flag('scroll', true),
      top: flag('top', true),
      bottom: flag('bottom', true),
      offsetSeconds: bounded('offsetSeconds', 0, -120, 120),
      keywords: List.unmodifiable(
        (raw['keywords'] is List ? raw['keywords'] as List : const [])
            .whereType<String>()
            .map((word) => trimDanmakuText(word.trim(), 60))
            .where((word) => word.isNotEmpty)
            .take(100),
      ),
      blockColored: flag('blockColored', false),
      subtitleSafe: flag('subtitleSafe', true),
    );
  }
}
