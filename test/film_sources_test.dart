import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/network_exit.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/sources_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';
import 'remote_test_helpers.dart';

class FilmRouteRepository extends RouteRepository {
  final selected = <int>[];
  Completer<PlaybackPlan>? deferredRoute;
  final released = <String>[];

  @override
  Future<PlaybackPlan> selectRoute(PlaybackPlan current, int route) async {
    selected.add(route);
    if (deferredRoute != null) return deferredRoute!.future;
    final session = 'selected-${selected.length}';
    active.add(session);
    return PlaybackPlan(
      url: 'https://fixture.invalid/working-$session.mp4',
      session: session,
      routeIndex: route,
      routeCount: 2,
      routeNames: const ['线路 2', '线路 5'],
    );
  }

  @override
  Future<void> release(String session) async {
    released.add(session);
    await super.release(session);
  }
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 15; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  test('cover refusals do not diagnose an IP block or browser challenge', () {
    const raw = '海报请求失败：HTTP 403';
    final message = NetworkExit.describe(raw);
    expect(message, contains(raw));
    expect(message, contains('防盗链'));
    expect(message, contains('重新获取海报'));
    expect(message, isNot(contains('浏览器验证')));
    expect(message, isNot(contains('可疑')));
    expect(message, isNot(contains('同一出口')));
    expect(
      NetworkExit.describe('example.test HTTP 403：站点要求浏览器验证'),
      contains('站源要求浏览器验证'),
    );
    expect(NetworkExit.describe('海报地址无效'), '海报地址无效');
  });

  test(
    'film sources preserve display names, edition gates and user access',
    () {
      for (final source in [SourceSite.ikanbot, SourceSite.a123]) {
        expect(SourceSite.byId(source.id).name, source.name);
        expect(source.onlineSearch, isTrue);
        expect(source.pagedSearch, isFalse);
        expect(source.adult, isFalse);
        expect(SourceSite.isKnown(source.id), isTrue);
        expect(SourceSite.isAvailable(source.id), allSourcesEnabled);
        expect(
          const LocalProfile(
            id: 'viewer',
            name: 'Viewer',
            sources: ['hongguo'],
          ).allows(source.id),
          isFalse,
        );
      }
      expect(SourceSite.ikanbot.name, '爱看机器人');
      expect(SourceSite.a123.name, 'A123TV');
      expect(
        SourceSite.allValues.map((site) => site.id).toSet().length,
        SourceSite.allValues.length,
      );
    },
  );

  test('late manual route results cannot replace a newer playback', () async {
    final repository = FilmRouteRepository()
      ..deferredRoute = Completer<PlaybackPlan>();
    final loader = PlaybackLoader(repository);
    final old = loader.selectRoute(
      const PlaybackPlan(
        url: 'https://fixture.invalid/first.mp4',
        session: 'first',
      ),
      1,
    );
    await Future<void>.delayed(Duration.zero);
    final latest = loader.use(
      const PlaybackPlan(
        url: 'https://fixture.invalid/latest.mp4',
        session: 'latest',
      ),
    );
    expect((await latest)?.session, 'latest');
    repository.deferredRoute!.complete(
      const PlaybackPlan(
        url: 'https://fixture.invalid/late.mp4',
        session: 'late',
      ),
    );
    expect(await old, isNull);
    expect(repository.selected, [1]);
    expect(repository.released, ['late']);
    await loader.close();
  });

  testWidgets(
    'source management shows the film names only in the full edition',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(repository: FilmRouteRepository(), store: store),
        ),
      );
      await tester.pumpAndSettle();
      for (final source in [SourceSite.ikanbot, SourceSite.a123]) {
        if (allSourcesEnabled) {
          await tester.scrollUntilVisible(
            find.byKey(ValueKey('source-${source.id}')),
            500,
          );
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(ValueKey('source-${source.id}')),
          allSourcesEnabled ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(source.name),
          allSourcesEnabled ? findsOneWidget : findsNothing,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(tester.takeException(), isNull);
      store.dispose();
    },
  );

  for (final source in [SourceSite.ikanbot, SourceSite.a123]) {
    for (final television in [false, true]) {
      testWidgets(
        '${source.id} manual routes preserve position and pause on ${television ? 'TV' : 'desktop'}',
        (tester) async {
          tester.view.physicalSize = television
              ? const Size(960, 540)
              : const Size(1100, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final store = LocalStore(await SharedPreferences.getInstance());
          await store.setPlaybackPreferences(
            store.playbackPreferences.copyWith(danmaku: false),
          );
          final repository = FilmRouteRepository();
          final platform = ScriptedPlayer();
          final drama = Drama(
            id: '${source.id}:fixture',
            source: source.id,
            title: '无远程图片的线路测试',
          );
          final detail = DramaDetail(drama, [
            Episode({'id': '${drama.id}:episode-1', 'currentEpisode': 1}, 1),
          ]);
          final player = PlayerScreen(
            detail: detail,
            initialIndex: 0,
            initialPosition: 7,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: platform),
            videoBuilder: (controls) => controls,
          );
          await tester.pumpWidget(
            television
                ? televisionHost(child: player)
                : MaterialApp(theme: ThemeData.dark(), home: player),
          );
          await settle(tester);
          expect(platform.opened, hasLength(1));
          await platform.seek(const Duration(seconds: 28));
          await platform.pause();
          await settle(tester);

          Future<void> choose(int route) async {
            await tester.tap(
              find.byKey(
                ValueKey(television ? 'tv-settings' : 'player-quality'),
              ),
            );
            await tester.pumpAndSettle();
            final option = find.byKey(
              ValueKey(television ? 'tv-route-$route' : 'menu-route-$route'),
            );
            await tester.ensureVisible(option);
            if (repository.selected.isNotEmpty) {
              expect(find.text('线路 5'), findsOneWidget);
              expect(find.text('线路 1'), findsNothing);
            }
            await tester.tap(option);
            await settle(tester);
            await tester.pump(const Duration(milliseconds: 350));
            await settle(tester);
          }

          await choose(1);
          expect(repository.selected, [1]);
          expect(platform.opened, hasLength(2));
          expect(platform.opened.last.start, const Duration(seconds: 28));
          expect(platform.state.playing, isFalse);
          await choose(0);
          expect(repository.selected, [1, 0]);
          expect(platform.opened.last.start, const Duration(seconds: 28));
          expect(platform.state.playing, isFalse);
          expect(repository.fallbackCalls, 0);
          expect(repository.primaryCalls, 1);
          if (!television) {
            repository.broken = true;
            platform.fail();
            for (var attempt = 0; attempt < 5; attempt++) {
              await tester.pump(const Duration(seconds: 1));
              await settle(tester);
            }
            expect(find.text('暂时无法播放'), findsOneWidget);
            final routes = find.byKey(const ValueKey('player-error-routes'));
            expect(routes, findsOneWidget);
            await tester.tap(routes);
            await tester.pumpAndSettle();
            final option = find.byKey(const ValueKey('menu-route-0'));
            await tester.ensureVisible(option);
            await tester.tap(option);
            await settle(tester);
            expect(find.text('暂时无法播放'), findsNothing);
            expect(repository.selected.last, 0);
            expect(platform.state.position, const Duration(seconds: 28));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await settle(tester);
          expect(platform.disposed, isTrue);
          expect(repository.active, isEmpty);
          expect(tester.takeException(), isNull);
          store.dispose();
        },
        skip: !allSourcesEnabled,
      );
    }
  }

  for (final exhausted in [false, true]) {
    testWidgets(
      'film playback ${exhausted ? 'exhausts every line and keeps manual selection valid' : 'reaches a working line after the fourth attempt'}',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        await store.setPlaybackPreferences(
          store.playbackPreferences.copyWith(danmaku: false),
        );
        final repository = SequenceRouteRepository(
          workingRoute: exhausted ? null : 6,
        );
        final platform = ScriptedPlayer();
        final detail = DramaDetail(
          const Drama(id: 'ikanbot:fixture', source: 'ikanbot', title: '线路恢复'),
          [
            Episode({'id': 'ikanbot:fixture:ep-1', 'currentEpisode': 1}, 1),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              detail: detail,
              initialIndex: 0,
              initialPosition: 7,
              repository: repository,
              store: store,
              playerFactory: () => Player(platformPlayer: platform),
              videoBuilder: (controls) => controls,
            ),
          ),
        );
        await settle(tester);
        for (var attempt = 0; attempt < 10; attempt++) {
          await tester.pump(const Duration(seconds: 1));
          await settle(tester);
        }
        expect(repository.fallbackCalls, 6);
        expect(repository.primaryCalls, exhausted ? 2 : 1);
        expect(repository.openedRoutes, [
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          if (exhausted) 0,
        ]);
        expect(repository.active, hasLength(1));
        if (exhausted) {
          expect(find.text('暂时无法播放'), findsOneWidget);
          await tester.pump(const Duration(seconds: 25));
          expect(repository.primaryCalls, 2);
          expect(repository.fallbackCalls, 6);
          repository.workingRoute = 1;
          await tester.tap(find.byKey(const ValueKey('player-error-routes')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('menu-route-1')));
          await settle(tester);
          expect(repository.selected, [1]);
          expect(find.text('暂时无法播放'), findsNothing);
        }
        expect(platform.opened.last.start, const Duration(seconds: 7));
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        expect(repository.active, isEmpty);
        expect(platform.disposed, isTrue);
        expect(tester.takeException(), isNull);
        store.dispose();
      },
      skip: !allSourcesEnabled,
    );
  }
}
