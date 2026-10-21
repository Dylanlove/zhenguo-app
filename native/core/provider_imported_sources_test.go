package core

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func importedSourcesTestEngine(t *testing.T, handler http.HandlerFunc) *nativeEngine {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d := engine.downloader
	d.client, d.limiter = server.Client(), newRequestLimiter(4, 0)
	d.cfg.XiaopingguoURL, d.cfg.MiguoHoneyURL = server.URL, server.URL
	t.Cleanup(func() {
		if engine.stream != nil {
			engine.stream.server.Close()
		}
	})
	return engine
}

func importedSourcesProto(fields map[int]string) []byte {
	var payload []byte
	for number, value := range fields {
		payload = xiaopingguoProtoField(payload, number, []byte(value))
	}
	return payload
}

func importedSourcesProtoResponse(writer http.ResponseWriter, payload []byte) {
	body := binary.AppendUvarint(nil, 1<<3)
	body = binary.AppendUvarint(body, 200)
	body = xiaopingguoProtoField(body, 3, payload)
	writer.Header().Set("Content-Type", "application/x-protobuf")
	writer.Write(body)
}

func importedSourcesXPGParams(request *http.Request) (url.Values, error) {
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return nil, err
	}
	fields, err := xiaopingguoProto(body)
	if err != nil {
		return nil, err
	}
	flat := xiaopingguoFlat(fields)
	joined := flat[1] + flat[2]
	if len(joined) < 8 || joined[:8] != flat[5] {
		return nil, fmt.Errorf("invalid binary envelope")
	}
	plain, err := xiaopingguoDecrypt(joined[8:], xiaopingguoBodyKey, "")
	if err != nil {
		return nil, err
	}
	timestamp := flat[4]
	if !strings.HasSuffix(string(plain), timestamp) {
		return nil, fmt.Errorf("body timestamp mismatch")
	}
	return url.ParseQuery(strings.TrimSuffix(string(plain), timestamp))
}

func TestImportedSourcesRegistrationAndFilters(t *testing.T) {
	previous := buildAllSources
	t.Cleanup(func() { buildAllSources = previous })
	for _, edition := range []string{"false", "true"} {
		buildAllSources = edition
		for _, source := range []string{sourceXiaopingguo, sourceMiguoHoney} {
			if nativeSourceAvailable(source) != (edition == "true") || !isFilmProviderSource(source) {
				t.Fatal("source registration or edition gate failed", source)
			}
			categories, err := (&nativeEngine{}).nativeCategories(context.Background(), source, false)
			if err != nil || len(categories) < 8 {
				t.Fatal("missing categories", source, err)
			}
			for _, category := range categories {
				if !validNativeCategory(source, category.ID) {
					t.Fatal("invalid declared category", source, category.ID)
				}
			}
		}
	}
	if sourceMiguoHoney == sourceMiguo {
		t.Fatal("honey source must not overwrite Dami source")
	}
	for _, selection := range []string{"video?cat=genres%2FVR", "duanju?cat=yeguo&sub=3", "hongtao?cat=tc", "shortv?cat=HS%E6%97%A5%E6%9C%AC4K%E5%8A%A8%E6%BC%AB"} {
		if !validNativeCategory(sourceMiguoHoney, selection) {
			t.Fatal("valid source filter rejected", selection)
		}
	}
	for _, selection := range []string{"video?cat=unknown", "hongtao?cat=tc&sub=2", "video?token=secret", "video?cat=new&cat=fc2"} {
		if validNativeCategory(sourceMiguoHoney, selection) {
			t.Fatal("invalid source filter accepted", selection)
		}
	}
	if !validNativeCategory(sourceXiaopingguo, "115?area=%E9%9F%A9%E5%9B%BD&sort=%E6%9C%80%E7%83%AD") {
		t.Fatal("Netflix filter rejected")
	}
	if nativeCatalogKey(sourceMiguoHoney, "video?cat=fc2") == nativeCatalogKey(sourceMiguoHoney, "video?cat=new") {
		t.Fatal("filtered caches collide")
	}
}

func TestXiaopingguoBinaryCatalogAndEpisodeRoutes(t *testing.T) {
	var requests atomic.Int32
	engine := importedSourcesTestEngine(t, func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		if request.Header.Get("User-Agent") != xiaopingguoUserAgent || request.Header.Get("Content-Type") != "application/x-protobuf" {
			t.Error("missing binary protocol headers")
		}
		var public map[string]string
		if json.Unmarshal([]byte(request.Header.Get("publicParams")), &public) != nil {
			t.Error("invalid public params")
			return
		}
		encrypted, err := hex.DecodeString(public["paramsData"])
		if err != nil {
			t.Error(err)
			return
		}
		plain, err := xiaopingguoDecrypt(base64.StdEncoding.EncodeToString(encrypted), xiaopingguoHeaderKey, xiaopingguoHeaderKey)
		if err != nil {
			t.Error(err)
			return
		}
		var headers map[string]any
		if json.Unmarshal(plain, &headers) != nil || headers["tenantId"] != "xpg" || headers["vApp"] != "1003" || len(nativeText(headers["uuid"])) != 32 {
			t.Error("invalid device parameters")
			return
		}
		params, err := importedSourcesXPGParams(request)
		if err != nil {
			t.Error(err)
			return
		}
		switch request.URL.Path {
		case "/api/proto/v5/drama/category", "/api/proto/v5/drama/search":
			if request.URL.Path == "/api/proto/v5/drama/category" && params.Get("typeId1") != "2" {
				t.Error("wrong category")
			}
			if request.URL.Path == "/api/proto/v5/drama/search" && params.Get("searchKeys") != "合成剧" {
				t.Error("search keyword corrupted")
			}
			card := importedSourcesProto(map[int]string{3: "123", 5: "合成剧", 2: "https://posters.invalid/never-request.jpg", 9: "2"})
			importedSourcesProtoResponse(writer, xiaopingguoProtoField(nil, 1, card))
		case xiaopingguoDetailPath:
			if params.Get("id") != "123" {
				t.Error("wrong detail")
			}
			detail := importedSourcesProto(map[int]string{9: "合成剧", 15: "2", 6: "<p>合成简介</p>"})
			for _, route := range []map[int]string{
				{3: "第2集", 4: "two", 9: "Ksvideo", 13: "2"},
				{3: "第1集", 4: "one", 9: "Ksvideo", 10: "原画", 13: "1"},
				{3: "第1集", 4: "backup", 9: "备用", 13: "1"},
				{3: "第1集", 4: "bad", 9: "坏线路", 13: "1"},
				{3: "第1集", 4: "excluded", 9: "youku", 13: "1"},
			} {
				detail = xiaopingguoProtoField(detail, 29, importedSourcesProto(route))
			}
			importedSourcesProtoResponse(writer, detail)
		case "/api/proto/v5/videoUsableUrl":
			token, _ := url.QueryUnescape(params.Get("playUrl"))
			address := "https://media.invalid/" + token + ".mp4?signature=a%2Fb&order=1"
			if token == "bad" {
				address = "https://media.invalid/player.html"
			}
			importedSourcesProtoResponse(writer, []byte(address))
		default:
			t.Error("unexpected request, including cover or media", request.URL)
			writer.WriteHeader(http.StatusNotFound)
		}
	})
	d := engine.downloader
	items, more, err := d.fetchXiaopingguoCatalogPage(context.Background(), 1, "2", "")
	if err != nil || more || len(items) != 1 || items[0].ID != "xiaopingguo:123" {
		t.Fatal(items, more, err)
	}
	items, _, err = d.fetchXiaopingguoCatalogPage(context.Background(), 2, "", "合成剧")
	if err != nil || len(items) != 1 {
		t.Fatal(items, err)
	}
	_, chapters, err := d.fetchXiaopingguoDetail(context.Background(), "123")
	if err != nil || len(chapters) != 2 || chapters[0].EpisodeString(0) != "1" {
		t.Fatal(chapters, err)
	}
	media, err := d.resolveXiaopingguoMedia(context.Background(), Task{DramaID: "xiaopingguo:123", Chapter: chapters[0]})
	if err != nil || len(media.Variants) != 1 || media.RouteName != "线路 1" || media.Variants[0].RouteName != "线路 2" || !strings.Contains(media.URL, "signature=a%2Fb&order=1") {
		t.Fatal("episode lines were lost, mixed, or corrupted", media, err)
	}
	if media.credentials == nil || !media.credentials.omitReferer || media.credentials.userAgent != xiaopingguoUserAgent {
		t.Fatal("media headers lost")
	}
	before := requests.Load()
	chapters[0].ID = providerChapterID(sourceXiaopingguo, "999", "invalid")
	if _, err := d.resolveXiaopingguoMedia(context.Background(), Task{DramaID: "xiaopingguo:123", Chapter: chapters[0]}); err == nil || requests.Load() != before {
		t.Fatal("mismatched episode reached network")
	}
}

func TestMiguoHoneyHandshakeRefreshSearchAndProxy(t *testing.T) {
	var handshakes atomic.Int32
	var refused atomic.Bool
	key := []byte("0123456789abcdef0123456789abcdef")
	engine := importedSourcesTestEngine(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		if request.URL.Path == "/api/handshake" {
			if request.URL.Query().Get("dev") == "" {
				t.Error("device missing")
			}
			if proof := request.URL.Query().Get("c"); proof == "" {
				io.WriteString(writer, `{"need_chal":"fixture","bits":4}`)
			} else {
				challenge, nonce, ok := strings.Cut(proof, ".")
				if !ok || challenge != "fixture" || miguoHoneyProof(challenge, nonce)>>28 != 0 {
					t.Error("invalid challenge proof")
				}
				sid := "session-" + strconv.Itoa(int(handshakes.Add(1)))
				json.NewEncoder(writer).Encode(map[string]any{"sid": sid, "skey": hex.EncodeToString(key), "exp": time.Now().Add(time.Hour).Unix()})
			}
			return
		}
		body := sha256.Sum256(nil)
		canonical := strings.Join([]string{request.Method, request.URL.EscapedPath(), request.URL.RawQuery, hex.EncodeToString(body[:]),
			request.Header.Get("X-Hp-Ts"), request.Header.Get("X-Hp-Nonce"), request.Header.Get("X-Hp-Sid")}, "\n")
		signer := hmac.New(sha256.New, key)
		signer.Write([]byte(canonical))
		if request.Header.Get("X-Hp-Sign") != hex.EncodeToString(signer.Sum(nil)) || request.Header.Get("Referer") != miguoHoneyReferer {
			t.Error("signature or referer mismatch")
		}
		if request.URL.Path == "/api/module" && !refused.Swap(true) {
			writer.WriteHeader(http.StatusUnauthorized)
			io.WriteString(writer, `{}`)
			return
		}
		switch request.URL.Path {
		case "/api/module":
			if request.URL.Query().Get("cat") != "genres/VR" || request.URL.Query().Get("src") != "missav" {
				t.Error("VR selector corrupted")
			}
			io.WriteString(writer, `{"list":[{"id":"fixture","title":"合成视频","cover":"https://posters.invalid/never-request.jpg"}],"has_more":true}`)
		case "/api/search":
			if request.URL.Query().Get("kw") != "合成" {
				t.Error("keyword corrupted")
			}
			if request.URL.Query().Get("key") == "shortv" {
				writer.WriteHeader(500)
				io.WriteString(writer, `{}`)
				return
			}
			io.WriteString(writer, `{"list":[{"id":"fixture","title":"合成结果","src":"huangdou"}],"has_more":false}`)
		case "/api/detail/video/fixture":
			io.WriteString(writer, `{"detail":{"title":"合成视频","episodes":[{"ep":1,"name":"1"},{"ep":2,"name":"2","lock":true}]}}`)
		case "/api/play/video/fixture/1":
			io.WriteString(writer, `{"play":{"src":"https://media.invalid/preview-r10/a.mp4","src_proxy":"/stream?token=a%2Fb"}}`)
		default:
			t.Error("unexpected request, including cover or media", request.URL)
			writer.WriteHeader(http.StatusNotFound)
		}
	})
	d := engine.downloader
	items, more, err := d.fetchMiguoHoneyCatalogPage(context.Background(), 2, "video?cat=genres%2FVR", "")
	if err != nil || !more || len(items) != 1 || handshakes.Load() != 2 {
		t.Fatal(items, more, handshakes.Load(), err)
	}
	if !strings.Contains(nativeText(items[0].Cover), "/cover/video?u=") {
		t.Fatal("cover proxy address missing")
	}
	keyID := items[0].SourceID
	_, chapters, err := d.fetchMiguoHoneyDetail(context.Background(), keyID)
	if err != nil || len(chapters) != 2 || !chapters[1].VIP || !strings.Contains(chapters[1].Title, "试看") {
		t.Fatal(chapters, err)
	}
	media, err := d.resolveMiguoHoneyMedia(context.Background(), Task{DramaID: items[0].ID, Chapter: chapters[0]})
	if err != nil || media.RouteName != "蜜果代理" || len(media.Variants) != 1 || !strings.Contains(media.Variants[0].RouteName, "试看") || !strings.Contains(media.URL, "token=a%2Fb&format=.m3u8") || !providerMediaHLSURL(media.URL) {
		t.Fatal("proxy and preview routes not preserved", media, err)
	}
	items, _, err = d.fetchMiguoHoneyCatalogPage(context.Background(), 1, "", "合成")
	if err == nil || len(items) != 6 || handshakes.Load() != 2 {
		t.Fatal("partial module search or session cache failed", len(items), handshakes.Load(), err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := miguoHoneySolve(ctx, "fixture", 16); err == nil {
		t.Fatal("challenge ignored cancellation")
	}
}

func TestXiaopingguoRRSPEncryptedResponseAndExactEpisode(t *testing.T) {
	engine := importedSourcesTestEngine(t, func(writer http.ResponseWriter, request *http.Request) {
		t.Error("RRSP fixture attempted a network request")
		writer.WriteHeader(http.StatusNotFound)
	})
	var playRequests int
	expected := "https://media.invalid/video.m3u8?auth_key=fixture-token"
	engine.downloader.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "api.rrmj.plus" || request.Header.Get("Referer") != xiaopingguoRRSPReferer {
			t.Error("wrong RRSP request target")
		}
		device, timestamp := request.Header.Get("aliId"), request.Header.Get("t")
		canonical := "GET\naliId:" + device + "\nct:web_applet\ncv:1.0.0\nt:" + timestamp + "\n" + request.URL.Path + "?" + request.URL.RawQuery
		signer := hmac.New(sha256.New, []byte(xiaopingguoRRSPSignKey))
		signer.Write([]byte(canonical))
		if request.Header.Get("x-ca-sign") != base64.StdEncoding.EncodeToString(signer.Sum(nil)) {
			t.Error("RRSP signature mismatch")
		}
		var response map[string]any
		switch request.URL.Path {
		case "/m-station/drama/page":
			response = map[string]any{"data": map[string]any{"episodeList": []any{map[string]any{"episodeNo": 2, "sid": "episode-2"}}}}
		case "/m-station/drama/play":
			playRequests++
			if request.URL.Query().Get("episodeSid") != "episode-2" || request.URL.Query().Get("dramaId") != "456" {
				t.Error("RRSP changed requested episode")
			}
			encrypted, err := xiaopingguoEncrypt([]byte(expected), []byte("0123456789abcdef"), []byte(xiaopingguoRRSPPlayIV))
			if err != nil {
				return nil, err
			}
			response = map[string]any{"data": map[string]any{"newSign": "xxxx0123456789abcdefxxxx", "m3u8": map[string]string{"url": base64.StdEncoding.EncodeToString(encrypted)}}}
		default:
			return nil, fmt.Errorf("unexpected RRSP path %s", request.URL.Path)
		}
		plain, err := json.Marshal(response)
		if err != nil {
			return nil, err
		}
		encrypted, err := xiaopingguoEncrypt(plain, []byte(xiaopingguoRRSPResponseKey), nil)
		if err != nil {
			return nil, err
		}
		body, err := json.Marshal(base64.StdEncoding.EncodeToString(encrypted))
		if err != nil {
			return nil, err
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Request: request, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})
	address, err := engine.downloader.resolveXiaopingguoRRSP(context.Background(), "https://mh.yichengwlkj.com/drama/456?episodeNo=2")
	if err != nil || address != expected || playRequests != 1 {
		t.Fatal(address, playRequests, err)
	}
	if _, err := engine.downloader.resolveXiaopingguoRRSP(context.Background(), "https://mh.yichengwlkj.com/drama/456?episodeNo=3"); err == nil || playRequests != 1 {
		t.Fatal("missing RRSP episode was silently replaced")
	}
}

func TestImportedSourceHLSQueryHintAndDASHPlayback(t *testing.T) {
	engine := importedSourcesTestEngine(t, func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/stream" || request.URL.Query().Get("token") != "a/b" || request.Header.Get("User-Agent") != miguoHoneyUserAgent || request.Header.Get("Referer") != miguoHoneyReferer {
			t.Error("media request or headers corrupted", request.URL)
		}
		writer.Header().Set("Content-Type", "application/octet-stream")
		io.WriteString(writer, "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts?signature=keep\n#EXT-X-ENDLIST\n")
	})
	address := engine.downloader.cfg.MiguoHoneyURL + "/stream?token=a%2Fb&format=.m3u8"
	media := providerMedia{URL: address, Referer: miguoHoneyReferer, RouteName: "蜜果代理",
		credentials: &providerMediaCredentials{userAgent: miguoHoneyUserAgent, referer: miguoHoneyReferer}}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil || !strings.HasSuffix(plan.URL, ".m3u8") {
		t.Fatal("HLS query hint lost in gateway", plan, err)
	}
	response, err := http.Get(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 || !strings.Contains(response.Header.Get("Content-Type"), "mpegurl") || !strings.Contains(string(body), engine.stream.address) {
		t.Fatal("HLS was not rewritten", string(body), err)
	}
	manager := &nativeDownloads{engine: engine}
	bundle, err := manager.downloadBundle(context.Background(), media, 0)
	if err != nil || len(bundle.assets) != 1 || len(bundle.playlists["index.m3u8"]) == 0 {
		t.Fatal("HLS hint lost in download", bundle, err)
	}
	media.URL = "https://media.invalid/video.mpd?token=keep"
	plan, err = engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil || plan.URL != media.URL || plan.Headers["User-Agent"] != miguoHoneyUserAgent || plan.Headers["Referer"] != miguoHoneyReferer {
		t.Fatal("DASH playback or request headers lost", plan, err)
	}
}
