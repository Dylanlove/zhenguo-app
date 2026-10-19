import 'dart:async';

import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_series.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _SeriesRepository extends FixtureRepository {
  final pending = Completer<CatalogPage>();

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => pending.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = Drama(
    id: 'hongguo:first',
    source: 'hongguo',
    title: '合成系列 第一季',
  );
  const second = Drama(
    id: 'hongguo:second',
    source: 'hongguo',
    title: '合成系列 第二季',
  );

  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  test('系列发现只接收同一站源的季', () async {
    final local = await store();
    final repository = _SeriesRepository();
    final controller = PlayerSeriesController(
      repository: repository,
      store: local,
      anchor: first,
    );
    addTearDown(controller.dispose);
    addTearDown(local.dispose);
    final discovery = controller.discover();
    repository.pending.complete(
      CatalogPage([
        second,
        const Drama(
          id: 'huangdou:third',
          source: 'huangdou',
          title: '合成系列 第三季',
        ),
      ]),
    );
    await discovery;
    expect(controller.entries.map((entry) => entry.drama.id), [
      'hongguo:first',
      'hongguo:second',
    ]);
  });

  test('离开播放器后迟到的系列结果不会更新', () async {
    final local = await store();
    addTearDown(local.dispose);
    final repository = _SeriesRepository();
    final controller = PlayerSeriesController(
      repository: repository,
      store: local,
      anchor: first,
    );
    final discovery = controller.discover();
    controller.dispose();
    repository.pending.complete(CatalogPage([second]));
    await discovery;
    expect(controller.entries, isEmpty);
  });

  testWidgets('选季回调保留真实剧目 ID，当前季不能重复选择', (tester) async {
    Drama? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerSeriesBar(
            entries: const [
              HongguoSeriesEntry(drama: first, season: 1, unit: '季'),
              HongguoSeriesEntry(drama: second, season: 2, unit: '季'),
            ],
            currentDramaId: first.id,
            onSelected: (drama) => selected = drama,
          ),
        ),
      ),
    );
    final current = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('player-season-hongguo:first')),
    );
    expect(current.onSelected, isNull);
    await tester.tap(
      find.byKey(const ValueKey('player-season-hongguo:second')),
    );
    expect(selected?.id, second.id);
  });
}
