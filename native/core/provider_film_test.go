package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func filmTestEngine(t *testing.T, handler http.HandlerFunc) *nativeEngine {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d := engine.downloader
	d.client, d.limiter = server.Client(), newRequestLimiter(3, 0)
	d.cfg.IkanbotURL, d.cfg.A123URL, d.cfg.Retries = server.URL, server.URL, 1
	t.Cleanup(func() {
		if engine.stream != nil {
			engine.stream.server.Close()
		}
	})
	return engine
}

func filmTestIkanbotPage(seed string) string {
	return `<input value="780774" id="current_id" type="hidden"><input value="` + seed + `" id="e_token" type="hidden"><input value="2" id="mtype"><h1 id="video_title">三体</h1><img data-src="//posters.invalid/cover.jpg" class="lazy cover"><h3 class="meta">2023</h3><h3 class="meta">中国大陆</h3><h3 class="meta">导演 / 演员</h3>`
}

func filmTestIkanbotLines(lines ...string) string {
	rows := []map[string]string{}
	for index, episodes := range lines {
		resource, _ := json.Marshal([]map[string]string{{"flag": fmt.Sprintf("线路%d", index+1), "url": episodes}})
		rows = append(rows, map[string]string{"resData": string(resource)})
	}
	body, _ := json.Marshal(map[string]any{"state": 1, "data": map[string]any{"list": rows}})
	return string(body)
}

func filmTestA123Page(id string, index int, first, second string) string {
	playback, _ := json.Marshal(map[string]any{"no": id, "ld": "main", "la": []any{
		[]any{"main", "主线", 2, index, first}, []any{"backup", "备用", 2, index, second},
		[]any{"wrong-episode", "错集", 2, 1 - index, "https://invalid.test/wrong.mp4"},
		[]any{"missing-episode", "缺集", index, index, "https://invalid.test/missing.mp4"},
	}})
	return `<head><meta content="真实页面结构的合成简介 &amp; 资料" name="description"></head><h1>三体</h1><div data-poster="//posters.invalid/a123.jpg" data-src="` + first + `" class="w4-player"></div><div class="w4-episode-list w4-scroll"><div><a title="第01集" href="/v/` + id + `/mainz0.html">第01集</a><a href="/v/` + id + `/mainz1.html">第02集</a></div></div><a href="/v/other/mainz0.html">推荐影片</a><a href="/v/` + id + `/backupz0.html">备用线路</a><script>var pp = ` + string(playback) + `; next();</script>`
}

func TestFilmProviderRegistrationAndDynamicToken(t *testing.T) {
	token, err := ikanbotToken("780774", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
	if err != nil || token != "BCDEFGHILMNOPQRSVWXYZabcfghijklm" {
		t.Fatalf("unexpected signature %q %v", token, err)
	}
	for _, seed := range []string{"", "short", strings.Repeat("a", 20)} {
		if _, err := ikanbotToken("780774", seed); err == nil {
			t.Fatal("accepted truncated token")
		}
	}
	for _, source := range []string{sourceIkanbot, sourceA123} {
		if !isHuangguoProviderSource(source) || !isFilmProviderSource(source) {
			t.Fatal("source not registered", source)
		}
		if validNativeCategory(source, "../10") || validNativeCategory(source, "999") {
			t.Fatal("accepted invalid category")
		}
		engine := &nativeEngine{}
		categories, err := engine.nativeCategories(context.Background(), source, false)
		if err != nil || len(categories) < 6 {
			t.Fatal("missing categories", source, categories, err)
		}
		for _, category := range categories {
			if !validNativeCategory(source, category.ID) {
				t.Fatal("registered category rejected", category)
			}
		}
	}
	previous := buildAllSources
	t.Cleanup(func() { buildAllSources = previous })
	for _, edition := range []string{"false", "true"} {
		buildAllSources = edition
		for _, source := range []string{sourceIkanbot, sourceA123} {
			if available := nativeSourceAvailable(source); available != (edition == "true") {
				t.Fatal("source bypassed edition gate", source, edition)
			}
		}
	}
	for address, want := range map[string]string{ikanbotBaseURL: sourceIkanbot, a123BaseURL: sourceA123} {
		if providerSourceForURL(address) != want {
			t.Fatal("missing URL registration", address)
		}
	}
	for raw, want := range map[string]string{
		"https://media.test/video.M3U8?token=a%2Fb": "https://media.test/video.M3U8?token=a%2Fb",
		"//media.test/video.mp4":                    "https://media.test/video.mp4",
		"javascript:bad":                            "", "https://media.test/page.html": "", "https://user:pass@media.test/video.mp4": "",
	} {
		if got := filmMediaURL(raw, "https://site.test/"); got != want {
			t.Fatalf("media URL %q became %q", raw, got)
		}
	}
}

func TestFilmCatalogSearchAndPagination(t *testing.T) {
	requests := []string{}
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.URL.RequestURI())
		if r.Header.Get("User-Agent") == "" || r.Header.Get("Referer") == "" {
			t.Error("missing browser headers")
		}
		switch {
		case r.URL.Path == "/search":
			if r.URL.Query().Get("q") != "三体" {
				t.Error("Chinese query was corrupted")
			}
			io.WriteString(w, `<div class="media"><a href="/play/780774" class="title-text">三体 2023</a><img src="data:image/svg+xml,placeholder" data-src="//posters.invalid/1.jpg" alt="三体"></div>`)
		case strings.HasPrefix(r.URL.Path, "/hot/index-tv-热门"):
			io.WriteString(w, `<a href="/play/780774" class="other item"><img src="data:image/svg+xml,placeholder" alt="三体" data-src="//posters.invalid/1.jpg"></a><a href="/hot/index-tv-热门-p-2.html">2</a>`)
		case r.URL.Path == "/s/三体.html" || r.URL.Path == "/t/11.html" || r.URL.Path == "/":
			io.WriteString(w, `<main><a href="/v/santi.html" class="w4-item"><img src="data:image/svg+xml,placeholder" data-src="//posters.invalid/a.jpg"><div title="三体" class="t">三体</div><div class="i">国产剧 / 2023年</div></a></main><div class="w4-page"><li aria-current="page">1</li><a href="/t/11/p2.html">2</a></div>`)
		default:
			t.Error("unexpected request", r.URL.Path)
			http.NotFound(w, r)
		}
	})
	for _, item := range []struct {
		source, category, query string
		more                    bool
	}{
		{sourceIkanbot, "tv-热门", "", true}, {sourceIkanbot, "", "三体", false},
		{sourceA123, "11", "", true}, {sourceA123, "", "三体", false}, {sourceA123, "", "", false},
	} {
		result, err := engine.nativeCatalog(context.Background(), nativeInput{Source: item.source, Category: item.category, Query: item.query, Page: 1, Force: true})
		if err != nil || len(result.Items) != 1 || result.HasMore != item.more || result.LocalSearch || result.Items[0].Cover == "" || strings.HasPrefix(result.Items[0].Cover, "data:") {
			t.Fatalf("catalog/search failed %+v: %+v %v", item, result, err)
		}
	}
	before := len(requests)
	items, more, err := engine.downloader.fetchA123CatalogPage(context.Background(), 2, "", "")
	if err != nil || more || len(items) != 0 || len(requests) != before {
		t.Fatal("homepage invented a second-page category")
	}
	if a123PagePath("https://a123.test/", "https://other.test/v/santi/mainz0.html", "santi", true) != "" {
		t.Fatal("accepted external episode page")
	}
}

func TestIkanbotRefreshesTokenKeepsCookiesAndUnionsEpisodes(t *testing.T) {
	pages, apis := 0, 0
	var base string
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/play/780774":
			pages++
			http.SetCookie(w, &http.Cookie{Name: "session", Value: strconv.Itoa(pages), Path: "/"})
			io.WriteString(w, filmTestIkanbotPage(strings.Repeat(strconv.Itoa(pages), 64)))
		case "/api/getResN":
			apis++
			cookie, err := r.Cookie("session")
			if err != nil || cookie.Value != strconv.Itoa(pages) {
				t.Error("detail cookie not retained", err)
			}
			if r.URL.Query().Get("videoId") != "780774" || r.URL.Query().Get("mtype") != "2" || r.URL.Query().Get("token") != strings.Repeat(strconv.Itoa(pages), 32) || r.Header.Get("Referer") != base+"/play/780774" {
				t.Error("incorrect dynamic authorization or referer")
			}
			if apis == 1 {
				io.WriteString(w, `{"state":-401,"message":"unauthorized"}`)
				return
			}
			io.WriteString(w, filmTestIkanbotLines("第01集$"+base+"/one.m3u8?token=a%2Fb$flag#第02集$"+base+"/two.mp4", "第01集$"+base+"/backup.mp4#第03集$"+base+"/three.mp4"))
		default:
			t.Error("unexpected request", r.URL.Path)
			http.NotFound(w, r)
		}
	})
	base = engine.downloader.cfg.IkanbotURL
	drama, chapters, err := engine.downloader.fetchIkanbotDetail(context.Background(), "780774")
	if err != nil || len(chapters) != 3 || drama.Desc == "" || nativeNormalize(drama).Cover == "" || pages != 2 || apis != 2 {
		t.Fatalf("detail failed chapters=%v pages=%d apis=%d: %v", chapters, pages, apis, err)
	}
	media, err := engine.downloader.resolveProviderMedia(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[0]})
	if err != nil || len(nativePlaybackChoices(media, 0).media) != 2 || !strings.Contains(media.URL, "?token=a%2Fb") || strings.Contains(media.URL, "$flag") || pages != 3 || apis != 3 {
		t.Fatalf("resolve failed variants=%d pages=%d apis=%d: %v", len(media.Variants), pages, apis, err)
	}
	if media.credentials == nil || media.credentials.cookie != "session=3" || media.credentials.userAgent != ikanbotUserAgent {
		t.Fatal("media credentials lost")
	}
	if _, err := engine.downloader.resolveIkanbotMedia(context.Background(), Task{DramaID: "ikanbot:780774", Chapter: Chapter{ID: "ikanbot:780775:ep-1"}}); err == nil || pages != 3 {
		t.Fatal("cross-drama chapter was accepted")
	}
}

func TestIkanbotAuthorizationFailureIsBounded(t *testing.T) {
	pages, apis := 0, 0
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/play/780774" {
			pages++
			io.WriteString(w, filmTestIkanbotPage(strings.Repeat("a", 64)))
			return
		}
		if r.URL.Path == "/api/getResN" {
			apis++
			io.WriteString(w, `{"state":-401,"message":"unauthorized"}`)
			return
		}
		t.Error("unexpected request", r.URL.Path)
	})
	_, _, err := engine.downloader.fetchIkanbotDetail(context.Background(), "780774")
	if err == nil || pages != 2 || apis != 2 || !strings.Contains(err.Error(), "-401") {
		t.Fatal("authorization error hidden or retried without bound", pages, apis, err)
	}
}

func TestA123DetailAndSameEpisodeRoutes(t *testing.T) {
	requests := 0
	var base string
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		requests++
		index := 0
		if strings.HasSuffix(r.URL.Path, "mainz1.html") {
			index = 1
		}
		if r.URL.Path != "/v/santi.html" && r.URL.Path != "/v/santi/mainz1.html" {
			t.Error("unexpected page", r.URL.Path)
		}
		io.WriteString(w, filmTestA123Page("santi", index, base+"/main.m3u8?auth=one", base+"/backup.mp4"))
	})
	base = engine.downloader.cfg.A123URL
	drama, chapters, err := engine.downloader.fetchA123Detail(context.Background(), "santi")
	if err != nil || len(chapters) != 2 || chapters[1].Title != "第02集" || !strings.Contains(drama.Desc, "& 资料") || !strings.HasSuffix(nativeNormalize(drama).Cover, "a123.jpg") {
		t.Fatalf("detail failed: %+v %+v %v", drama, chapters, err)
	}
	media, err := engine.downloader.resolveA123Media(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[1]})
	if err != nil || len(media.Variants) != 2 || media.Variants[1].URL != base+"/backup.mp4" || media.Referer != base+"/v/santi/mainz1.html" {
		t.Fatalf("wrong same-episode variants: %+v %v", media, err)
	}
	if _, err := engine.downloader.resolveA123Media(context.Background(), Task{DramaID: drama.ID, Chapter: Chapter{ID: "a123:other:mainz1", PageURL: base + "/v/santi/mainz1.html"}}); err == nil || requests != 2 {
		t.Fatal("accepted a mismatched chapter")
	}
}

func TestA123RejectsWrongEpisodeEvenWithPlayerAddress(t *testing.T) {
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, filmTestA123Page("santi", 0, "https://media.test/wrong.mp4", "https://media.test/other.mp4"))
	})
	_, err := engine.downloader.resolveA123Media(context.Background(), Task{DramaID: "a123:santi", Chapter: Chapter{ID: "a123:santi:mainz1"}})
	if err == nil || !strings.Contains(err.Error(), "集数") {
		t.Fatal("wrong episode player address was accepted", err)
	}
}

func TestFilmPlaybackSwitchFailureAndRequestHeaders(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "true"
	t.Cleanup(func() { buildAllSources = previous })
	for _, source := range []string{sourceIkanbot, sourceA123} {
		t.Run(source, func(t *testing.T) {
			var base string
			engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/good.m3u8" && r.URL.Path != "/good.mp4" && r.URL.Path != "/bad.m3u8" {
					t.Fatal("unexpected request", r.URL.Path)
				}
				cookie, err := r.Cookie("signed")
				if err != nil || cookie.Value != "yes" || r.Header.Get("Referer") != base+"/page" || r.Header.Get("Origin") != base || !strings.HasPrefix(r.Header.Get("User-Agent"), "Mozilla/5.0") {
					t.Error("playback headers lost", err, r.Header)
				}
				switch r.URL.Path {
				case "/bad.m3u8":
					http.Error(w, "expired", http.StatusNotFound)
				case "/good.m3u8":
					w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
					io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n")
				case "/good.mp4":
					w.Header().Set("Content-Type", "video/mp4")
					io.WriteString(w, "synthetic-mp4-header")
				}
			})
			base = engine.downloader.cfg.A123URL
			address, _ := http.NewRequest(http.MethodGet, base+"/", nil)
			engine.downloader.filmDownloader().client.Jar.SetCookies(address.URL, []*http.Cookie{{Name: "signed", Value: "yes", Path: "/"}})
			options := []providerMedia{}
			for _, path := range []string{"/bad.m3u8", "/good.m3u8", "/good.mp4"} {
				options = append(options, engine.downloader.filmMedia(source, base+path, base+"/page"))
			}
			media := options[0]
			media.Variants = options
			choice := nativePlaybackChoices(media, 0)
			choice.source = source
			plan, err := engine.nativeOpenPlayback(context.Background(), choice)
			if err != nil {
				t.Fatal(err)
			}
			check := func(plan nativePlan, status int, contains string) {
				t.Helper()
				response, err := http.Get(plan.URL)
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				if err != nil || response.StatusCode != status || !strings.Contains(string(body), contains) {
					t.Fatalf("playback status=%d body=%q err=%v", response.StatusCode, body, err)
				}
			}
			check(plan, http.StatusBadGateway, "请重试")
			next, err := engine.nativeNextPlayback(context.Background(), plan.Session)
			if err != nil || next.RouteIndex != 1 || next.RouteCount != 3 {
				t.Fatal(next, err)
			}
			check(next, http.StatusOK, "#EXTM3U")
			selected, err := engine.nativeSelectFilmRoute(context.Background(), next.Session, 2)
			if err != nil || selected.RouteIndex != 2 {
				t.Fatal(selected, err)
			}
			check(selected, http.StatusOK, "synthetic-mp4-header")
			back, err := engine.nativeSelectFilmRoute(context.Background(), selected.Session, 1)
			if err != nil {
				t.Fatal(err)
			}
			check(back, http.StatusOK, "#EXTM3U")
			for _, route := range []int{-1, 3} {
				if _, err := engine.nativeSelectFilmRoute(context.Background(), back.Session, route); err == nil {
					t.Fatal("accepted invalid route", route)
				}
			}
			if _, err := engine.nativeNextPlayback(context.Background(), selected.Session); err == nil {
				t.Fatal("exhausted routes restarted")
			}
			for _, session := range []string{plan.Session, next.Session, selected.Session, back.Session} {
				engine.nativeReleasePlayback(session)
			}
			if len(engine.playbacks) != 0 || len(engine.stream.sessions) != 0 {
				t.Fatal("playback sessions leaked")
			}
		})
	}
}

func TestFilmSourceHealthChecksPlaylistKeyAndSegment(t *testing.T) {
	var base string
	engine := filmTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			io.WriteString(w, `<main><a class="w4-item" href="/v/santi.html"><div class="t">三体</div></a></main>`)
		case "/v/santi.html", "/v/santi/mainz0.html":
			io.WriteString(w, filmTestA123Page("santi", 0, base+"/good.m3u8", base+"/backup.mp4"))
		case "/good.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.key\"\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n")
		case "/key.key":
			w.Header().Set("Content-Type", "application/octet-stream")
			io.WriteString(w, "0123456789abcdef")
		case "/part.ts":
			w.Header().Set("Content-Type", "video/mp2t")
			w.Write([]byte{0x47, 0, 0, 0})
		default:
			t.Error("unexpected health request", r.URL.Path)
			http.NotFound(w, r)
		}
	})
	base = engine.downloader.cfg.A123URL
	if err := engine.checkSource(context.Background(), sourceA123, nativeDrama{}, true); err != nil {
		t.Fatal(err)
	}
	status := engine.sourceStatus(sourceA123)
	if status.Health == nil || status.Health.State != "ok" || len(status.Health.Steps) != 5 {
		t.Fatalf("incomplete source health: %+v", status.Health)
	}
}

func TestFilmProvidersLive(t *testing.T) {
	if os.Getenv("CHECK_LIVE_FILM_PROVIDERS") != "true" {
		t.Skip("set CHECK_LIVE_FILM_PROVIDERS=true for live source acceptance")
	}
	previous := buildAllSources
	buildAllSources = "true"
	t.Cleanup(func() { buildAllSources = previous })
	for _, source := range []string{sourceIkanbot, sourceA123} {
		t.Run(source, func(t *testing.T) {
			engine, err := newNativeEngine(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if engine.stream != nil {
					engine.stream.server.Close()
				}
			})
			ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
			defer cancel()
			categories, err := engine.nativeCategories(ctx, source, false)
			if err != nil {
				t.Fatal(err)
			}
			category := "tv-热门"
			if source == sourceA123 {
				category = "11"
			}
			catalog, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Category: category, Page: 1, Force: true})
			if err != nil || len(catalog.Items) == 0 {
				t.Fatalf("category catalog failed count=%d err=%v", len(catalog.Items), err)
			}
			secondPage, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Category: category, Page: 2, Force: true})
			if err != nil || len(secondPage.Items) == 0 || reflect.DeepEqual(catalog.Items, secondPage.Items) {
				t.Fatalf("category pagination failed count=%d err=%v", len(secondPage.Items), err)
			}
			home, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Page: 1, Force: true})
			if err != nil || len(home.Items) == 0 {
				t.Fatalf("home failed count=%d err=%v", len(home.Items), err)
			}
			search, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Query: "三体", Page: 1})
			if err != nil || len(search.Items) == 0 || search.LocalSearch {
				t.Fatalf("Chinese search failed count=%d err=%v", len(search.Items), err)
			}
			target := search.Items[0]
			for _, item := range search.Items {
				if item.SourceID == "santi" {
					target = item
					break
				}
			}
			detail, err := engine.nativeDetail(ctx, target)
			if err != nil {
				t.Fatal("detail", err)
			}
			body, _ := json.Marshal(detail)
			var parsed struct {
				Drama    nativeDrama `json:"drama"`
				Chapters []Chapter   `json:"chapters"`
			}
			if json.Unmarshal(body, &parsed) != nil || len(parsed.Chapters) < 2 || parsed.Drama.Description == "" || parsed.Drama.Cover == "" {
				t.Fatalf("incomplete detail chapters=%d description=%t cover=%t", len(parsed.Chapters), parsed.Drama.Description != "", parsed.Drama.Cover != "")
			}
			media, err := engine.downloader.resolveProviderMedia(ctx, Task{DramaID: target.ID, Chapter: parsed.Chapters[0], Index: 1})
			if err != nil {
				t.Fatal("resolve", err)
			}
			secondEpisode, err := engine.downloader.resolveProviderMedia(ctx, Task{DramaID: target.ID, Chapter: parsed.Chapters[1], Index: 2})
			if err != nil || secondEpisode.URL == media.URL {
				t.Fatalf("episode selection failed: %v", err)
			}
			choice := nativePlaybackChoices(media, 0)
			choice.source = source
			if len(choice.media) < 2 {
				t.Fatal("expected multiple live routes")
			}
			plan, err := engine.nativeOpenPlayback(ctx, choice)
			if err != nil {
				t.Fatal(err)
			}
			client := &http.Client{Timeout: 15 * time.Second}
			succeeded := []int{}
			decoded := false
			for index := 0; index < min(8, len(choice.media)); index++ {
				if index > 0 {
					old := plan.Session
					plan, err = engine.nativeSelectFilmRoute(ctx, plan.Session, index)
					engine.nativeReleasePlayback(old)
					if err != nil {
						t.Fatal(err)
					}
				}
				response, requestErr := client.Get(plan.URL)
				if requestErr != nil {
					t.Logf("route %d failed: %v", index+1, publicError(requestErr))
					continue
				}
				playlist, readErr := io.ReadAll(io.LimitReader(response.Body, 4<<20))
				response.Body.Close()
				if readErr != nil || response.StatusCode != http.StatusOK || !nativePlaylistPrefix(playlist) {
					_, _, cause := engine.downloader.fetchMediaPlaylist(providerMediaContext(ctx, choice.media[index].credentials), choice.media[index].URL, choice.media[index].Referer)
					t.Logf("route %d unavailable: HTTP %d certificate_error=%t cause=%v", index+1, response.StatusCode, isCertificateValidationError(cause), publicError(cause))
					continue
				}
				succeeded = append(succeeded, index+1)
				if !decoded && os.Getenv("FILM_LIVE_DECODE") == "true" {
					binary, err := exec.LookPath("ffprobe")
					if err != nil {
						t.Fatal("ffprobe unavailable", err)
					}
					probeContext, stop := context.WithTimeout(ctx, 30*time.Second)
					command := exec.CommandContext(probeContext, binary, "-v", "error", "-rw_timeout", "12000000", "-analyzeduration", "3000000", "-probesize", "2097152", "-show_entries", "stream=codec_name,width,height", "-of", "json", plan.URL)
					output, err := command.Output()
					stop()
					var probe struct {
						Streams []struct {
							Codec  string `json:"codec_name"`
							Width  int    `json:"width"`
							Height int    `json:"height"`
						} `json:"streams"`
					}
					if err != nil || json.Unmarshal(output, &probe) != nil || len(probe.Streams) == 0 {
						t.Errorf("media probe failed on route %d: %v", index+1, err)
					} else {
						decoded = true
						t.Logf("LIVE media probe source=%s streams=%+v", source, probe.Streams)
					}
				}
				if len(succeeded) == 2 {
					break
				}
			}
			engine.nativeReleasePlayback(plan.Session)
			if len(succeeded) < 2 {
				t.Errorf("two-route playlist verification incomplete: %v", succeeded)
			}
			if reflect.DeepEqual(catalog.Items, search.Items) {
				t.Error("search returned catalog contents")
			}
			t.Logf("LIVE source=%s categories=%d home=%d category_items=%d second_page_items=%d more=%t Chinese_search=%d title=%q chapters=%d episode_selection=passed routes=%d readable_routes=%v", source, len(categories), len(home.Items), len(catalog.Items), len(secondPage.Items), catalog.HasMore, len(search.Items), parsed.Drama.Title, len(parsed.Chapters), len(choice.media), succeeded)
		})
	}
}
