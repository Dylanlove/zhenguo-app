package core

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

var xiaopingguoSortFilter = nativeCategoryFilter{Key: "sort", Name: "排序", Default: "最新", Values: []nativeCategory{
	{ID: "最新", Name: "最新"}, {ID: "最热", Name: "最热"}, {ID: "评分", Name: "评分"},
}}

var xiaopingguoCategories = []nativeCategory{
	{ID: "2", Name: "剧集", Filters: []nativeCategoryFilter{xiaopingguoSortFilter}},
	{ID: "1", Name: "电影", Filters: []nativeCategoryFilter{xiaopingguoSortFilter}},
	{ID: "3", Name: "综艺", Filters: []nativeCategoryFilter{xiaopingguoSortFilter}},
	{ID: "4", Name: "动漫", Filters: []nativeCategoryFilter{xiaopingguoSortFilter}},
	{ID: "5", Name: "短剧", Filters: []nativeCategoryFilter{xiaopingguoSortFilter}},
	{ID: "117", Name: "4K专区", Filters: []nativeCategoryFilter{{Key: "group", Name: "4K分组", Values: []nativeCategory{
		{Name: "全部"}, {ID: "4K大片", Name: "4K大片"}, {ID: "4K好剧", Name: "4K好剧"},
	}}}},
	{ID: "115", Name: "奈飞专区", Filters: []nativeCategoryFilter{xiaopingguoSortFilter, {Key: "area", Name: "地区", Values: []nativeCategory{
		{Name: "精选"}, {ID: "美国", Name: "美剧"}, {ID: "韩国", Name: "韩剧"}, {ID: "日本", Name: "日剧"}, {ID: "英国", Name: "英剧"},
	}}}},
}

var xiaopingguoURLPattern = regexp.MustCompile(`https?://[^\x00-\x20"'<>]+`)
var xiaopingguoEpisodePattern = regexp.MustCompile(`(?:第\s*)?([0-9]+)\s*[集话期]|^([0-9]+)$`)
var xiaopingguoMediaPattern = regexp.MustCompile(`(?i)\.(m3u8|mp4|mkv|flv|ts|m4s|avi|mov)([?#]|$)`)

type xiaopingguoRoute struct {
	Name    string
	Source  string
	Token   string
	Quality string
}

type xiaopingguoEpisode struct {
	Key     string
	Number  int
	Title   string
	Sources []xiaopingguoRoute
}

func providerCategoryPages(ctx context.Context, categories []nativeCategory, fetch func(context.Context, string) ([]Drama, bool, error)) ([]Drama, bool, error) {
	type result struct {
		items []Drama
		more  bool
		err   error
	}
	results := make([]result, len(categories))
	slots := make(chan struct{}, nativeCatalogFanoutWorkers)
	var group sync.WaitGroup
	for index, category := range categories {
		group.Add(1)
		go func(index int, category nativeCategory) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			results[index].items, results[index].more, results[index].err = fetch(ctx, category.ID)
		}(index, category)
	}
	group.Wait()
	items := []Drama{}
	seen := map[string]bool{}
	more := false
	var failures []error
	for _, result := range results {
		more = more || result.more || result.err != nil
		if result.err != nil {
			failures = append(failures, result.err)
		}
		for _, item := range result.items {
			if item.ID != "" && !seen[item.ID] {
				seen[item.ID] = true
				items = append(items, item)
			}
		}
	}
	return items, more, errors.Join(failures...)
}

func xiaopingguoCategoryName(id string) string {
	for _, category := range xiaopingguoCategories {
		if category.ID == id {
			return category.Name
		}
	}
	return ""
}

func xiaopingguoCleanText(value string) string {
	return strings.TrimSpace(html.UnescapeString(categoryTextPattern.ReplaceAllString(value, "")))
}

func parseXiaopingguoList(payload []byte, tag bool, category, group string) ([]Drama, error) {
	fields, err := xiaopingguoProto(payload)
	if err != nil {
		return nil, err
	}
	var records [][]byte
	for _, field := range fields {
		if field.wire != 2 {
			continue
		}
		if !tag && field.number == 1 {
			records = append(records, field.data)
		}
		if tag && field.number == 31 {
			children, err := xiaopingguoProto(field.data)
			if err != nil {
				return nil, err
			}
			if group != "" && xiaopingguoFlat(children)[1] != group {
				continue
			}
			for _, child := range children {
				if child.number == 5 && child.wire == 2 {
					records = append(records, child.data)
				}
			}
		}
	}
	items := []Drama{}
	seen := map[string]bool{}
	for _, record := range records {
		fields, err := xiaopingguoProto(record)
		if err != nil {
			return nil, err
		}
		row := xiaopingguoFlat(fields)
		id, title := row[3], strings.TrimSpace(row[5])
		if !webProviderNumericID.MatchString(id) || title == "" || seen[id] {
			continue
		}
		seen[id] = true
		cover := xiaopingguoURLPattern.FindString(row[2])
		items = append(items, Drama{ID: providerDramaID(sourceXiaopingguo, id), Source: sourceXiaopingguo,
			SourceID: id, Title: truncate(title, 512), Cover: cover, CoverURL: cover,
			Intro:        truncate(xiaopingguoCleanText(firstNonEmpty(row[4], row[13], row[26])), 12000),
			CategoryName: firstNonEmpty(xiaopingguoCategoryName(category), xiaopingguoCategoryName(row[9])),
			OnlineDate:   row[11], ChannelName: "小苹果"})
	}
	return items, nil
}

func (d *Downloader) fetchXiaopingguoCatalogPage(ctx context.Context, page int, selection, query string) ([]Drama, bool, error) {
	page = max(1, page)
	if query = strings.TrimSpace(query); query != "" {
		payload, err := d.xiaopingguoRequest(ctx, "/api/proto/v5/drama/search", []xiaopingguoParam{
			{"searchKeys", query}, {"page", strconv.Itoa(page)}, {"pagesize", "21"},
		})
		if err != nil {
			return nil, false, err
		}
		items, err := parseXiaopingguoList(payload, false, "", "")
		return items, len(items) >= 21, err
	}
	if selection == "" {
		return providerCategoryPages(ctx, xiaopingguoCategories, func(ctx context.Context, category string) ([]Drama, bool, error) {
			return d.fetchXiaopingguoCatalogPage(ctx, page, category, "")
		})
	}
	category, values, err := providerCategorySelection(xiaopingguoCategories, selection)
	if err != nil {
		return nil, false, err
	}
	id := category.ID
	if id == "117" || id == "115" && values.Get("area") == "" && page == 1 {
		if id == "117" && page > 1 {
			return []Drama{}, false, nil
		}
		payload, err := d.xiaopingguoRequest(ctx, "/api/proto/v4/tag/list/detail?pagesize=21&id="+id+"&page=1", nil)
		if err != nil {
			return nil, false, err
		}
		items, err := parseXiaopingguoList(payload, true, id, values.Get("group"))
		return items, id == "115", err
	}
	if id == "115" && values.Get("area") == "" {
		areas := []nativeCategory{{ID: "美国"}, {ID: "韩国"}, {ID: "日本"}, {ID: "英国"}}
		return providerCategoryPages(ctx, areas, func(ctx context.Context, area string) ([]Drama, bool, error) {
			return d.fetchXiaopingguoCatalogPage(ctx, page-1, "115?"+url.Values{"area": {area}, "sort": {values.Get("sort")}}.Encode(), "")
		})
	}
	params := []xiaopingguoParam{{"pagesize", "21"}, {"typeId1", id}, {"page", strconv.Itoa(page)}, {"vodOrderBy", values.Get("sort")}}
	if id == "115" {
		params[1].value = "2"
		params = append(params, xiaopingguoParam{"vodArea", values.Get("area")})
	}
	payload, err := d.xiaopingguoRequest(ctx, "/api/proto/v5/drama/category", params)
	if err != nil {
		return nil, false, err
	}
	items, err := parseXiaopingguoList(payload, false, id, "")
	return items, len(items) >= 21, err
}

func parseXiaopingguoDetail(payload []byte, id string) (Drama, []xiaopingguoEpisode, error) {
	fields, err := xiaopingguoProto(payload)
	if err != nil {
		return Drama{}, nil, err
	}
	metadata := []xiaopingguoField{}
	for _, field := range fields {
		if field.number != 29 {
			metadata = append(metadata, field)
		}
	}
	row := xiaopingguoFlat(metadata)
	cover := xiaopingguoURLPattern.FindString(row[2])
	drama := Drama{ID: providerDramaID(sourceXiaopingguo, id), Source: sourceXiaopingguo, SourceID: id,
		Title: truncate(strings.TrimSpace(row[9]), 512), Intro: truncate(xiaopingguoCleanText(row[6]), 12000),
		Cover: cover, CoverURL: cover, CategoryName: xiaopingguoCategoryName(row[15]), OnlineDate: row[18], ChannelName: "小苹果"}
	if drama.Title == "" {
		return Drama{}, nil, errors.New("小苹果详情缺少影片名称")
	}
	counts := map[string]int{}
	indices := map[string]int{}
	episodes := []xiaopingguoEpisode{}
	for _, field := range fields {
		if field.number != 29 || field.wire != 2 {
			continue
		}
		parts, err := xiaopingguoProto(field.data)
		if err != nil {
			return Drama{}, nil, err
		}
		route := xiaopingguoFlat(parts)
		source := firstNonEmpty(route[9], "Ksvideo")
		if strings.Contains(strings.ToLower(source), "youku") || route[4] == "" {
			continue
		}
		name := source
		if route[10] != "" {
			name += "·" + route[10]
		}
		counts[name]++
		title := firstNonEmpty(route[3], strconv.Itoa(counts[name]))
		number, _ := strconv.Atoi(route[13])
		match := xiaopingguoEpisodePattern.FindStringSubmatch(title)
		if number <= 0 && match != nil {
			number, _ = strconv.Atoi(firstNonEmpty(match[1], match[2]))
		}
		key := "episode:" + strconv.Itoa(number)
		if number <= 0 {
			number, key = counts[name], "special:"+title
		}
		if row[15] == "1" {
			number, key, title = 1, "movie", "正片"
		}
		index, exists := indices[key]
		if !exists {
			index = len(episodes)
			indices[key] = index
			episodes = append(episodes, xiaopingguoEpisode{Key: key, Number: number, Title: title})
		}
		episode := &episodes[index]
		duplicate := false
		for _, existing := range episode.Sources {
			duplicate = duplicate || existing.Source == source && existing.Token == route[4]
		}
		if !duplicate {
			episode.Sources = append(episode.Sources, xiaopingguoRoute{Name: name, Source: source, Token: route[4], Quality: route[10]})
		}
	}
	sort.SliceStable(episodes, func(i, j int) bool { return episodes[i].Number < episodes[j].Number })
	drama.TotalEpisode, drama.EpisodeCount = len(episodes), len(episodes)
	return drama, episodes, nil
}

func (d *Downloader) xiaopingguoDetail(ctx context.Context, id string) (Drama, []xiaopingguoEpisode, error) {
	if !webProviderNumericID.MatchString(id) {
		return Drama{}, nil, errors.New("小苹果影片标识无效")
	}
	payload, err := d.xiaopingguoRequest(ctx, xiaopingguoDetailPath, []xiaopingguoParam{{"id", id}})
	if err != nil {
		return Drama{}, nil, err
	}
	return parseXiaopingguoDetail(payload, id)
}

func (d *Downloader) fetchXiaopingguoDetail(ctx context.Context, id string) (Drama, []Chapter, error) {
	drama, episodes, err := d.xiaopingguoDetail(ctx, id)
	if err != nil {
		return drama, nil, err
	}
	chapters := []Chapter{}
	for _, episode := range episodes {
		code := base64.RawURLEncoding.EncodeToString([]byte(episode.Key))
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceXiaopingguo, id, code), Source: sourceXiaopingguo,
			Title: episode.Title, CurrentEpisode: rawEpisode(episode.Number), Referer: d.providerBaseURL(sourceXiaopingguo) + "/"})
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("小苹果未返回可播放分集")
	}
	return drama, chapters, nil
}

func (d *Downloader) resolveXiaopingguoMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, id, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceXiaopingguo, id, "")
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(task.Chapter.ID, prefix))
	if !valid || source != sourceXiaopingguo || !strings.HasPrefix(task.Chapter.ID, prefix) || err != nil {
		return providerMedia{}, errors.New("小苹果播放分集与影片不符，请刷新详情")
	}
	_, episodes, err := d.xiaopingguoDetail(ctx, id)
	if err != nil {
		return providerMedia{}, err
	}
	for _, episode := range episodes {
		if episode.Key != string(key) {
			continue
		}
		type result struct {
			media providerMedia
			err   error
		}
		results := make([]result, len(episode.Sources))
		slots := make(chan struct{}, 4)
		var group sync.WaitGroup
		for index, route := range episode.Sources {
			group.Add(1)
			go func(index int, route xiaopingguoRoute) {
				defer group.Done()
				select {
				case slots <- struct{}{}:
					defer func() { <-slots }()
				case <-ctx.Done():
					results[index].err = ctx.Err()
					return
				}
				results[index].media, results[index].err = d.resolveXiaopingguoRoute(ctx, route)
				results[index].media.RouteName = fmt.Sprintf("线路 %d", index+1)
			}(index, route)
		}
		group.Wait()
		var routes []providerMedia
		var failures []error
		for _, result := range results {
			if result.err != nil {
				failures = append(failures, result.err)
			} else {
				routes = append(routes, result.media)
			}
		}
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		if len(routes) == 0 {
			return providerMedia{}, fmt.Errorf("小苹果播放解析失败：%w", errors.Join(failures...))
		}
		media := routes[0]
		media.Variants = routes[1:]
		return media, nil
	}
	return providerMedia{}, errors.New("小苹果没有对应分集，请刷新详情")
}

func xiaopingguoDirectURL(raw string) string {
	address, err := url.Parse(raw)
	if err != nil || !isProviderHTTPMediaURL(raw) || address.User != nil {
		return ""
	}
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "response-content-disposition") || xiaopingguoMediaPattern.MatchString(raw) {
		return raw
	}
	if strings.Contains(lower, "/m3u8/") || strings.Contains(lower, "/hls/") || strings.Contains(lower, "m3u8?") ||
		strings.Contains(lower, "/api/banyun") || strings.Contains(lower, "/api/gongyou") {
		separator := "?"
		if address.RawQuery != "" {
			separator = "&"
		}
		return raw + separator + "ext=.m3u8"
	}
	return ""
}

func (d *Downloader) resolveXiaopingguoRoute(ctx context.Context, route xiaopingguoRoute) (providerMedia, error) {
	var address string
	agent, referer := xiaopingguoUserAgent, ""
	if route.Source == "RRSP" || strings.Contains(route.Token, "yichengwlkj.com") {
		var err error
		address, err = d.resolveXiaopingguoRRSP(ctx, route.Token)
		if err != nil {
			return providerMedia{}, err
		}
		agent, referer = xiaopingguoRRSPAgent, xiaopingguoRRSPReferer
	} else {
		payload, err := d.xiaopingguoRequest(ctx, "/api/proto/v5/videoUsableUrl", []xiaopingguoParam{
			{"vodPlayFrom", xiaopingguoURIComponent(route.Source)}, {"playUrl", xiaopingguoURIComponent(route.Token)},
		})
		if err == nil {
			address = xiaopingguoDirectURL(xiaopingguoURLPattern.FindString(string(payload)))
		}
		if address == "" {
			address = xiaopingguoDirectURL(route.Token)
		}
		if address == "" {
			if err != nil {
				return providerMedia{}, err
			}
			return providerMedia{}, fmt.Errorf("%s 未返回视频直链", route.Name)
		}
	}
	parsed, err := url.Parse(address)
	if err != nil || !isProviderHTTPMediaURL(address) || parsed.User != nil {
		return providerMedia{}, errors.New("小苹果播放地址无效")
	}
	return providerMedia{URL: address, Referer: referer, RouteName: route.Name,
		credentials: &providerMediaCredentials{origin: providerMediaOrigin(parsed), userAgent: agent, referer: referer, omitReferer: referer == ""}}, nil
}

func xiaopingguoURIComponent(raw string) string {
	encoded := strings.ReplaceAll(url.QueryEscape(raw), "+", "%20")
	return strings.NewReplacer("%21", "!", "%27", "'", "%28", "(", "%29", ")", "%2A", "*").Replace(encoded)
}
