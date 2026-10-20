package core

import "net/url"

var miguoHoneyCategories = []nativeCategory{
	{ID: "video", Name: "蜜果视频", Filters: []nativeCategoryFilter{{Key: "cat", Name: "分类", Default: "new", Values: []nativeCategory{
		{ID: "new", Name: "最近更新"}, {ID: "release", Name: "新作上市"}, {ID: "chinese-subtitle", Name: "中文字幕"},
		{ID: "madou", Name: "麻豆传媒"}, {ID: "uncensored-leak", Name: "无码流出"}, {ID: "fc2", Name: "FC2"},
		{ID: "monthly-hot", Name: "热门"}, {ID: "genres/VR", Name: "VR"}, {ID: "heyzo", Name: "HEYZO"},
		{ID: "tokyohot", Name: "东京热"}, {ID: "1pondo", Name: "一本道"}, {ID: "caribbeancom", Name: "Caribbeancom"},
		{ID: "caribbeancompr", Name: "Caribbeancompr"}, {ID: "siro", Name: "SIRO"}, {ID: "luxu", Name: "LUXU"},
		{ID: "twav", Name: "TWAV"}, {ID: "furuke", Name: "Furuke"}, {ID: "today-hot", Name: "今日热门"}, {ID: "weekly-hot", Name: "本周热门"},
	}}}},
	{ID: "duanju", Name: "蜜果短剧", Filters: []nativeCategoryFilter{
		{Key: "cat", Name: "厂牌分类", Default: "huangtao", Values: []nativeCategory{
			{ID: "huangtao", Name: "黄桃短剧"}, {ID: "huangguo", Name: "黄果短剧"}, {ID: "yeguo", Name: "野果短剧"},
			{ID: "chengguo", Name: "橙果短剧"}, {ID: "yizk", Name: "一直看短剧"}, {ID: "huangdou", Name: "黄豆短剧"},
			{ID: "chiguo", Name: "赤果短剧"}, {ID: "pengran", Name: "怦然心动"}, {ID: "erciyuan", Name: "动漫"},
			{ID: "jinbi", Name: "金币专区"}, {ID: "huiyuan", Name: "会员专区"},
		}},
		{Key: "sub", Name: "二级筛选", Default: "0", Values: []nativeCategory{
			{ID: "0", Name: "全部 / 精选 / 推荐"}, {ID: "1", Name: "子类1（AI短剧 / 野果原创 / 黄豆原创 / 热门好剧 / 国漫）"},
			{ID: "2", Name: "子类2（AI漫剧 / 真人短剧 / UP原创 / 民国风月 / 日漫）"},
			{ID: "3", Name: "子类3（魔改漫剧 / 大神精选 / 悬疑惊悚 / 动画同人）"},
			{ID: "4", Name: "子类4（网红改编 / 单体作品 / 同人魔改 / 游戏同人）"},
			{ID: "5", Name: "子类5（影视魔改 / 古典风月 / 排行榜）"}, {ID: "6", Name: "子类6（国漫AI / 都市艳遇）"},
			{ID: "7", Name: "子类7（魔改短剧 / 恋爱情感）"}, {ID: "8", Name: "子类8（爆爽逆袭）"},
			{ID: "9", Name: "子类9（职场沉浮）"}, {ID: "10", Name: "子类10（家庭伦理）"}, {ID: "11", Name: "子类11（奇幻修仙）"},
		}},
	}},
	{ID: "hongtao", Name: "红桃短剧", Filters: []nativeCategoryFilter{
		{Key: "cat", Name: "频道", Default: "zhenren", Values: []nativeCategory{
			{ID: "zhenren", Name: "红桃原创"}, {ID: "tc", Name: "甜宠言情"}, {ID: "nx", Name: "逆袭爽剧"},
			{ID: "gz", Name: "古装传奇"}, {ID: "ds", Name: "都市生活"}, {ID: "xh", Name: "玄幻奇幻"},
			{ID: "xy", Name: "悬疑热血"}, {ID: "manju", Name: "正经漫剧"}, {ID: "unclassified", Name: "未分类短剧"},
		}},
		{Key: "sub", Name: "题材", Default: "0", ParentKey: "cat", ParentValues: []string{"zhenren"}, Values: []nativeCategory{
			{ID: "0", Name: "都市"}, {ID: "1", Name: "古装"}, {ID: "2", Name: "民国"}, {ID: "3", Name: "重生"}, {ID: "4", Name: "异能"},
		}},
	}},
	{ID: "caibian", Name: "擦边短剧", Filters: []nativeCategoryFilter{{Key: "cat", Name: "排序", Default: "0", Values: []nativeCategory{
		{ID: "0", Name: "最新"}, {ID: "1", Name: "推荐"}, {ID: "2", Name: "全部"},
	}}}},
	{ID: "shortv", Name: "蜜果动漫", Filters: []nativeCategoryFilter{{Key: "cat", Name: "源频道", Default: "all", Values: []nativeCategory{
		{ID: "all", Name: "全部"}, {ID: "Hanime", Name: "Hanime"}, {ID: "NaughtyMachinima", Name: "NaughtyMachinima"}, {ID: "HS日本4K动漫", Name: "HS日本4K动漫"},
	}}}},
	{ID: "guochan", Name: "国产精品"},
	{ID: "heiliao", Name: "黑料吃瓜", Filters: []nativeCategoryFilter{{Key: "cat", Name: "频道", Default: "0", Values: []nativeCategory{
		{ID: "0", Name: "最新"}, {ID: "1", Name: "推荐"},
	}}}},
	{ID: "hbo", Name: "HBO精选", Filters: []nativeCategoryFilter{{Key: "cat", Name: "剧集类型", Default: "meiju", Values: []nativeCategory{
		{ID: "meiju", Name: "美剧"}, {ID: "hanju", Name: "韩剧"},
	}}}},
	{ID: "live", Name: "蜜果直播", Filters: []nativeCategoryFilter{{Key: "cat", Name: "分类与地区", Default: "girls", Values: []nativeCategory{
		{ID: "girls", Name: "女主播"}, {ID: "couples", Name: "情侣"}, {ID: "men", Name: "男主播"}, {ID: "trans", Name: "跨性别"},
		{ID: "cn", Name: "中国"}, {ID: "jp", Name: "日本"}, {ID: "kr", Name: "韩国"}, {ID: "us", Name: "美国"},
		{ID: "th", Name: "泰国"}, {ID: "vn", Name: "越南"}, {ID: "ru", Name: "俄罗斯"},
	}}}},
}

func miguoHoneyModuleParams(module string, values url.Values) (url.Values, string) {
	params := url.Values{"key": {module}}
	source := "huangdou"
	category := values.Get("cat")
	if category != "" {
		params.Set("cat", category)
	}
	switch module {
	case "duanju":
		source = "duoju86"
		switch category {
		case "huangguo", "chiguo", "pengran":
			source = category
		case "huangdou", "erciyuan", "jinbi", "huiyuan":
			source = "huangdou"
		}
		params.Set("src", source)
		params.Set("sub", firstNonEmpty(values.Get("sub"), "0"))
	case "hongtao":
		source = "duoju89"
		if category == "zhenren" || category == "manju" {
			source = "huangdou"
		}
		params.Set("src", source)
		params.Set("sub", firstNonEmpty(values.Get("sub"), "0"))
	case "hbo":
		params.Set("src", source)
		params.Set("sub", "0")
	case "caibian":
		params.Set("src", source)
		params.Set("nav", "caibian")
		params.Set("sub", category)
	case "guochan":
		source = "guochan"
		params.Set("src", source)
	case "video":
		source = "missav"
		params.Set("src", source)
	case "shortv":
		source = "dongman"
		params.Set("src", source)
	}
	return params, source
}
