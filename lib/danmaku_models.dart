import 'package:characters/characters.dart';

import 'models.dart';

const danmakuLifetimeMs = 8000;
const danmakuMaxDurationMs = 86400000;
const danmakuMaxItems = 20000;

String trimDanmakuText(String text, int limit) =>
    text.characters.take(limit).toString();

enum DanmakuMode { scroll, top, bottom }

class DanmakuItem {
  const DanmakuItem({
    required this.id,
    required this.text,
    required this.timeMs,
    this.color = 0xffffff,
    this.mode = DanmakuMode.scroll,
  });
  final String id;
  final String text;
  final int timeMs;
  final int color;
  final DanmakuMode mode;
}

int? danmakuNumber(String text) {
  final direct = int.tryParse(text);
  if (direct != null) return direct;
  const digits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var total = 0, digit = 0;
  for (final char in text.characters) {
    if (digits.containsKey(char)) {
      digit = digits[char]!;
    } else if (char == '十' || char == '百') {
      total += (digit == 0 ? 1 : digit) * (char == '十' ? 10 : 100);
      digit = 0;
    } else {
      return null;
    }
  }
  return text.isEmpty ? null : total + digit;
}

class DanmakuSubject {
  const DanmakuSubject({
    required this.key,
    required this.title,
    required this.episode,
    this.season = 1,
  });
  final String key;
  final String title;
  final int season;
  final int episode;
  String get fileName =>
      '$title S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}.mp4';

  static DanmakuSubject? fromEpisode(Drama drama, Episode episode) {
    if (drama.title.trim().isEmpty || episode.number <= 0) return null;
    final pattern = RegExp(
      r'第\s*([\d零一二三四五六七八九十百两]+)\s*季|\bS(\d{1,3})(?:E\d+)?\b',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(drama.title);
    final season = intValue(
      episode.raw['seasonNumber'] ?? episode.raw['season'],
    );
    final parsed = match == null
        ? 1
        : danmakuNumber(match.group(1) ?? match.group(2)!);
    final title = drama.title.replaceAll(pattern, '').trim();
    final number = season > 0 ? season : parsed ?? 1;
    return DanmakuSubject(
      key: '${drama.id}|$number|${episode.number}',
      title: title.isEmpty ? drama.title.trim() : title,
      season: number,
      episode: episode.number,
    );
  }
}

class DanmakuAnime {
  const DanmakuAnime({
    required this.id,
    required this.title,
    this.description = '',
  });
  final String id;
  final String title;
  final String description;
}

class DanmakuMatch {
  const DanmakuMatch({
    required this.sourceId,
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.animeId = '',
  });
  final String sourceId;
  final String episodeId;
  final String animeId;
  final String animeTitle;
  final String episodeTitle;
  String get label => '$animeTitle · $episodeTitle';
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'episodeId': episodeId,
    'animeId': animeId,
    'animeTitle': animeTitle,
    'episodeTitle': episodeTitle,
  };
  factory DanmakuMatch.fromJson(Map<String, dynamic> json) {
    final source = json['sourceId'], episode = json['episodeId'];
    if (source is! String ||
        source.isEmpty ||
        episode is! String ||
        episode.isEmpty ||
        episode.length > 2048) {
      throw const FormatException('弹幕匹配记录无效');
    }
    return DanmakuMatch(
      sourceId: source,
      episodeId: episode,
      animeId: json['animeId'] as String? ?? '',
      animeTitle: json['animeTitle'] as String? ?? '',
      episodeTitle: json['episodeTitle'] as String? ?? '',
    );
  }
}
