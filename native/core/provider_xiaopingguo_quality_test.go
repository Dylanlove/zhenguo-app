package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

const mediaTestSPS720 = "6742c01fda014016ec044000000300400000030083c60ca8"
const mediaTestSPS1080 = "6742c028da01e0089f97011000000300100000030020f1832a"
const mediaTestSPSHEVC720 = "42010101600000030090000003000003005da00280802d16595952930bc05a020000030002000003000210"

func mediaTestMP4(encoded string) []byte {
	sps, _ := hex.DecodeString(encoded)
	config := []byte{1, 66, 192, 40, 255, 225, byte(len(sps) >> 8), byte(len(sps))}
	config = append(config, sps...)
	box := binary.BigEndian.AppendUint32(nil, uint32(8+len(config)))
	return append(append(box, []byte("avcC")...), config...)
}

func mediaTestTS(encoded string) []byte {
	sps, _ := hex.DecodeString(encoded)
	elementary := append(bytes.Repeat([]byte{0xab}, 170), []byte{0, 0, 0, 1}...)
	elementary = append(elementary, sps...)
	elementary = append(elementary, []byte{0, 0, 1, 9, 0x10}...)
	payload := append([]byte{0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0}, elementary...)
	var output []byte
	for index := 0; len(payload) > 0 || index < 3; index++ {
		packet := bytes.Repeat([]byte{0xff}, 188)
		packet[0], packet[1], packet[2], packet[3] = 0x47, 1, 0, 0x10|byte(index&15)
		if index == 0 {
			packet[1] |= 0x40
		}
		size := min(184, len(payload))
		copy(packet[4:], payload[:size])
		payload = payload[size:]
		output = append(output, packet...)
	}
	return output
}

func TestMediaResolutionReadsCodecParametersAcrossTSPackets(t *testing.T) {
	for _, item := range []struct {
		name          string
		data          []byte
		width, height int
	}{
		{"avc-mp4", mediaTestMP4(mediaTestSPS1080), 1920, 1080},
		{"avc-ts", mediaTestTS(mediaTestSPS720), 1280, 720},
		{"hevc-ts", mediaTestTS(mediaTestSPSHEVC720), 1280, 720},
		{"prefixed-ts", append([]byte("synthetic-prefix"), mediaTestTS(mediaTestSPS1080)...), 1920, 1080},
		{"not-media", []byte("超级无敌4K 3840x2160"), 0, 0},
		{"truncated-config", []byte{0, 0, 0, 64, 'a', 'v', 'c', 'C', 1}, 0, 0},
	} {
		t.Run(item.name, func(t *testing.T) {
			width, height := mediaResolution(item.data)
			if width != item.width || height != item.height {
				t.Fatalf("resolution = %dx%d, want %dx%d", width, height, item.width, item.height)
			}
		})
	}
}

func TestXiaopingguoQualityUsesEncryptedMediaInsteadOfMasterLabels(t *testing.T) {
	secret := []byte("0123456789abcdef")
	iv := make([]byte, 16)
	binary.BigEndian.PutUint64(iv[8:], 7)
	encrypted := pkcs7Pad(mediaTestTS(mediaTestSPS720), aes.BlockSize)
	block, _ := aes.NewCipher(secret)
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, encrypted)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "quality-fixture" || r.Header.Get("Referer") != "" {
			t.Error("media probe lost scoped headers")
		}
		switch r.URL.Path {
		case "/master.m3u8":
			fmt.Fprint(w, "#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=3840x2160,BANDWIDTH=10000000\nmedia.m3u8\n")
		case "/media.m3u8":
			fmt.Fprint(w, "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n")
		case "/key":
			w.Write(secret)
		case "/segment.ts":
			if r.Header.Get("Range") != "bytes=0-262143" {
				t.Error("probe must bound segment reads")
			}
			w.Write(encrypted)
		default:
			t.Error("unexpected request", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	d := &Downloader{client: server.Client()}
	media := d.prepareXiaopingguoPlayback(context.Background(), providerMedia{URL: server.URL + "/master.m3u8", RouteName: "线路 1",
		credentials: &providerMediaCredentials{userAgent: "quality-fixture", omitReferer: true}})
	if media.Quality != 720 || media.Width != 1280 || media.Height != 720 || media.RouteName != "线路 1 · 1280×720" {
		t.Fatalf("marketing or master metadata replaced codec resolution: %+v", media)
	}
}

func TestMediaResolutionFindsMP4MetadataAfterMediaData(t *testing.T) {
	payload := append(binary.BigEndian.AppendUint32(nil, 16), []byte("ftypisom0000")...)
	payload = binary.BigEndian.AppendUint32(payload, 2<<20)
	payload = append(payload, []byte("mdat")...)
	payload = append(payload, make([]byte, (2<<20)-8)...)
	payload = append(payload, mediaTestMP4(mediaTestSPS1080)...)
	var ranges []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ranges = append(ranges, r.Header.Get("Range"))
		http.ServeContent(w, r, "synthetic.mp4", time.Time{}, bytes.NewReader(payload))
	}))
	defer server.Close()
	d := &Downloader{client: server.Client()}
	media := d.inspectMediaResolution(context.Background(), providerMedia{URL: server.URL + "/video.mp4"})
	if media.Width != 1920 || media.Height != 1080 || len(ranges) != 2 || ranges[1] != "bytes=2097168-2359311" {
		t.Fatalf("MP4 metadata probe failed: %dx%d, ranges=%v", media.Width, media.Height, ranges)
	}
}

func TestXiaopingguoAutomaticQualityReevaluatesEveryEpisode(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "true"
	t.Cleanup(func() { buildAllSources = previous })
	engine := importedSourcesTestEngine(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case xiaopingguoDetailPath:
			detail := importedSourcesProto(map[int]string{9: "合成剧", 15: "2"})
			for episode := 1; episode <= 3; episode++ {
				order := []string{"low", "high", "unknown"}
				if episode == 2 {
					order = []string{"high", "unknown", "low"}
				} else if episode == 3 {
					order = []string{"low"}
				}
				for _, source := range order {
					detail = xiaopingguoProtoField(detail, 29, importedSourcesProto(map[int]string{
						3: fmt.Sprintf("第%d集", episode), 4: fmt.Sprintf("%s%d", source, episode), 9: source, 10: "超级无敌4K", 13: fmt.Sprint(episode),
					}))
				}
			}
			importedSourcesProtoResponse(w, detail)
		case "/api/proto/v5/videoUsableUrl":
			params, err := importedSourcesXPGParams(r)
			if err != nil {
				t.Error(err)
				return
			}
			token, _ := url.QueryUnescape(params.Get("playUrl"))
			importedSourcesProtoResponse(w, []byte("http://"+r.Host+"/"+token+".mp4"))
		default:
			switch {
			case strings.HasPrefix(r.URL.Path, "/low"):
				if strings.Contains(r.URL.Path, "2.mp4") {
					w.Write(mediaTestMP4(mediaTestSPS1080))
				} else {
					w.Write(mediaTestMP4(mediaTestSPS720))
				}
			case strings.HasPrefix(r.URL.Path, "/high"):
				if strings.Contains(r.URL.Path, "2.mp4") {
					w.Write(mediaTestMP4(mediaTestSPS720))
				} else {
					w.Write(mediaTestMP4(mediaTestSPS1080))
				}
			case strings.HasPrefix(r.URL.Path, "/unknown"):
				w.WriteHeader(http.StatusServiceUnavailable)
			default:
				t.Error("unexpected request", r.URL.Path)
				w.WriteHeader(404)
			}
		}
	})
	_, chapters, err := engine.downloader.fetchXiaopingguoDetail(context.Background(), "123")
	if err != nil || len(chapters) != 3 {
		t.Fatal(chapters, err)
	}
	resolve := func(episode int, quality int) nativePlan {
		t.Helper()
		plan, err := engine.nativeResolve(context.Background(), nativeInput{Drama: nativeDrama{ID: "xiaopingguo:123"}, Chapter: chapters[episode-1], Index: episode, Force: true, Quality: quality})
		if err != nil {
			t.Fatal(err)
		}
		return plan
	}
	initial := resolve(1, 0)
	if initial.Quality != 1080 || initial.RouteCount != 3 || initial.RouteNames[0] != "线路 2 · 1920×1080" {
		t.Fatalf("automatic selection ignored actual resolution: %+v", initial)
	}
	for _, name := range initial.RouteNames {
		if strings.Contains(name, "4K") {
			t.Fatal("unverified quality remained in route name", name)
		}
	}
	manual, err := engine.nativeSelectFilmRoute(context.Background(), initial.Session, 1)
	if err != nil || manual.Quality != 720 {
		t.Fatal("manual route selection no longer works for the current episode", manual, err)
	}
	next := resolve(2, 0)
	if next.Quality != 1080 || next.RouteNames[0] != "线路 3 · 1920×1080" {
		t.Fatalf("next episode retained a route instead of reevaluating resolution: %+v", next)
	}
	preloaded, err := engine.nativePreload(context.Background(), nativeInput{Drama: nativeDrama{ID: "xiaopingguo:123"}, Chapter: chapters[1], Index: 2, Force: true})
	if err != nil || preloaded.Quality != 1080 || preloaded.RouteNames[0] != "线路 3 · 1920×1080" {
		t.Fatal("preload ignored automatic quality selection", preloaded, err)
	}
	if selected := resolve(1, 720); selected.Quality != 720 || selected.RouteCount != 1 {
		t.Fatal("explicit quality preference no longer works", selected)
	}
	if available := resolve(3, 0); available.Quality != 720 {
		t.Fatal("missing high quality route blocked available media", available)
	}
}
