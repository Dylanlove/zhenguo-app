import 'core_bridge.dart';
import 'live_models.dart';

class YspLiveClient {
  YspLiveClient(this.repository);

  final AppRepository repository;

  Future<Map<String, dynamic>> status() => repository.ysp('status', const {});

  Future<List<LiveChannel>> channels() async {
    final result = await repository.ysp('channels', const {});
    final rows = result['items'] as List? ?? const [];
    return [
      for (final (index, value) in rows.indexed)
        if (value is Map)
          LiveChannel(
            key: LiveChannel.makeKey(
              'ysp',
              '${value['group']}',
              '${value['id']}',
            ),
            name: '${value['name']}',
            urls: ['ysp://${value['id']}'],
            number: (index + 1).toString().padLeft(3, '0'),
            group: '${value['group']}',
            logo:
                'https://garysclub.sharewithyou.dpdns.org/logos/ysp-live-logos/${value['id']}.png',
            source: 'ysp',
            token: '${value['id']}',
            tvgId: '${value['tvgId']}',
            catchup: value['catchup'] == true,
            subtitle: value['ultra'] == true ? '4K 超高清' : '',
          ),
    ];
  }

  Future<LivePlayback> playback(
    LiveChannel channel, {
    String quality = 'auto',
    DateTime? start,
    DateTime? end,
  }) async {
    final result = await repository.ysp('playback', {
      'channel': channel.token,
      'quality': quality,
      if (start != null) 'start': start.millisecondsSinceEpoch ~/ 1000,
      if (end != null) 'end': end.millisecondsSinceEpoch ~/ 1000,
    });
    final url = result['url'] as String? ?? '';
    if (!isPlayableLiveUrl(url)) throw AppFailure('央视频播放地址无效');
    return LivePlayback(url: url);
  }

  Future<Map<String, dynamic>> configure({
    required String quality,
    required bool share,
    required int port,
  }) => repository.ysp('configure', {
    'quality': quality,
    'share': share,
    'port': port,
  });

  Future<Map<String, dynamic>> rules() => repository.ysp('rules', const {});

  Future<void> stop() async {
    await repository.ysp('stop', const {});
  }

  Future<void> release() async {
    await repository.ysp('idle', const {});
  }
}

String yspQualityLabel(String quality) => switch (quality) {
  'best' => '4K / 高码率',
  'hd' => '1080p 优先',
  _ => '自动画质',
};
