class SourceCapabilities {
  const SourceCapabilities({
    this.onlineSearch = false,
    this.searchPaging = false,
    this.catalogPaging = false,
    this.suggestions = false,
    this.categories = false,
    this.rankings = false,
    this.recommendations = false,
    this.film = false,
    this.fingerprint = '',
  });

  final bool onlineSearch,
      searchPaging,
      catalogPaging,
      suggestions,
      categories,
      rankings,
      recommendations,
      film;
  final String fingerprint;

  factory SourceCapabilities.fromJson(Map<String, dynamic> data) {
    const flags = [
      'onlineSearch',
      'searchPaging',
      'catalogPaging',
      'suggestions',
      'categories',
      'rankings',
      'recommendations',
      'film',
    ];
    if (flags.any((key) => data[key] is! bool) ||
        data['fingerprint'] is! String ||
        !RegExp(r'^[a-f0-9]{16}$').hasMatch(data['fingerprint'] as String)) {
      throw const FormatException('站源能力描述无效');
    }
    return SourceCapabilities(
      onlineSearch: data['onlineSearch'] == true,
      searchPaging: data['searchPaging'] == true,
      catalogPaging: data['catalogPaging'] == true,
      suggestions: data['suggestions'] == true,
      categories: data['categories'] == true,
      rankings: data['rankings'] == true,
      recommendations: data['recommendations'] == true,
      film: data['film'] == true,
      fingerprint: data['fingerprint'] as String,
    );
  }

  List<String> get labels => [
    if (onlineSearch) '在线搜索' else '已加载内容筛选',
    if (searchPaging) '搜索分页',
    if (suggestions) '搜索联想',
    if (rankings) '榜单',
    if (recommendations) '推荐',
  ];
}
