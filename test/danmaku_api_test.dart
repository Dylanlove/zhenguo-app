import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/danmaku_api.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(HttpServer, DanmakuSource)> server(
    Future<void> Function(HttpRequest) handle,
  ) async {
    final local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => local.close(force: true));
    local.listen((request) async {
      await handle(request);
    });
    return (
      local,
      DanmakuSource(
        id: 'local',
        name: '本地合成 API',
        baseUrl: 'http://127.0.0.1:${local.port}/private/api/v2',
      ),
    );
  }

  Future<void> json(
    HttpRequest request,
    Object response, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    await request.response.close();
  }

  DanmakuApiClient client() {
    final value = DanmakuApiClient();
    addTearDown(value.dispose);
    return value;
  }

  test(
    'custom HTTP API supports match, search, episodes, XML comments and episode caching',
    () async {
      var comments = 0, matchRequests = 0;
      final (_, source) = await server((request) async {
        expect(request.uri.pathSegments.take(3), ['private', 'api', 'v2']);
        if (request.uri.path.endsWith('/match')) {
          matchRequests++;
          final input =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(request.method, 'POST');
          expect(input['fileName'], '合成作品 S02E12.mp4');
          await json(request, {
            'success': true,
            'isMatched': true,
            'matches': [
              {
                'animeId': 1,
                'episodeId': 12,
                'animeTitle': '合成作品',
                'episodeTitle': '第12集',
              },
            ],
          });
        } else if (request.uri.path.endsWith('/search/anime')) {
          expect(request.uri.queryParameters['keyword'], '合成作品');
          await json(request, {
            'animes': [
              {'animeId': 1, 'animeTitle': '合成作品'},
            ],
          });
        } else if (request.uri.path.endsWith('/bangumi/1')) {
          await json(request, {
            'bangumi': {
              'episodes': [
                {'episodeId': 'a/b', 'episodeTitle': '第12集'},
              ],
            },
          });
        } else {
          expect(request.uri.pathSegments.last, 'a/b');
          expect(request.uri.queryParameters['format'], 'json');
          comments++;
          request.response.headers.contentType = ContentType(
            'text',
            'xml',
            charset: 'utf-8',
          );
          request.response.write(
            '<i><d p="1,1,25,16711680,0,0,u,1">合成弹幕</d></i>',
          );
          await request.response.close();
        }
      });
      final api = client(), cancel = DanmakuCancellation();
      final match = await api.match(
        source,
        const DanmakuSubject(key: 's', title: '合成作品', season: 2, episode: 12),
        cancel,
      );
      expect(match?.episodeId, '12');
      const subject = DanmakuSubject(
        key: 's',
        title: '合成作品',
        season: 2,
        episode: 12,
      );
      await api.match(source, subject, cancel);
      expect(matchRequests, 1);
      await api.match(source, subject, cancel, force: true);
      expect(matchRequests, 2);
      final shows = await api.search(source, '合成作品', cancel);
      final episodes = await api.episodes(source, shows.single, cancel);
      final items = await api.comments(source, episodes.single, cancel);
      expect(items.single.text, '合成弹幕');
      expect(items.single.color, 0xff0000);
      await api.comments(source, episodes.single, cancel);
      expect(comments, 1);
    },
  );

  test(
    'missing match endpoint uses conservative exact-title and exact-episode matching',
    () async {
      final (_, source) = await server((request) async {
        if (request.uri.path.endsWith('/match')) {
          await json(request, {}, status: 404);
        } else if (request.uri.path.endsWith('/search/anime')) {
          await json(request, {
            'animes': [
              {'animeId': 1, 'animeTitle': '合成作品'},
            ],
          });
        } else {
          await json(request, {
            'bangumi': {
              'episodes': [
                {'episodeId': 1, 'episodeTitle': '第一集'},
                {'episodeId': 12, 'episodeTitle': '第十二集'},
              ],
            },
          });
        }
      });
      final api = client();
      final found = await api.match(
        source,
        const DanmakuSubject(key: 's', title: '合成作品', episode: 12),
        DanmakuCancellation(),
      );
      expect(found?.episodeId, '12');
      final unknownSeason = await api.match(
        source,
        const DanmakuSubject(key: 's', title: '合成作品', season: 2, episode: 12),
        DanmakuCancellation(),
      );
      expect(unknownSeason, isNull);
    },
  );

  test(
    'ambiguous matches stay unresolved instead of guessing an episode',
    () async {
      final (_, source) = await server(
        (request) => json(request, {
          'isMatched': true,
          'matches': [
            {'episodeId': 1},
            {'episodeId': 2},
          ],
        }),
      );
      final found = await client().match(
        source,
        const DanmakuSubject(key: 's', title: '作品', episode: 1),
        DanmakuCancellation(),
      );
      expect(found, isNull);
    },
  );

  test('API detection rejects HTML and incomplete success responses', () async {
    var html = true;
    final (_, source) = await server((request) async {
      request.response.write(html ? '<html>login</html>' : '{"success":true}');
      await request.response.close();
    });
    final api = client();
    await expectLater(
      api.probe(source, DanmakuCancellation()),
      throwsA(isA<DanmakuApiException>()),
    );
    html = false;
    await expectLater(
      api.probe(source, DanmakuCancellation()),
      throwsA(isA<DanmakuApiException>()),
    );
  });

  test(
    'cancelling a hanging request closes it independently of playback',
    () async {
      final arrived = Completer<void>();
      final (_, source) = await server((request) async {
        arrived.complete();
      });
      final cancel = DanmakuCancellation();
      final future = client().search(source, '作品', cancel);
      final expectation = expectLater(future, throwsA(isA<DanmakuCancelled>()));
      await arrived.future;
      cancel.cancel();
      await expectation;
    },
  );

  test(
    'comment cache evicts old episodes and rejects oversized responses',
    () async {
      var calls = 0, oversized = false;
      final (_, source) = await server((request) async {
        calls++;
        if (oversized) {
          request.response.contentLength = 16 * 1024 * 1024 + 1;
          unawaited(request.response.close().catchError((Object _) {}));
        } else {
          await json(request, {
            'comments': [
              {'p': '0,1,16777215,u', 'm': '合成'},
            ],
          });
        }
      });
      final api = client();
      DanmakuMatch match(int i) => DanmakuMatch(
        sourceId: source.id,
        episodeId: '$i',
        animeTitle: '作品',
        episodeTitle: '$i',
      );
      for (var i = 0; i < 7; i++) {
        await api.comments(source, match(i), DanmakuCancellation());
      }
      await api.comments(source, match(0), DanmakuCancellation());
      expect(calls, 8);
      oversized = true;
      await expectLater(
        api.comments(source, match(100), DanmakuCancellation()),
        throwsA(isA<DanmakuApiException>()),
      );
    },
  );
}
