package ysp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var playlistURI = regexp.MustCompile(`URI="([^"]+)"`)

func (s *Service) registerAsset(address string, headers map[string]string) string {
	raw, _ := json.Marshal(headers)
	id := sha256Text(address + "\x00" + string(raw))[:40]
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.assets[id]; existing != nil {
		existing.lastUsed = time.Now()
		return "/asset/" + existing.token
	} else {
		if len(s.assets) >= 2048 {
			var oldestID string
			var oldest time.Time
			for key, value := range s.assets {
				if oldestID == "" || value.lastUsed.Before(oldest) {
					oldestID, oldest = key, value.lastUsed
				}
			}
			if oldestID != "" {
				s.cacheBytes -= len(s.assets[oldestID].data)
				delete(s.assets, oldestID)
			}
		}
		s.assets[id] = &asset{address: address, headers: cloneHeaders(headers), token: s.encodeAsset(address, headers), lastUsed: time.Now()}
	}
	return "/asset/" + s.assets[id].token
}
func absoluteURL(value, base string) string {
	root, err := url.Parse(base)
	if err != nil {
		return ""
	}
	address, err := url.Parse(value)
	if err != nil {
		return ""
	}
	resolved := root.ResolveReference(address)
	if resolved.Scheme != "http" && resolved.Scheme != "https" {
		return ""
	}
	return resolved.String()
}
func (s *Service) rewrite(body, base string, headers map[string]string) string {
	return s.rewriteHeaders(body, base, headers, nil)
}
func (s *Service) rewriteHeaders(body, base string, headers map[string]string, overrides map[string]map[string]string) string {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	for index, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			lines[index] = playlistURI.ReplaceAllStringFunc(line, func(attribute string) string {
				matched := playlistURI.FindStringSubmatch(attribute)
				address := absoluteURL(matched[1], base)
				if address == "" {
					return attribute
				}
				return `URI="` + s.registerAsset(address, headers) + `"`
			})
			continue
		}
		if address := absoluteURL(trimmed, base); address != "" {
			selected := headers
			if stored := overrides[address]; stored != nil {
				selected = stored
			}
			lines[index] = s.registerAsset(address, selected)
		}
	}
	return strings.Join(lines, "\n")
}
func (entry *playlistEntry) stitch(body, base string, plan Plan) string {
	changed := entry.engine != "" && entry.engine != plan.Engine
	entry.engine = plan.Engine
	if strings.Contains(body, "#EXT-X-STREAM-INF") || strings.Contains(body, "#EXT-X-KEY") || strings.Contains(body, "#EXT-X-MAP") {
		body = strings.ReplaceAll(body, "#EXT-X-ENDLIST", "")
		if changed && !strings.Contains(body, "#EXT-X-STREAM-INF") {
			body = injectDiscontinuity(body)
		}
		return body
	}
	duration := 6.0
	date := ""
	known := map[string]int{}
	for index, value := range entry.segments {
		known[segmentKey(value.address, value.date)] = index
	}
	if entry.seen == nil {
		entry.seen = map[string]bool{}
	}
	var incoming []segment
	discontinuity := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXTINF:") {
			number := strings.SplitN(strings.TrimPrefix(line, "#EXTINF:"), ",", 2)[0]
			if value, err := strconv.ParseFloat(number, 64); err == nil && value > 0 && value < 120 {
				duration = value
			}
			continue
		}
		if strings.HasPrefix(line, "#EXT-X-PROGRAM-DATE-TIME:") {
			date = strings.TrimPrefix(line, "#EXT-X-PROGRAM-DATE-TIME:")
			continue
		}
		if line == "#EXT-X-DISCONTINUITY" {
			discontinuity = true
			continue
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		address := absoluteURL(line, base)
		if address == "" {
			continue
		}
		incoming = append(incoming, segment{duration: duration, date: date, address: address, headers: plan.Headers, discontinuity: discontinuity})
		date = ""
		discontinuity = false
	}
	initial := len(entry.segments) == 0
	for index, candidate := range incoming {
		address, date := candidate.address, candidate.date
		key := segmentKey(address, date)
		if index, ok := known[key]; ok {
			entry.segments[index].address = address
			entry.segments[index].headers = plan.Headers
			continue
		}
		if entry.seen[key] {
			continue
		}
		entry.seen[key] = true
		entry.seenOrder = append(entry.seenOrder, key)
		if initial && index < len(incoming)-25 {
			continue
		}
		if len(entry.segments) > 0 && date != "" {
			previous := entry.segments[len(entry.segments)-1].date
			if previous != "" {
				a, aErr := time.Parse(time.RFC3339Nano, date)
				b, bErr := time.Parse(time.RFC3339Nano, previous)
				if aErr == nil && bErr == nil && !a.After(b) {
					continue
				}
			}
		}
		entry.sequence++
		candidate.sequence = entry.sequence
		candidate.discontinuity = candidate.discontinuity || changed
		entry.segments = append(entry.segments, candidate)
		changed = false
		known[key] = len(entry.segments) - 1
	}
	if len(entry.seenOrder) > 240 {
		for _, key := range entry.seenOrder[:len(entry.seenOrder)-240] {
			delete(entry.seen, key)
		}
		entry.seenOrder = append([]string(nil), entry.seenOrder[len(entry.seenOrder)-240:]...)
	}
	if len(entry.segments) == 0 {
		return strings.ReplaceAll(body, "#EXT-X-ENDLIST", "")
	}
	if len(entry.segments) > 120 {
		for _, removed := range entry.segments[:len(entry.segments)-120] {
			if removed.discontinuity {
				entry.discontinuities++
			}
		}
		entry.segments = append([]segment(nil), entry.segments[len(entry.segments)-120:]...)
	}
	start := len(entry.segments) - 15
	if start < 0 {
		start = 0
	}
	display := entry.segments[start:]
	if len(display) >= 4 {
		display = display[:len(display)-1]
	}
	target := 6.0
	for _, value := range display {
		if value.duration > target {
			target = value.duration
		}
	}
	result := []string{"#EXTM3U", "#EXT-X-VERSION:3", fmt.Sprintf("#EXT-X-TARGETDURATION:%.0f", math.Ceil(target)), fmt.Sprintf("#EXT-X-MEDIA-SEQUENCE:%d", display[0].sequence)}
	discontinuities := entry.discontinuities
	for _, skipped := range entry.segments[:start] {
		if skipped.discontinuity {
			discontinuities++
		}
	}
	if discontinuities > 0 {
		result = append(result, fmt.Sprintf("#EXT-X-DISCONTINUITY-SEQUENCE:%d", discontinuities))
	}
	for _, value := range display {
		if value.discontinuity {
			result = append(result, "#EXT-X-DISCONTINUITY")
		}
		if value.date != "" {
			result = append(result, "#EXT-X-PROGRAM-DATE-TIME:"+value.date)
		}
		result = append(result, fmt.Sprintf("#EXTINF:%.3f,", value.duration), value.address)
	}
	return strings.Join(result, "\n") + "\n"
}

func segmentKey(address, date string) string {
	if date != "" {
		return "pdt:" + date
	}
	uri, _ := url.Parse(address)
	if uri == nil {
		return address
	}
	return uri.Scheme + "://" + uri.Host + uri.Path
}

func injectDiscontinuity(body string) string {
	if strings.Contains(body, "#EXT-X-DISCONTINUITY\n") || strings.Contains(body, "#EXT-X-DISCONTINUITY\r\n") {
		return body
	}
	lines := strings.Split(body, "\n")
	for index, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#EXTINF:") || strings.HasPrefix(strings.TrimSpace(line), "#EXT-X-PROGRAM-DATE-TIME:") {
			lines[index] = "#EXT-X-DISCONTINUITY\n" + line
			return strings.Join(lines, "\n")
		}
	}
	return body
}
func (s *Service) sendAsset(writer http.ResponseWriter, request *http.Request, id string) {
	token, err := s.decodeAsset(id)
	if err != nil {
		http.Error(writer, "分片令牌无效", http.StatusForbidden)
		return
	}
	s.registerAsset(token.URL, token.Headers)
	rawToken, _ := json.Marshal(token.Headers)
	id = sha256Text(token.URL + "\x00" + string(rawToken))[:40]
	s.mu.Lock()
	entry := s.assets[id]
	if entry == nil {
		s.mu.Unlock()
		http.Error(writer, "播放分片已过期，请重新打开频道", http.StatusGone)
		return
	}
	entry.lastUsed = time.Now()
	address, headers, data, contentType := entry.address, cloneHeaders(entry.headers), entry.data, entry.contentType
	s.mu.Unlock()
	ranged := request.Header.Get("Range") != ""
	if ranged {
		headers["Range"] = request.Header.Get("Range")
	}
	if len(data) > 0 && !ranged {
		writer.Header().Set("Content-Type", contentType)
		writer.Header().Set("Content-Length", strconv.Itoa(len(data)))
		if request.Method != "HEAD" {
			writer.Write(data)
		}
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 20*time.Second)
	defer cancel()
	raw, final, responseHeaders, err := fetch(ctx, s.client, "GET", address, nil, headers, 64<<20)
	if err != nil {
		http.Error(writer, "央视频分片暂不可用", http.StatusBadGateway)
		return
	}
	contentType = responseHeaders.Get("Content-Type")
	if contentType == "" {
		contentType = "video/mp2t"
	}
	if strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(string(raw[:min(len(raw), 20)]), "\ufeff")), "#EXTM3U") {
		raw = []byte(s.rewrite(string(raw), final, entry.headers))
		contentType = "application/vnd.apple.mpegurl"
	}
	writer.Header().Set("Content-Type", contentType)
	writer.Header().Set("Content-Length", strconv.Itoa(len(raw)))
	for _, key := range []string{"Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := responseHeaders.Get(key); value != "" {
			writer.Header().Set(key, value)
		}
	}
	if ranged && responseHeaders.Get("Content-Range") != "" {
		writer.WriteHeader(http.StatusPartialContent)
	}
	if !ranged && !strings.Contains(contentType, "mpegurl") && len(raw) <= 32<<20 {
		s.mu.Lock()
		if current := s.assets[id]; current == entry {
			s.cacheBytes -= len(entry.data)
			entry.data = nil
			for s.cacheBytes+len(raw) > 64<<20 {
				var oldestID string
				var oldest time.Time
				for key, value := range s.assets {
					if len(value.data) > 0 && (oldestID == "" || value.lastUsed.Before(oldest)) {
						oldestID, oldest = key, value.lastUsed
					}
				}
				if oldestID == "" {
					break
				}
				oldestEntry := s.assets[oldestID]
				s.cacheBytes -= len(oldestEntry.data)
				oldestEntry.data = nil
			}
			entry.data = raw
			entry.contentType = contentType
			s.cacheBytes += len(raw)
		}
		s.mu.Unlock()
	}
	if request.Method != "HEAD" {
		writer.Write(raw)
	}
}

func (s *Service) subscription(request *http.Request) string {
	s.mu.Lock()
	port := s.settings.Port
	s.mu.Unlock()
	host := request.Host
	if _, _, err := netSplitHost(host); err != nil {
		host = "127.0.0.1:" + strconv.Itoa(port)
	}
	scheme := "http"
	if request.TLS != nil || strings.EqualFold(strings.TrimSpace(strings.Split(request.Header.Get("X-Forwarded-Proto"), ",")[0]), "https") {
		scheme = "https"
	}
	base := scheme + "://" + host
	lines := []string{`#EXTM3U url-tvg="https://epg.zsdc.eu.org/t.xml.gz,https://epg.pw/xmltv/epg_CN.xml.gz" x-tvg-url="https://epg.zsdc.eu.org/t.xml.gz"`, "#EXT-X-APTV-PREVIEW: FALSE", "#EXT-X-APTV-LATENCY: FALSE", "#EXT-X-APTV-LOGO: FALSE"}
	query := request.URL.Query()
	group := query.Get("group")
	onlyUltra := query.Get("k4") == "1" || strings.EqualFold(query.Get("k4"), "true")
	for _, channel := range s.channels {
		if group != "" && !strings.Contains(channel.Group, group) || onlyUltra && !channel.Ultra {
			continue
		}
		attributes := fmt.Sprintf(` tvg-id="%s" tvg-name="%s" tvg-logo="https://garysclub.sharewithyou.dpdns.org/logos/ysp-live-logos/%s.png" group-title="%s"`, channel.TvgID, channel.Name, channel.ID, channel.Group)
		if channel.Catchup {
			attributes += ` catchup="append" catchup-days="7" catchup-source="?utc={utc}&lutc={lutc}"`
		}
		lines = append(lines, "#EXTINF:-1"+attributes+","+channel.Name, base+"/live/"+channel.ID+".m3u8")
	}
	return strings.Join(lines, "\n") + "\n"
}
func netSplitHost(host string) (string, string, error) {
	uri, err := url.Parse("http://" + host)
	if err != nil || uri.Hostname() == "" || uri.Path != "" || uri.RawQuery != "" || uri.Fragment != "" || uri.User != nil {
		return "", "", errors.New("请求主机无效")
	}
	return uri.Hostname(), uri.Port(), nil
}
func (s *Service) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Access-Control-Allow-Origin", "*")
	if request.Method != "GET" && request.Method != "HEAD" {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	send := func(contentType string, data []byte) {
		writer.Header().Set("Content-Type", contentType)
		writer.Header().Set("Content-Length", strconv.Itoa(len(data)))
		writer.Header().Set("Cache-Control", "no-store")
		if request.Method != "HEAD" {
			writer.Write(data)
		}
	}
	switch request.URL.Path {
	case "/", "/index.html":
		send("text/plain; charset=utf-8", []byte("YSP Live "+Version+" · 真果鉴设备端适配\n订阅：/all.m3u\n健康：/health\n诊断：/diag\nGary's Club · https://t.me/garysclub\n"))
		return
	case "/all.m3u":
		send("application/vnd.apple.mpegurl; charset=utf-8", []byte(s.subscription(request)))
		return
	case "/health", "/diag":
		raw, _ := json.MarshalIndent(s.Status(), "", "  ")
		send("application/json; charset=utf-8", raw)
		return
	case "/ysp.list", "/ysp.module":
		raw, err := bundled.ReadFile("assets" + request.URL.Path)
		if err != nil {
			http.NotFound(writer, request)
			return
		}
		send("text/plain; charset=utf-8", raw)
		return
	}
	if strings.HasPrefix(request.URL.Path, "/asset/") {
		s.sendAsset(writer, request, strings.TrimPrefix(request.URL.Path, "/asset/"))
		return
	}
	path := strings.TrimPrefix(request.URL.Path, "/")
	path = strings.TrimPrefix(path, "live/")
	if !strings.HasSuffix(path, ".m3u8") || strings.Contains(path, "/") {
		http.NotFound(writer, request)
		return
	}
	channel, err := s.channel(path)
	if err != nil {
		http.NotFound(writer, request)
		return
	}
	start, end, err := catchupQuery(request.URL.Query())
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}
	if start > 0 {
		if err = validateCatchup(channel, start, end); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
	}
	s.mu.Lock()
	quality := s.settings.Quality
	s.mu.Unlock()
	if choice := request.URL.Query().Get("quality"); choice != "" {
		if !validQuality(choice) {
			http.Error(writer, "画质参数无效", http.StatusBadRequest)
			return
		}
		quality = choice
	}
	ctx, cancel := context.WithTimeout(request.Context(), 40*time.Second)
	defer cancel()
	body, err := s.Playlist(ctx, channel, quality, start, end)
	if err != nil {
		http.Error(writer, "央视频频道暂不可用，请重试或切换画质", http.StatusBadGateway)
		return
	}
	send("application/vnd.apple.mpegurl", []byte(body))
}
