package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

const (
	sourceA123    = "a123"
	a123BaseURL   = "https://a123tv.com"
	a123UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

var a123Categories = []nativeCategory{
	{ID: "10", Name: "电影"},
	{ID: "11", Name: "连续剧"},
	{ID: "12", Name: "综艺"},
	{ID: "13", Name: "动漫"},
	{ID: "15", Name: "福利"},
}

var a123Identifier = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)
var a123PPStart = regexp.MustCompile(`\bvar\s+pp\s*=\s*`)

type a123Playback struct {
	No string              `json:"no"`
	LD string              `json:"ld"`
	LA [][]json.RawMessage `json:"la"`
}

func a123PagePath(pageURL, reference, slug string, episode bool) string {
	base, err := url.Parse(pageURL)
	if err != nil || reference == "" {
		return ""
	}
	address, err := url.Parse(filmResolveURL(pageURL, reference))
	if err != nil || address.User != nil || providerMediaOrigin(address) != providerMediaOrigin(base) || address.RawQuery != "" || address.Fragment != "" {
		return ""
	}
	parts := strings.Split(strings.TrimPrefix(address.Path, "/v/"), "/")
	if !strings.HasPrefix(address.Path, "/v/") || !strings.HasSuffix(address.Path, ".html") {
		return ""
	}
	if episode {
		if len(parts) != 2 || parts[0] != slug || !a123Identifier.MatchString(strings.TrimSuffix(parts[1], ".html")) {
			return ""
		}
	} else if len(parts) != 1 || !a123Identifier.MatchString(strings.TrimSuffix(parts[0], ".html")) {
		return ""
	}
	return address.Path
}

func parseA123Cards(document *html.Node, pageURL, category string) []Drama {
	items := []Drama{}
	seen := map[string]bool{}
	for _, card := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "a" && providerHTMLClass(node, "w4-item") }) {
		path := a123PagePath(pageURL, providerHTMLAttr(card, "href"), "", false)
		if path == "" {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/v/"), ".html")
		if seen[id] {
			continue
		}
		titleNode := providerHTMLFirstClass(card, "t")
		title := firstNonEmpty(providerHTMLAttr(titleNode, "title"), providerHTMLText(titleNode))
		cover := ""
		for _, image := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "img" }) {
			title = firstNonEmpty(title, providerHTMLAttr(image, "alt"))
			cover = firstNonEmpty(cover, providerCoverAddress(providerHTMLAttr(image, "data-src"), pageURL), providerCoverAddress(providerHTMLAttr(image, "src"), pageURL))
		}
		if title == "" {
			continue
		}
		seen[id] = true
		remark := providerHTMLText(providerHTMLFirstClass(card, "i"))
		kind, _, _ := strings.Cut(remark, "/")
		items = append(items, Drama{ID: providerDramaID(sourceA123, id), Source: sourceA123, SourceID: id,
			Title: truncate(title, 512), Name: truncate(title, 512), Cover: cover, CoverURL: cover,
			ChannelName: "A123TV", CategoryName: firstNonEmpty(strings.TrimSpace(kind), category), Remark: truncate(remark, 128)})
	}
	return items
}

func (d *Downloader) fetchA123CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if page < 1 || page > 100000 || len(query) > 256 || !validFilmCategory(a123Categories, category) {
		return nil, false, errors.New("A123TV 目录查询参数无效")
	}
	if page > 1 && (category == "" || query != "") {
		return []Drama{}, false, nil
	}
	path, categoryName := "/", ""
	if query != "" {
		path = "/s/" + url.PathEscape(query) + ".html"
	} else if category != "" {
		path = "/t/" + category
		if page > 1 {
			path += "/p" + strconv.Itoa(page)
		}
		path += ".html"
		for _, item := range a123Categories {
			if item.ID == category {
				categoryName = item.Name
			}
		}
	}
	body, pageURL, err := d.fetchFilmText(ctx, sourceA123, path, "")
	if err != nil {
		return nil, false, err
	}
	document, err := filmDocument(body)
	if err != nil {
		return nil, false, err
	}
	items := parseA123Cards(document, pageURL, categoryName)
	if len(items) == 0 && (query == "" || len(providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "main" })) == 0) {
		return nil, false, errors.New("A123TV 未返回有效影视列表，请稍后重试")
	}
	more := false
	if category != "" && query == "" {
		pagination := providerHTMLFirstClass(document, "w4-page")
		for _, node := range providerHTMLNodes(pagination, func(node *html.Node) bool { return providerHTMLAttr(node, "aria-current") == "page" }) {
			if providerHTMLText(node) != strconv.Itoa(page) {
				return nil, false, errors.New("A123TV 返回的目录页码与请求不符")
			}
		}
		for _, anchor := range providerHTMLNodes(pagination, func(node *html.Node) bool { return node.Data == "a" }) {
			href := providerHTMLAttr(anchor, "href")
			prefix := "/t/" + category + "/p"
			if strings.HasPrefix(href, prefix) && strings.HasSuffix(href, ".html") {
				number, _ := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(href, prefix), ".html"))
				more = more || number > page
			}
		}
	}
	return items, more, nil
}

func parseA123Playback(document *html.Node, sourceID string) (a123Playback, error) {
	for _, script := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "script" }) {
		if script.FirstChild == nil {
			continue
		}
		body := script.FirstChild.Data
		start := a123PPStart.FindStringIndex(body)
		if start == nil {
			continue
		}
		var playback a123Playback
		if json.NewDecoder(strings.NewReader(body[start[1]:])).Decode(&playback) != nil {
			return playback, errors.New("A123TV 播放参数无法解析")
		}
		if playback.No != sourceID || !a123Identifier.MatchString(playback.LD) {
			return playback, errors.New("A123TV 播放页与请求影片不符")
		}
		return playback, nil
	}
	return a123Playback{}, errors.New("A123TV 播放页缺少线路参数，请刷新详情重试")
}

func (d *Downloader) fetchA123Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !a123Identifier.MatchString(sourceID) {
		return Drama{}, nil, errors.New("A123TV 影片标识无效")
	}
	body, pageURL, err := d.fetchFilmText(ctx, sourceA123, "/v/"+sourceID+".html", "")
	if err != nil {
		return Drama{}, nil, err
	}
	document, err := filmDocument(body)
	if err != nil {
		return Drama{}, nil, err
	}
	if _, err := parseA123Playback(document, sourceID); err != nil {
		return Drama{}, nil, err
	}
	title := ""
	for _, heading := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "h1" }) {
		title = providerHTMLText(heading)
		break
	}
	player := providerHTMLFirstClass(document, "w4-player")
	if title == "" {
		title, _, _ = strings.Cut(providerHTMLAttr(player, "data-title"), " - ")
	}
	if title == "" {
		return Drama{}, nil, errors.New("A123TV 详情缺少影片名称")
	}
	cover := providerCoverAddress(firstNonEmpty(providerHTMLAttr(player, "data-poster"), filmMeta(document, "og:image")), pageURL)
	description := filmMeta(document, "description", "og:description")
	drama := Drama{ID: providerDramaID(sourceA123, sourceID), Source: sourceA123, SourceID: sourceID,
		Title: truncate(title, 512), Name: truncate(title, 512), Cover: cover, CoverURL: cover,
		Desc: truncate(description, 12000), Intro: truncate(description, 12000), ChannelName: "A123TV"}
	list := providerHTMLFirstClass(document, "w4-episode-list")
	chapters := []Chapter{}
	seen := map[string]bool{}
	used := map[int]bool{}
	for _, anchor := range providerHTMLNodes(list, func(node *html.Node) bool { return node.Data == "a" }) {
		path := a123PagePath(pageURL, providerHTMLAttr(anchor, "href"), sourceID, true)
		if path == "" || seen[path] {
			continue
		}
		seen[path] = true
		name := firstNonEmpty(providerHTMLAttr(anchor, "title"), providerHTMLText(anchor))
		number := nextUnusedEpisodeIndex(episodeIndex(name, len(chapters)+1), used)
		used[number] = true
		code := strings.TrimSuffix(strings.TrimPrefix(path, "/v/"+sourceID+"/"), ".html")
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceA123, sourceID, code), Source: sourceA123,
			Title: firstNonEmpty(name, fmt.Sprintf("第%d集", number)), CurrentEpisode: rawEpisode(number),
			PageURL: filmResolveURL(pageURL, path), Referer: pageURL})
	}
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("A123TV 详情没有可播放分集，请稍后重试")
	}
	drama.TotalEpisode, drama.EpisodeCount = len(chapters), len(chapters)
	return drama, chapters, nil
}

func (d *Downloader) resolveA123Media(ctx context.Context, task Task) (providerMedia, error) {
	source, id, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceA123, id, "")
	code := strings.TrimPrefix(task.Chapter.ID, prefix)
	if !valid || source != sourceA123 || !a123Identifier.MatchString(id) || !strings.HasPrefix(task.Chapter.ID, prefix) || !a123Identifier.MatchString(code) {
		return providerMedia{}, errors.New("A123TV 播放分集与影片不符，请刷新详情")
	}
	path := "/v/" + id + "/" + code + ".html"
	ctx = context.WithValue(ctx, providerTextNoCacheKey{}, true)
	body, pageURL, err := d.fetchFilmText(ctx, sourceA123, path, d.providerBaseURL(source)+"/v/"+id+".html")
	if err != nil {
		return providerMedia{}, err
	}
	document, err := filmDocument(body)
	if err != nil {
		return providerMedia{}, err
	}
	playback, err := parseA123Playback(document, id)
	if err != nil {
		return providerMedia{}, err
	}
	if !strings.HasPrefix(code, playback.LD+"z") {
		return providerMedia{}, errors.New("A123TV 返回的播放线路与分集不符")
	}
	expected, err := strconv.Atoi(strings.TrimPrefix(code, playback.LD+"z"))
	if err != nil || expected < 0 {
		return providerMedia{}, errors.New("A123TV 播放分集参数无效")
	}
	type routeEntry struct {
		code    string
		address string
	}
	routes := []routeEntry{}
	matched := false
	for _, row := range playback.LA {
		if len(row) < 5 {
			continue
		}
		var route, address string
		var count, index int
		if json.Unmarshal(row[0], &route) != nil || json.Unmarshal(row[2], &count) != nil || json.Unmarshal(row[3], &index) != nil || json.Unmarshal(row[4], &address) != nil {
			continue
		}
		if index == expected && count > index {
			routes = append(routes, routeEntry{code: route, address: address})
			matched = matched || route == playback.LD
		}
	}
	if !matched {
		return providerMedia{}, errors.New("A123TV 返回的集数与所选分集不符，请刷新详情")
	}
	options := []providerMedia{}
	seen := map[string]bool{}
	add := func(raw string) {
		if address := filmMediaURL(raw, pageURL); address != "" && !seen[address] {
			seen[address] = true
			options = append(options, d.filmMedia(source, address, pageURL))
		}
	}
	player := providerHTMLFirstClass(document, "w4-player")
	add(providerHTMLAttr(player, "data-src"))
	for _, current := range []bool{true, false} {
		for _, route := range routes {
			if (route.code == playback.LD) == current {
				add(route.address)
			}
		}
	}
	if len(options) == 0 {
		return providerMedia{}, errors.New("A123TV 该集暂无可用的 MP4 或 M3U8 线路，请稍后重试")
	}
	media := options[0]
	media.Variants = options
	return media, nil
}
