import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/catalog_browser.dart';
import 'package:duanju_app/catalog_filters.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'remote_test_helpers.dart';

final importedCategory = CatalogCategory.fromJson({
  'id': 'video',
  'name': '蜜果视频',
  'filters': [
    {
      'key': 'cat',
      'name': '分类',
      'default': 'new',
      'values': [
        {'id': 'new', 'name': '最近更新'},
        {'id': 'fc2', 'name': 'FC2'},
        {'id': 'genres/VR', 'name': 'VR'},
      ],
    },
  ],
});

class ImportedSourceRepository extends FixtureRepository {
  final categoryRequests = <String>[];

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => [CatalogCategory.all, importedCategory];

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(
        category.isEmpty
            ? const [
                Drama(
                  id: 'miguo-honey:unfiltered',
                  source: 'miguo-honey',
                  title: '已缓存内容',
                  category: '蜜果视频',
                ),
              ]
            : [],
      );

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    categoryRequests.add(category);
    return CatalogPage(
      [
        Drama(
          id: 'miguo-honey:filtered',
          source: source,
          title: '筛选结果',
          category: '蜜果视频',
        ),
      ],
      page: page,
      hasMore: page == 1,
    );
  }
}

void main() {
  test(
    'imported sources retain grouping, edition gates and separate identities',
    () {
      expect(SourceSite.xiaopingguo.adult, isFalse);
      expect(SourceSite.miguoHoney.adult, isTrue);
      expect(SourceSite.miguoHoney.name, '蜜果');
      expect(SourceSite.byId('miguo').name, '米果');
      for (final source in [SourceSite.xiaopingguo, SourceSite.miguoHoney]) {
        expect(source.filmSource, isTrue);
        expect(source.pagedSearch, isTrue);
        expect(SourceSite.isAvailable(source.id), allSourcesEnabled);
      }
      expect(
        SourceSite.knownValues.where((source) => !source.adult).last,
        SourceSite.xiaopingguo,
      );
      expect(SourceSite.knownValues.last, SourceSite.miguoHoney);
    },
  );

  test(
    'category filters preserve encoded values and remove inactive subfilters',
    () {
      final selection = importedCategory.selection({'cat': 'genres/VR'});
      expect(selection, 'video?cat=genres%2FVR');
      expect(importedCategory.filterValues(selection), {'cat': 'genres/VR'});
      expect(importedCategory.selection({'cat': 'new'}), 'video');
      final dependent = CatalogCategory.fromJson({
        'id': 'hongtao',
        'name': '红桃短剧',
        'filters': [
          {
            'key': 'cat',
            'name': '频道',
            'default': 'zhenren',
            'values': [
              {'id': 'zhenren', 'name': '原创'},
              {'id': 'tc', 'name': '甜宠'},
            ],
          },
          {
            'key': 'sub',
            'name': '题材',
            'default': '0',
            'parentKey': 'cat',
            'parentValues': ['zhenren'],
            'values': [
              {'id': '0', 'name': '都市'},
              {'id': '1', 'name': '古装'},
            ],
          },
        ],
      });
      expect(dependent.selection({'cat': 'tc', 'sub': '1'}), 'hongtao?cat=tc');
      expect(dependent.filterValues('hongtao?cat=tc&sub=1'), {'cat': 'tc'});
      expect(dependent.filterValues('hongtao?sub=1'), {
        'cat': 'zhenren',
        'sub': '1',
      });
    },
  );

  test(
    'browser forwards subfilters and keeps unfiltered cached rows out',
    () async {
      final repository = ImportedSourceRepository();
      final browser = CatalogBrowser(repository);
      const group = SourceGroup('miguo-honey', '蜜果', [SourceSite.miguoHoney]);
      await browser.loadCategories(group);
      final category = browser
          .categories(group)
          .firstWhere((category) => category.name == '蜜果视频');
      expect(category.filters, hasLength(1));
      final selection = category.selection({'cat': 'genres/VR'});
      final result = await browser.load(group, category: selection);
      expect(repository.categoryRequests, ['video?cat=genres%2FVR']);
      expect(result.items.map((item) => item.id), ['miguo-honey:filtered']);
      await browser.load(group, category: selection, more: true);
      expect(repository.categoryRequests.last, 'video?cat=genres%2FVR');
    },
  );

  testWidgets(
    'source filter sheet applies a selection and restores the category chip',
    (tester) async {
      var selection = 'video';
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: CatalogFilters(
                categories: [importedCategory],
                category: selection,
                onCategory: (value) => update(() => selection = value),
                onRetry: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('分类筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'VR'));
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(selection, 'video?cat=genres%2FVR');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '蜜果视频'))
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('television remote can reach the source filter button', (
    tester,
  ) async {
    await tester.pumpWidget(
      televisionHost(
        child: Scaffold(
          body: CatalogFilters(
            categories: [importedCategory],
            category: 'video',
            remoteAutofocus: true,
            onCategory: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focusRemote(tester, find.byKey(const ValueKey('category-video')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('蜜果视频筛选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
