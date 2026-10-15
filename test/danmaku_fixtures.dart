import 'dart:async';

import 'package:duanju_app/danmaku_api.dart';
import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_preferences.dart';
import 'package:duanju_app/models.dart';

const fixtureDanmakuSource = DanmakuSource(
  id: 'custom',
  name: '合成弹幕 API',
  baseUrl: 'https://danmaku.example.test/token/api/v2',
);
const fixtureDanmakuPreferences = DanmakuPreferences(
  sources: [fixtureDanmakuSource],
  defaultSourceId: 'custom',
);
const danmakuPlan = PlaybackPlan(
  url: 'https://media.example.test/synthetic.mp4',
);
const danmakuSubject = DanmakuSubject(
  key: 'other:100|2|1',
  title: '合成作品',
  season: 2,
  episode: 1,
);

class DanmakuLoad {
  DanmakuLoad(this.match, this.cancel);
  final DanmakuMatch match;
  final DanmakuCancellation cancel;
  final result = Completer<List<DanmakuItem>>();
}

class FixtureDanmakuService extends DanmakuService {
  int matchCalls = 0, searchCalls = 0;
  bool hold = false, fail = false, unmatched = false, disposed = false;
  final loads = <DanmakuLoad>[];
  List<DanmakuItem>? data;
  @override
  Future<DanmakuMatch?> match(
    DanmakuSource source,
    DanmakuSubject subject,
    DanmakuCancellation cancel, {
    bool force = false,
  }) async {
    matchCalls++;
    return unmatched
        ? null
        : DanmakuMatch(
            sourceId: source.id,
            episodeId: 'api-${subject.episode}',
            animeTitle: subject.title,
            episodeTitle: '第${subject.episode}集',
          );
  }

  @override
  Future<List<DanmakuItem>> comments(
    DanmakuSource source,
    DanmakuMatch match,
    DanmakuCancellation cancel,
  ) async {
    final load = DanmakuLoad(match, cancel);
    loads.add(load);
    if (hold) return load.result.future;
    if (fail) throw const DanmakuApiException('合成弹幕失败');
    return data ??
        [
          DanmakuItem(
            id: match.episodeId,
            text: '合成弹幕 ${match.episodeId}',
            timeMs: 0,
          ),
        ];
  }

  @override
  Future<List<DanmakuAnime>> search(
    DanmakuSource source,
    String keyword,
    DanmakuCancellation cancel,
  ) async {
    searchCalls++;
    return const [DanmakuAnime(id: 'show', title: '合成作品')];
  }

  @override
  Future<List<DanmakuMatch>> episodes(
    DanmakuSource source,
    DanmakuAnime anime,
    DanmakuCancellation cancel,
  ) async => [
    DanmakuMatch(
      sourceId: source.id,
      episodeId: 'manual',
      animeTitle: anime.title,
      episodeTitle: '第1集',
    ),
  ];
  @override
  void dispose() {
    disposed = true;
  }
}

void updateDanmaku(
  DanmakuController controller, {
  int position = 0,
  int duration = 180000,
  bool playing = true,
  bool buffering = false,
  bool foreground = true,
  bool available = true,
  double speed = 1,
}) => controller.update(
  position: Duration(milliseconds: position),
  duration: Duration(milliseconds: duration),
  speed: speed,
  playing: playing,
  buffering: buffering,
  foreground: foreground,
  available: available,
);

Future<void> flushDanmaku() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.value();
  }
}
