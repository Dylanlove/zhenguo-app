package core

import (
	"context"

	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

const xingguoCatalogPageSize = 50

const (
	xingguoProductID = "2a8c14d1-72e7-498b-af23-381028eb47c0"
	xingguoVestID    = "2be070e0-c824-4d0e-a67a-8f688890cadb"
	xingguoToken     = "202509271001001446030204698626"
)

func xingguoQuery(resourceID, page, size string) url.Values {
	return url.Values{
		"productId":  {xingguoProductID},
		"vestId":     {xingguoVestID},
		"channel":    {"oppo19"},
		"osType":     {"android"},
		"version":    {"20"},
		"token":      {xingguoToken},
		"resourceId": {resourceID},
		"pageNum":    {page},
		"pageSize":   {size},
	}
}

func xingguoDramaFromNode(node map[string]any, base string) Drama {
	id := duanjuFindString(node, "id", "bookId")
	if id == "" {
		return Drama{}
	}
	sourceKey := duanjuKeyWithPayload(id, duanjuFindString(node, "introduction"))
	heat := duanjuFindInt(node, "heat")
	views := ""
	if heat > 0 {
		views = strconv.Itoa(heat) + "万播放"
	}
	return Drama{
		ID:           providerDramaID(sourceXingguo, sourceKey),
		Source:       sourceXingguo,
		SourceID:     sourceKey,
		Title:        duanjuFindString(node, "name", "title"),
		Intro:        duanjuFindString(node, "introduction", "desc"),
		Cover:        duanjuCover(base, node, "icon", "cover"),
		EpisodeCount: json.Number(strconv.Itoa(duanjuFindInt(node, "chapterCount", "total"))),
		Views:        views,
		ChannelName:  duanjuSourceName(sourceXingguo),
	}
}

const nativeCatalogFanoutWorkers = 4

const xingguoWalkCategory = "walk"

const xingguoWalkBatch = 40

const xingguoWalkMaxID = 5200

func (d *Downloader) fetchXingguoWalkPage(ctx context.Context, page int) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	first := (page-1)*xingguoWalkBatch + 1
	if first > xingguoWalkMaxID {
		return nil, false, nil
	}
	last := min(first+xingguoWalkBatch-1, xingguoWalkMaxID)
	rows := make([][]Drama, last-first+1)
	slots := make(chan struct{}, nativeCatalogFanoutWorkers)
	var group sync.WaitGroup
	for id := first; id <= last; id++ {
		group.Add(1)
		go func(index, id int) {
			defer group.Done()
			defer func() {
				if recover() != nil {
					rows[index] = nil
				}
			}()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				return
			}
			items, _, err := d.fetchXingguoCatalogPage(ctx, 1, strconv.Itoa(id))
			if err == nil {
				rows[index] = items
			}
		}(id-first, id)
	}
	group.Wait()
	items := []Drama{}
	seen := map[string]bool{}
	for _, part := range rows {
		for _, drama := range part {
			if drama.ID == "" || seen[drama.ID] {
				continue
			}
			seen[drama.ID] = true
			items = append(items, drama)
		}
	}
	return items, last < xingguoWalkMaxID, nil
}

func (d *Downloader) fetchXingguoCatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	if strings.TrimSpace(category) == xingguoWalkCategory {
		return d.fetchXingguoWalkPage(ctx, page)
	}
	base := d.duanjuBaseURL(sourceXingguo)
	resourceID := strings.TrimSpace(category)
	if resourceID == "" {
		resourceID = duanjuStaticCategories[sourceXingguo][0].ID
	}
	if !webProviderNumericID.MatchString(resourceID) {
		return nil, false, errors.New("星果分类无效")
	}
	if page < 1 {
		page = 1
	}
	address := base + "/novel-api/app/pageModel/getResourceById?" + xingguoQuery(resourceID, strconv.Itoa(page), strconv.Itoa(xingguoCatalogPageSize)).Encode()
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceXingguo, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, false, err
	}
	data := duanjuFindMap(response, "data")
	var items []Drama
	for _, entry := range duanjuFindList(data, "datalist") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := xingguoDramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items, len(items) >= xingguoCatalogPageSize, nil
}

func (d *Downloader) searchXingguo(ctx context.Context, query string) ([]Drama, error) {
	keyword := strings.TrimSpace(query)
	if keyword == "" {
		return nil, errors.New("请输入搜索关键词")
	}
	base := d.duanjuBaseURL(sourceXingguo)
	values := url.Values{
		"productId": {xingguoProductID},
		"vestId":    {xingguoVestID},
		"channel":   {"oppo19"},
		"osType":    {"android"},
		"version":   {"20"},
		"token":     {xingguoToken},
		"key":       {keyword},
		"pageNum":   {"1"},
		"pageSize":  {"20"},
	}
	address := base + "/novel-api/basedata/book/searchBook?" + values.Encode()
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceXingguo, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, err
	}
	data := duanjuFindMap(response, "data")
	var items []Drama
	seen := map[string]bool{}
	for _, entry := range duanjuFindList(data, "datalist") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		drama := xingguoDramaFromNode(node, base)
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		items = append(items, drama)
	}
	if len(items) == 0 {
		return nil, errors.New("星果未搜索到相关剧集")
	}
	return items, nil
}

func (d *Downloader) fetchXingguoDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	base := d.duanjuBaseURL(sourceXingguo)
	bookID, intro := duanjuKeyBaseID(sourceID), duanjuKeyPayloadValue(sourceID)
	if bookID == "" {
		bookID = strings.TrimSpace(sourceID)
	}
	address := base + "/novel-api/basedata/book/getChapterList?" + url.Values{
		"bookId":    {bookID},
		"productId": {xingguoProductID},
		"vestId":    {xingguoVestID},
		"channel":   {"oppo19"},
		"osType":    {"android"},
		"version":   {"20"},
		"token":     {xingguoToken},
	}.Encode()
	response, err := d.duanjuJSON(ctx, duanjuRequest{Source: sourceXingguo, Address: address, Referer: base + "/"})
	if err != nil {
		return Drama{}, nil, err
	}
	drama := Drama{
		ID:          providerDramaID(sourceXingguo, sourceID),
		Source:      sourceXingguo,
		SourceID:    sourceID,
		Intro:       intro,
		ChannelName: duanjuSourceName(sourceXingguo),
	}
	var chapters []Chapter
	for index, entry := range duanjuFindList(response, "data") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := xingguoEpisodeURL(node)
		if videoURL == "" {
			continue
		}
		number := index + 1
		if parsed := duanjuFindInt(node, "chapterNum", "sort", "index"); parsed > 0 {
			number = parsed
		}
		chapters = append(chapters, duanjuChapter(sourceXingguo, sourceID, number, "", videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("星果未返回可播放分集")
	}
	sortDuanjuChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func xingguoEpisodeURL(node map[string]any) string {
	if direct := duanjuFindString(node, "shortPlayUrl", "playUrl", "url"); direct != "" {
		return direct
	}
	for _, listKey := range []string{"shortPlayList", "chapterShortPlayVoList"} {
		for _, entry := range duanjuFindList(node, listKey) {
			child, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			if address := xingguoEpisodeURL(child); address != "" {
				return address
			}
		}
	}
	return ""
}

func duanjuFormatCount(value int) string {
	if value <= 0 {
		return ""
	}
	return fmt.Sprintf("%d集", value)
}
