package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type miguoHoneyItemKey struct {
	Module string `json:"module"`
	ID     string `json:"id"`
	Source string `json:"src"`
}

var miguoHoneySourcePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`)

func miguoHoneyKey(item miguoHoneyItemKey) string {
	payload, _ := json.Marshal(item)
	return base64.RawURLEncoding.EncodeToString(payload)
}

func miguoHoneyParseKey(key string) (miguoHoneyItemKey, error) {
	var item miguoHoneyItemKey
	payload, err := base64.RawURLEncoding.DecodeString(key)
	if err != nil || json.Unmarshal(payload, &item) != nil || item.ID == "" || len(item.ID) > 1024 || strings.ContainsAny(item.ID, "\x00\r\n") || !miguoHoneySourcePattern.MatchString(item.Source) {
		return item, errors.New("蜜果影片标识无效")
	}
	for _, category := range miguoHoneyCategories {
		if category.ID == item.Module {
			return item, nil
		}
	}
	return item, errors.New("蜜果影片频道无效")
}

func (d *Downloader) miguoHoneyCover(module, raw string) string {
	if raw == "" {
		return ""
	}
	base := d.providerBaseURL(sourceMiguoHoney)
	if module == "live" || strings.HasPrefix(raw, "/") || !strings.Contains(raw, "://") {
		return filmResolveURL(base+"/", raw)
	}
	return base + "/cover/" + url.PathEscape(module) + "?u=" + url.QueryEscape(raw)
}

func miguoHoneyCategoryName(module string) string {
	for _, category := range miguoHoneyCategories {
		if category.ID == module {
			return category.Name
		}
	}
	return ""
}

func (d *Downloader) miguoHoneyDrama(row map[string]any, item miguoHoneyItemKey) Drama {
	key := miguoHoneyKey(item)
	coverModule := item.Module
	if item.Module == "duanju" || item.Module == "hongtao" || item.Module == "hbo" {
		coverModule = item.Source
	}
	cover := d.miguoHoneyCover(coverModule, duanjuFindString(row, "cover_n", "cover"))
	intro := truncate(xiaopingguoCleanText(duanjuFindString(row, "desc", "description")), 12000)
	return Drama{ID: providerDramaID(sourceMiguoHoney, key), Source: sourceMiguoHoney, SourceID: key,
		Title: truncate(firstNonEmpty(duanjuFindString(row, "title", "name"), item.ID), 512), Intro: intro, Desc: intro,
		Cover: cover, CoverURL: cover, CategoryName: miguoHoneyCategoryName(item.Module),
		OnlineDate: duanjuFindString(row, "date"), Remark: duanjuFindString(row, "remark"),
		EpisodeCount: duanjuFindInt(row, "episode_count", "total_episode"), ChannelName: "蜜果"}
}

func (d *Downloader) fetchMiguoHoneyCatalogPage(ctx context.Context, page int, selection, query string) ([]Drama, bool, error) {
	page = max(1, page)
	query = strings.TrimSpace(query)
	if selection == "" {
		categories := miguoHoneyCategories
		if query != "" {
			categories = []nativeCategory{}
			for _, category := range miguoHoneyCategories {
				if category.ID != "live" && category.ID != "heiliao" {
					categories = append(categories, category)
				}
			}
		}
		return providerCategoryPages(ctx, categories, func(ctx context.Context, category string) ([]Drama, bool, error) {
			return d.fetchMiguoHoneyCatalogPage(ctx, page, category, query)
		})
	}
	category, values, err := providerCategorySelection(miguoHoneyCategories, selection)
	if err != nil {
		return nil, false, err
	}
	params, source := miguoHoneyModuleParams(category.ID, values)
	params.Set("page", strconv.Itoa(page))
	path := "/api/module"
	if query != "" {
		path = "/api/search"
		params = url.Values{"key": {category.ID}, "kw": {query}, "page": {strconv.Itoa(page)}}
	}
	response, err := d.miguoHoneyRequest(ctx, path, params)
	if err != nil {
		return nil, false, err
	}
	rows := duanjuMapList(response["list"])
	items := []Drama{}
	seen := map[string]bool{}
	for _, row := range rows {
		id := duanjuFindString(row, "id", "code")
		if id == "" {
			continue
		}
		itemSource := firstNonEmpty(duanjuFindString(row, "src"), source)
		item := miguoHoneyItemKey{Module: category.ID, ID: id, Source: itemSource}
		key := miguoHoneyKey(item)
		if _, err := miguoHoneyParseKey(key); err != nil || seen[key] {
			continue
		}
		seen[key] = true
		items = append(items, d.miguoHoneyDrama(row, item))
	}
	more, known := response["has_more"].(bool)
	if !known {
		if value, found := response["has_more"]; found {
			more = nativeText(value) == "1"
		} else if query != "" {
			more = len(rows) >= 10
		}
	}
	return items, more, nil
}

func miguoHoneyEpisodeLocked(row map[string]any) bool {
	locked, _ := row["lock"].(bool)
	return locked || nativeText(row["lock"]) == "1" || nativeText(row["lock"]) == "true"
}

func (d *Downloader) fetchMiguoHoneyDetail(ctx context.Context, key string) (Drama, []Chapter, error) {
	item, err := miguoHoneyParseKey(key)
	if err != nil {
		return Drama{}, nil, err
	}
	response, err := d.miguoHoneyRequest(ctx, "/api/detail/"+item.Module+"/"+url.PathEscape(item.ID), url.Values{"src": {item.Source}})
	if err != nil {
		return Drama{}, nil, err
	}
	row := duanjuFindMap(response, "detail")
	if len(row) == 0 {
		return Drama{}, nil, errors.New("蜜果未返回影片详情")
	}
	drama := d.miguoHoneyDrama(row, item)
	episodes := duanjuMapList(row["episodes"])
	if len(episodes) == 0 {
		episodes = []map[string]any{{"ep": "1", "name": "正片"}}
	}
	chapters := []Chapter{}
	seen := map[string]bool{}
	for index, episode := range episodes {
		code := firstNonEmpty(duanjuFindString(episode, "ep"), strconv.Itoa(index+1))
		if len(code) > 256 || strings.ContainsAny(code, "\x00\r\n") || seen[code] {
			continue
		}
		seen[code] = true
		number, err := strconv.Atoi(code)
		if err != nil || number < 1 {
			number = index + 1
		}
		title := firstNonEmpty(duanjuFindString(episode, "name"), fmt.Sprintf("第%d集", number))
		if _, err := strconv.Atoi(title); err == nil {
			title = "第" + title + "集"
		}
		locked := miguoHoneyEpisodeLocked(episode)
		if locked {
			title += " [试看10秒]"
		}
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceMiguoHoney, key, base64.RawURLEncoding.EncodeToString([]byte(code))),
			Source: sourceMiguoHoney, Title: title, CurrentEpisode: rawEpisode(number), VIP: locked, Referer: miguoHoneyReferer})
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("蜜果未返回有效分集")
	}
	drama.TotalEpisode, drama.EpisodeCount = len(chapters), len(chapters)
	return drama, chapters, nil
}

func (d *Downloader) resolveMiguoHoneyMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, key, valid := splitProviderDramaID(task.DramaID)
	item, err := miguoHoneyParseKey(key)
	prefix := providerChapterID(sourceMiguoHoney, key, "")
	code, decodeError := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(task.Chapter.ID, prefix))
	if !valid || source != sourceMiguoHoney || err != nil || !strings.HasPrefix(task.Chapter.ID, prefix) || decodeError != nil || len(code) == 0 || len(code) > 256 || strings.ContainsAny(string(code), "\x00\r\n") {
		return providerMedia{}, errors.New("蜜果播放分集与影片不符，请刷新详情")
	}
	response, err := d.miguoHoneyRequest(ctx, "/api/play/"+item.Module+"/"+url.PathEscape(item.ID)+"/"+url.PathEscape(string(code)), url.Values{"src": {item.Source}})
	if err != nil {
		return providerMedia{}, err
	}
	play := duanjuFindMap(response, "play")
	direct, proxy := duanjuFindString(play, "src"), duanjuFindString(play, "src_proxy")
	type route struct{ url, name string }
	routes := []route{{direct, "蜜果直连"}, {proxy, "蜜果代理"}}
	if strings.Contains(direct, "preview-r10") && proxy != "" {
		routes[0], routes[1] = routes[1], routes[0]
	}
	variants := []providerMedia{}
	seen := map[string]bool{}
	for _, route := range routes {
		if route.url == "" {
			continue
		}
		address := filmResolveURL(d.providerBaseURL(sourceMiguoHoney)+"/", route.url)
		parsed, err := url.Parse(address)
		if err != nil || !isProviderHTTPMediaURL(address) || parsed.User != nil || seen[address] {
			continue
		}
		seen[address] = true
		lower := strings.ToLower(address)
		if !strings.Contains(lower, ".m3u8") && !strings.Contains(lower, ".mp4") && !strings.Contains(lower, ".mpd") {
			separator := "?"
			if parsed.RawQuery != "" {
				separator = "&"
			}
			address += separator + "format=.m3u8"
		}
		referer := miguoHoneyReferer
		if strings.Contains(strings.ToLower(parsed.Hostname()), "hembed.com") || strings.Contains(strings.ToLower(parsed.Hostname()), "hanime") {
			referer = "https://hanime1.me/"
		}
		name := route.name
		if strings.Contains(lower, "preview-r10") || task.Chapter.VIP {
			name += " · 试看"
		}
		variants = append(variants, providerMedia{URL: address, Referer: referer, RouteName: name,
			credentials: &providerMediaCredentials{origin: providerMediaOrigin(parsed), userAgent: miguoHoneyUserAgent, referer: referer}})
	}
	if len(variants) == 0 {
		return providerMedia{}, errors.New("蜜果未返回可播放线路")
	}
	media := variants[0]
	media.Variants = variants[1:]
	return media, nil
}
