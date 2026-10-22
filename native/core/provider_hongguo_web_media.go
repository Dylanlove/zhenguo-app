package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var hongguoVideoJSONLD = regexp.MustCompile(`(?is)<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>`)

func (d *Downloader) resolveHongguoWebMedia(ctx context.Context, seriesID, videoID string) (providerMedia, error) {
	base := d.providerBaseURL(sourceHongguo)
	pageURL := base + "/player/" + url.PathEscape(seriesID) + "/" + url.PathEscape(videoID)
	body, err := d.fetchProviderText(ctx, pageURL, base+"/")
	if err != nil {
		return providerMedia{}, err
	}
	return parseHongguoWebMedia(body, seriesID, videoID, base+"/")
}

func parseHongguoWebMedia(body, seriesID, videoID, referer string) (providerMedia, error) {
	var page map[string]any
	for key, value := range nestedMap(parseRouterData(body), "loaderData") {
		candidate, _ := value.(map[string]any)
		if !strings.HasPrefix(key, "player_") || mapString(candidate, "vid") != videoID || mapString(candidate, "series_id") != seriesID {
			continue
		}
		if strings.HasSuffix(key, "/page") {
			page = candidate
			break
		}
		if page == nil {
			page = candidate
		}
	}
	if page == nil {
		return providerMedia{}, errors.New("红果网页未返回所请求的剧集，请重新获取分集")
	}
	detail := nestedMap(page, "seriesDetail")
	if limit, err := strconv.Atoi(mapString(detail, "accessible_episode_cnt")); err == nil && limit >= 0 {
		index := 0
		for position, value := range anyList(detail["vid_list"]) {
			if fmt.Sprint(value) == videoID {
				index = position + 1
				break
			}
		}
		if index == 0 || index > limit {
			return providerMedia{}, errors.New("该集不在红果网页公开播放范围内，继续尝试 App 取流")
		}
	}
	seo := nestedMap(page, "publicVideoSeo")
	if seo["available"] == false {
		return providerMedia{}, errors.New("红果网页当前未开放该集播放，继续尝试 App 取流")
	}
	var addresses []string
	seen := map[string]bool{}
	for _, match := range hongguoVideoJSONLD.FindAllStringSubmatch(body, -1) {
		var node map[string]any
		if json.Unmarshal([]byte(match[1]), &node) != nil && json.Unmarshal([]byte(html.UnescapeString(match[1])), &node) != nil {
			continue
		}
		if mapString(node, "@type") != "VideoObject" {
			continue
		}
		address := strings.TrimSpace(html.UnescapeString(mapString(node, "contentUrl")))
		parsed, err := url.Parse(address)
		if err != nil || !isProviderHTTPMediaURL(address) || !strings.HasPrefix(parsed.Path, "/video/public/"+videoID+"/") || !strings.HasSuffix(strings.ToLower(parsed.Path), ".mp4") || seen[address] {
			continue
		}
		addresses = append(addresses, address)
		seen[address] = true
	}
	info := nestedMap(page, "video_player_info")
	if len(addresses) == 0 {
		addresses = hongguoMediaAddresses(info)
	}
	if len(addresses) == 0 {
		return providerMedia{}, errors.New("红果该集未提供公开播放地址，继续尝试 App 取流")
	}
	duration, _ := strconv.ParseFloat(firstNonEmpty(mapString(seo, "durationSeconds", "duration"), mapString(info, "duration")), 64)
	quality, _ := strconv.Atoi(mapString(seo, "height"))
	if width, _ := strconv.Atoi(mapString(seo, "width")); width > 0 && (quality == 0 || width < quality) {
		quality = width
	}
	media := providerMedia{URL: addresses[0], Referer: referer, Duration: time.Duration(duration * float64(time.Second)), Quality: quality}
	for _, address := range addresses {
		variant := media
		variant.URL, variant.Variants = address, nil
		media.Variants = append(media.Variants, variant)
	}
	return media, nil
}
