package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

const (
	sourceIkanbot    = "ikanbot"
	ikanbotBaseURL   = "https://www1.ikanbot.com"
	ikanbotUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

var ikanbotCategories = []nativeCategory{
	{ID: "movie-热门", Name: "热门电影"},
	{ID: "tv-热门", Name: "热门剧集"},
	{ID: "tv-国产剧", Name: "国产剧"},
	{ID: "tv-日剧", Name: "日剧"},
	{ID: "tv-韩剧", Name: "韩剧"},
	{ID: "tv-美剧", Name: "美剧"},
	{ID: "tv-英剧", Name: "英剧"},
	{ID: "tv-港剧", Name: "港剧"},
	{ID: "tv-日本动画", Name: "日本动画"},
	{ID: "tv-综艺", Name: "综艺"},
	{ID: "tv-纪录片", Name: "纪录片"},
}

var ikanbotPageNumber = regexp.MustCompile(`-p-([0-9]+)\.html$`)
var ikanbotBareNumber = regexp.MustCompile(`^[0-9]{1,8}$`)

type ikanbotEpisode struct {
	key     string
	title   string
	address string
	number  int
}

type ikanbotLine struct {
	name     string
	episodes []ikanbotEpisode
}

type ikanbotDetail struct {
	drama   Drama
	token   string
	mtype   string
	pageURL string
	lines   []ikanbotLine
}

func validIkanbotID(id string) bool {
	return len(id) >= 4 && len(id) <= 12 && webProviderNumericID.MatchString(id)
}

func ikanbotToken(id, seed string) (string, error) {
	if !validIkanbotID(id) {
		return "", errors.New("爱看机器人影片 ID 无效")
	}
	var signed strings.Builder
	offset := 0
	for _, digit := range id[len(id)-4:] {
		offset += int(digit-'0')%3 + 1
		if offset+8 > len(seed) {
			return "", errors.New("爱看机器人播放令牌缺失或无效，请刷新详情重试")
		}
		signed.WriteString(seed[offset : offset+8])
		offset += 8
	}
	return signed.String(), nil
}

func ikanbotCardID(reference string) string {
	if !strings.HasPrefix(reference, "/play/") {
		return ""
	}
	id := strings.TrimPrefix(reference, "/play/")
	if !validIkanbotID(id) {
		return ""
	}
	return id
}

func parseIkanbotCards(document *html.Node, pageURL, category string, search bool) []Drama {
	items := []Drama{}
	seen := map[string]bool{}
	cards := providerHTMLNodes(document, func(node *html.Node) bool {
		if search {
			return providerHTMLClass(node, "media")
		}
		return node.Data == "a" && providerHTMLClass(node, "item")
	})
	for _, card := range cards {
		id := ikanbotCardID(providerHTMLAttr(card, "href"))
		if search {
			for _, anchor := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
				if id = ikanbotCardID(providerHTMLAttr(anchor, "href")); id != "" {
					break
				}
			}
		}
		if id == "" || seen[id] {
			continue
		}
		title, cover := "", ""
		for _, image := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "img" }) {
			title = firstNonEmpty(title, providerHTMLAttr(image, "alt"))
			cover = firstNonEmpty(cover, providerCoverAddress(providerHTMLAttr(image, "data-src"), pageURL))
		}
		if search {
			title = firstNonEmpty(providerHTMLText(providerHTMLFirstClass(card, "title-text")), title)
		}
		if title == "" {
			for _, node := range providerHTMLNodes(card, func(node *html.Node) bool { return node.Data == "p" }) {
				title = providerHTMLText(node)
				break
			}
		}
		if title == "" {
			continue
		}
		seen[id] = true
		kind := "剧集"
		if strings.HasPrefix(category, "movie-") {
			kind = "电影"
		}
		items = append(items, Drama{ID: providerDramaID(sourceIkanbot, id), Source: sourceIkanbot, SourceID: id,
			Title: truncate(title, 512), Name: truncate(title, 512), Cover: cover, CoverURL: cover,
			ChannelName: "爱看机器人", CategoryName: kind,
			Desc: providerHTMLText(providerHTMLFirstClass(card, "small"))})
	}
	return items
}

func (d *Downloader) fetchIkanbotCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if page < 1 || page > 100000 || len(query) > 256 || !validFilmCategory(ikanbotCategories, category) {
		return nil, false, errors.New("爱看机器人目录查询参数无效")
	}
	if query != "" && page > 1 {
		return []Drama{}, false, nil
	}
	category = firstNonEmpty(category, ikanbotCategories[0].ID)
	path := "/hot/index-" + category + ".html"
	if page > 1 {
		path = fmt.Sprintf("/hot/index-%s-p-%d.html", category, page)
	}
	if query != "" {
		path = "/search?" + url.Values{"q": {query}}.Encode()
	}
	body, pageURL, err := d.fetchFilmText(ctx, sourceIkanbot, path, "")
	if err != nil {
		return nil, false, err
	}
	document, err := filmDocument(body)
	if err != nil {
		return nil, false, err
	}
	items := parseIkanbotCards(document, pageURL, category, query != "")
	if len(items) == 0 && (query == "" || !strings.Contains(body, "title-text") && !strings.Contains(body, "没有") && !strings.Contains(body, "未找到")) {
		return nil, false, errors.New("爱看机器人未返回有效影视列表，请稍后重试")
	}
	more := false
	if query == "" {
		for _, anchor := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "a" }) {
			href := providerHTMLAttr(anchor, "href")
			if strings.HasPrefix(href, "/hot/index-"+category+"-p-") {
				if match := ikanbotPageNumber.FindStringSubmatch(href); len(match) == 2 {
					number, _ := strconv.Atoi(match[1])
					more = more || number > page
				}
			}
		}
	}
	return items, more, nil
}

func parseIkanbotDetail(document *html.Node, sourceID, pageURL string) (ikanbotDetail, error) {
	result := ikanbotDetail{pageURL: pageURL}
	values := map[string]string{}
	for _, node := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "input" }) {
		values[providerHTMLAttr(node, "id")] = strings.TrimSpace(providerHTMLAttr(node, "value"))
	}
	if values["current_id"] != sourceID || values["mtype"] != "1" && values["mtype"] != "2" {
		return result, errors.New("爱看机器人详情与请求影片不符，请刷新详情")
	}
	if _, err := ikanbotToken(sourceID, values["e_token"]); err != nil {
		return result, err
	}
	title, cover := "", ""
	metadata := []string{}
	for _, node := range providerHTMLNodes(document, func(node *html.Node) bool {
		return providerHTMLAttr(node, "id") == "video_title" || node.Data == "h3" && providerHTMLClass(node, "meta") || node.Data == "img" && providerHTMLClass(node, "cover")
	}) {
		switch {
		case providerHTMLAttr(node, "id") == "video_title":
			title = providerHTMLText(node)
		case node.Data == "img":
			cover = providerCoverAddress(providerHTMLAttr(node, "data-src"), pageURL)
		default:
			if text := providerHTMLText(node); text != "" {
				metadata = append(metadata, text)
			}
		}
	}
	if title == "" {
		return result, errors.New("爱看机器人详情缺少影片名称")
	}
	description := strings.Join(metadata, " · ")
	kind := "电影"
	if values["mtype"] == "2" {
		kind = "剧集"
	}
	result.drama = Drama{ID: providerDramaID(sourceIkanbot, sourceID), Source: sourceIkanbot, SourceID: sourceID,
		Title: truncate(title, 512), Name: truncate(title, 512), Cover: cover, CoverURL: cover,
		Desc: truncate(description, 12000), Intro: truncate(description, 12000), ChannelName: "爱看机器人", CategoryName: kind}
	result.token, result.mtype = values["e_token"], values["mtype"]
	return result, nil
}

func parseIkanbotLines(raw json.RawMessage, mtype, pageURL string) ([]ikanbotLine, error) {
	var payload struct {
		List []struct {
			ResData string `json:"resData"`
		} `json:"list"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, errors.New("爱看机器人线路数据无效")
	}
	lines := []ikanbotLine{}
	for index, item := range payload.List {
		var resources []struct {
			URL string `json:"url"`
		}
		if json.Unmarshal([]byte(item.ResData), &resources) != nil {
			continue
		}
		for _, resource := range resources {
			line := ikanbotLine{name: fmt.Sprintf("线路 %d", index+1)}
			seen := map[string]bool{}
			pairs := strings.Split(resource.URL, "#")
			for index, pair := range pairs {
				name, address, ok := strings.Cut(pair, "$")
				address, _, _ = strings.Cut(address, "$")
				address = filmMediaURL(address, pageURL)
				if !ok || address == "" {
					continue
				}
				name = strings.Join(strings.Fields(name), " ")
				number := episodeIndex(name, 0)
				if number == 0 && ikanbotBareNumber.MatchString(name) {
					number, _ = strconv.Atoi(name)
				}
				key := "extra-" + name
				if mtype == "1" || name == "" {
					number = index + 1
				}
				if number > 0 {
					key = "ep-" + strconv.Itoa(number)
				}
				if seen[key] {
					continue
				}
				seen[key] = true
				line.episodes = append(line.episodes, ikanbotEpisode{key: key, title: name, address: address, number: number})
			}
			if len(line.episodes) == 0 {
				continue
			}
			lines = append(lines, line)
		}
	}
	if len(lines) == 0 {
		return nil, errors.New("爱看机器人暂未返回可用的 MP4 或 M3U8 线路，请稍后重试")
	}
	return lines, nil
}

func (d *Downloader) loadIkanbotDetail(ctx context.Context, sourceID string) (ikanbotDetail, error) {
	if !validIkanbotID(sourceID) {
		return ikanbotDetail{}, errors.New("爱看机器人影片 ID 无效")
	}
	ctx = context.WithValue(ctx, providerTextNoCacheKey{}, true)
	for attempt := 0; attempt < 2; attempt++ {
		body, pageURL, err := d.fetchFilmText(ctx, sourceIkanbot, "/play/"+sourceID, "")
		if err != nil {
			return ikanbotDetail{}, err
		}
		document, err := filmDocument(body)
		if err != nil {
			return ikanbotDetail{}, err
		}
		detail, err := parseIkanbotDetail(document, sourceID, pageURL)
		if err != nil {
			return ikanbotDetail{}, err
		}
		token, err := ikanbotToken(sourceID, detail.token)
		if err != nil {
			return ikanbotDetail{}, err
		}
		path := "/api/getResN?" + url.Values{"videoId": {sourceID}, "mtype": {detail.mtype}, "token": {token}}.Encode()
		body, _, err = d.fetchFilmText(ctx, sourceIkanbot, path, pageURL)
		if err != nil {
			return ikanbotDetail{}, err
		}
		var response struct {
			State   int             `json:"state"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if json.Unmarshal([]byte(body), &response) != nil {
			return ikanbotDetail{}, errors.New("爱看机器人线路接口返回无效数据")
		}
		if response.State != 1 {
			if response.State == -401 && attempt == 0 {
				continue
			}
			return ikanbotDetail{}, fmt.Errorf("爱看机器人线路获取失败（%d）：%s，请刷新详情重试", response.State, truncate(response.Message, 128))
		}
		detail.lines, err = parseIkanbotLines(response.Data, detail.mtype, pageURL)
		return detail, err
	}
	return ikanbotDetail{}, errors.New("爱看机器人播放令牌刷新失败，请稍后重试")
}

func (d *Downloader) fetchIkanbotDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	detail, err := d.loadIkanbotDetail(ctx, sourceID)
	if err != nil {
		return Drama{}, nil, err
	}
	episodes := []ikanbotEpisode{}
	seen := map[string]bool{}
	used := map[int]bool{}
	for _, line := range detail.lines {
		for _, episode := range line.episodes {
			if !seen[episode.key] {
				seen[episode.key] = true
				used[episode.number] = true
				episodes = append(episodes, episode)
			}
		}
	}
	sort.SliceStable(episodes, func(i, j int) bool {
		if episodes[i].number == 0 {
			return false
		}
		if episodes[j].number == 0 {
			return true
		}
		return episodes[i].number < episodes[j].number
	})
	chapters := make([]Chapter, 0, len(episodes))
	for _, episode := range episodes {
		number := episode.number
		if number == 0 {
			number = nextUnusedEpisodeIndex(len(chapters)+1, used)
			used[number] = true
		}
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceIkanbot, sourceID, episode.key), Source: sourceIkanbot,
			Title: firstNonEmpty(episode.title, fmt.Sprintf("第%d集", number)), CurrentEpisode: rawEpisode(number),
			VideoURL: episode.address, PageURL: detail.pageURL, Referer: detail.pageURL})
	}
	detail.drama.TotalEpisode, detail.drama.EpisodeCount = len(chapters), len(chapters)
	return detail.drama, chapters, nil
}

func (d *Downloader) resolveIkanbotMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, id, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceIkanbot, id, "")
	if !valid || source != sourceIkanbot || !validIkanbotID(id) || !strings.HasPrefix(task.Chapter.ID, prefix) {
		return providerMedia{}, errors.New("爱看机器人播放分集与影片不符，请刷新详情")
	}
	key := strings.TrimPrefix(task.Chapter.ID, prefix)
	if key == "" {
		return providerMedia{}, errors.New("爱看机器人缺少分集标识，请刷新详情")
	}
	detail, err := d.loadIkanbotDetail(ctx, id)
	if err != nil {
		return providerMedia{}, err
	}
	options := []providerMedia{}
	for _, line := range detail.lines {
		for _, episode := range line.episodes {
			if episode.key == key {
				option := d.filmMedia(source, episode.address, detail.pageURL)
				option.RouteName = line.name
				options = append(options, option)
			}
		}
	}
	if len(options) == 0 {
		return providerMedia{}, errors.New("爱看机器人该集线路已失效，请刷新详情或选择其他分集")
	}
	media := options[0]
	media.Variants = options
	return media, nil
}
