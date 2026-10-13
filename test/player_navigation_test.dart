import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/live_playback.dart';
import 'package:duanju_app/live_player_screen.dart';
import 'package:duanju_app/live_repository.dart';
import 'package:duanju_app/live_sources.dart';
import 'package:duanju_app/live_store.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_route.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

class _LiveFixture extends LivePlaybackController {
  _LiveFixture(this.fixturePlayer) : super(repository: LiveRepository());

  final Player fixturePlayer;
  String? failure;

  @override
  Player get player => fixturePlayer;

  @override
  String? get error => failure;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final systemCalls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    systemCalls.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      systemCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      return switch (call.method) {
        'getBrightness' || 'getMediaVolume' => .5,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('duanju/media_volume'),
      (_) async => null,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(AppDevice.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('duanju/media_volume'),
      null,
    );
  });

  void iosTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final size in [const Size(844, 390), const Size(390, 844)]) {
    iosTest(
      'live controls hide after two seconds at ${size.width} width without a persistent progress bar',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final platform = ScriptedPlayer();
        final player = Player(platformPlayer: platform);
        await player.open(Media('https://fixture.invalid/live.m3u8'));
        final playback = _LiveFixture(player);
        final store = LiveStore(
          await SharedPreferences.getInstance(),
          'default',
        )..load();
        await tester.pumpWidget(
          MaterialApp(
            home: LivePlayerScreen(
              playback: playback,
              source: LiveSource.values.first,
              store: store,
              onExit: () {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          systemCalls.any(
            (call) =>
                call.method == 'SystemChrome.setEnabledSystemUIMode' &&
                call.arguments == 'SystemUiMode.immersiveSticky',
          ),
          isTrue,
        );
        expect(find.byTooltip('退出全屏').hitTestable(), findsOneWidget);
        expect(find.byKey(const ValueKey('player-progress')), findsNothing);
        await tester.pump(const Duration(milliseconds: 1800));
        expect(find.byTooltip('退出全屏').hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('退出全屏').hitTestable(), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tapAt(Offset(size.width / 2, size.height / 2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('旋转与全屏').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('旋转与全屏').hitTestable());
        await tester.pump(const Duration(milliseconds: 1800));
        expect(find.byTooltip('退出全屏').hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('退出全屏').hitTestable(), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(
          systemCalls.any(
            (call) =>
                call.method == 'SystemChrome.setEnabledSystemUIMode' &&
                call.arguments == 'SystemUiMode.edgeToEdge',
          ),
          isTrue,
        );
        playback.dispose();
        playback.repository.dispose();
        store.dispose();
        await player.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<(ScriptedPlayer, RouteRepository)> openFailedPlayer(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = RouteRepository()..broken = true;
    final platform = ScriptedPlayer();
    final store = LocalStore(await SharedPreferences.getInstance());
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  playerRoute(
                    PlayerScreen(
                      detail: detail,
                      initialIndex: 0,
                      repository: repository,
                      store: store,
                      playerFactory: () => Player(platformPlayer: platform),
                      videoBuilder: (controls) => controls,
                    ),
                  ),
                ),
                child: const Text('打开播放器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开播放器'));
    for (var index = 0; index < 7; index++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('暂时无法播放'), findsOneWidget);
    return (platform, repository);
  }

  iosTest(
    'failed mobile playback keeps a clickable back button without retrying',
    (tester) async {
      final (player, _) = await openFailedPlayer(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('返回').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('打开播放器'), findsOneWidget);
      expect(find.text('暂时无法播放'), findsNothing);
      expect(player.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fullscreen in [false, true]) {
    iosTest(
      'iOS edge swipe exits failed playback with fullscreen=$fullscreen',
      (tester) async {
        final (player, _) = await openFailedPlayer(tester);
        if (fullscreen) {
          await tester.tap(find.byTooltip('旋转与全屏').hitTestable());
          await tester.pumpAndSettle();
          expect(find.byTooltip('退出全屏').hitTestable(), findsOneWidget);
        }
        await tester.timedDragFrom(
          const Offset(1, 180),
          const Offset(320, 0),
          const Duration(milliseconds: 400),
        );
        await tester.pumpAndSettle();
        expect(find.text('打开播放器'), findsOneWidget);
        expect(find.text('暂时无法播放'), findsNothing);
        expect(player.disposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  iosTest('live playback errors also keep a working return button', (
    tester,
  ) async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    final playback = _LiveFixture(player)..failure = '合成直播错误';
    final store = LiveStore(await SharedPreferences.getInstance(), 'default')
      ..load();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push<void>(
                context,
                playerRoute(
                  LivePlayerScreen(
                    playback: playback,
                    source: LiveSource.values.first,
                    store: store,
                    onExit: () {},
                  ),
                ),
              ),
              child: const Text('打开直播'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开直播'));
    await tester.pumpAndSettle();
    expect(find.text('直播暂时中断'), findsOneWidget);
    expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('返回').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('打开直播'), findsOneWidget);
    playback.dispose();
    playback.repository.dispose();
    store.dispose();
    await player.dispose();
    expect(tester.takeException(), isNull);
  });
}
