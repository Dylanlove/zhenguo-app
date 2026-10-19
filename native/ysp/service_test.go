package ysp

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCatchupTimeFormats(t *testing.T) {
	want := time.Date(2026, 10, 19, 1, 59, 0, 0, time.UTC).Unix()
	for _, input := range []string{
		strconv.FormatInt(want, 10), strconv.FormatInt(want*1000+123, 10),
		"20261019095900", "202610190959", "20261019015900Z",
		"2026-10-19T01:59:00Z", "2026-10-19T01:59:00.123Z",
		"2026-10-19T09:59:00+08:00", "2026-10-19 09:59:00", "2026-10-19T09:59",
	} {
		t.Run(input, func(t *testing.T) {
			got, err := catchupTime(input)
			if err != nil || got != want {
				t.Fatalf("got %d, %v; want %d", got, err, want)
			}
		})
	}
	for _, input := range []string{"", "not-a-time", "abc1792375140", "20261319095900"} {
		if _, err := catchupTime(input); err == nil {
			t.Fatalf("accepted invalid time %q", input)
		}
	}
	start, end, err := catchupQuery(url.Values{"playseek": {"20261019015900Z-20261019025900Z"}})
	if err != nil || start != want || end != want+3600 {
		t.Fatalf("playseek: %d %d %v", start, end, err)
	}
}

func playlistFixture(first, last int) string {
	var body strings.Builder
	body.WriteString("#EXTM3U\n#EXT-X-TARGETDURATION:6\n")
	for index := first; index <= last; index++ {
		fmt.Fprintf(&body, "#EXTINF:6,\n%d.ts?signature=fresh\n", index)
	}
	return body.String()
}

func TestStitchKeepsHistoryBeyondVisibleWindow(t *testing.T) {
	entry := &playlistEntry{}
	plan := Plan{Engine: "jce"}
	entry.stitch(playlistFixture(1, 200), "https://media.example/live.m3u8", plan)
	if len(entry.segments) != 25 {
		t.Fatalf("cold start retained %d segments", len(entry.segments))
	}
	entry.stitch(playlistFixture(201, 340), "https://media.example/live.m3u8", plan)
	before := entry.sequence
	body := "#EXTM3U\n#EXTINF:6,\n150.ts?signature=renewed\n#EXTINF:6,\n340.ts\n#EXTINF:6,\n341.ts\n"
	result := entry.stitch(body, "https://media.example/live.m3u8", plan)
	if entry.sequence != before+1 || strings.Contains(result, "/150.ts") {
		t.Fatalf("old segment replayed: sequence %d -> %d", before, entry.sequence)
	}
	if len(entry.segments) > 120 || len(entry.seenOrder) > 240 {
		t.Fatal("segment history exceeded bounds")
	}
}

func TestStitchUsesProgrammeTimeAcrossCDNs(t *testing.T) {
	entry := &playlistEntry{}
	body := "#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:2026-10-19T01:00:00Z\n#EXTINF:6,\nfirst.ts\n"
	entry.stitch(body, "https://first.example/live.m3u8", Plan{Engine: "jce"})
	entry.stitch(strings.ReplaceAll(body, "first.ts", "second.ts"), "https://second.example/live.m3u8", Plan{Engine: "jce"})
	if entry.sequence != 1 || !strings.Contains(entry.segments[0].address, "second.example/second.ts") {
		t.Fatal("same programme time was appended as a new segment")
	}
}

func TestDiscontinuityPrecedesMediaTags(t *testing.T) {
	entry := &playlistEntry{engine: "jce"}
	body := "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-PROGRAM-DATE-TIME:2026-10-19T01:00:00Z\n#EXTINF:6,\npart.m4s\n"
	got := entry.stitch(body, "https://media.example/live.m3u8", Plan{Engine: "device"})
	if !strings.Contains(got, "#EXT-X-DISCONTINUITY\n#EXT-X-PROGRAM-DATE-TIME:") || strings.Count(got, "#EXT-X-DISCONTINUITY\n") != 1 {
		t.Fatalf("incorrect discontinuity placement: %s", got)
	}
	if again := injectDiscontinuity(got); again != got {
		t.Fatal("duplicate discontinuity added")
	}
}

func TestConcurrentColdStartSharesRefresh(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		time.Sleep(30 * time.Millisecond)
		fmt.Fprint(w, playlistFixture(1, 5))
	}))
	defer upstream.Close()
	service, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.ctx = context.Background()
	channel := service.channels[0]
	entry := service.getEntry(channel, "auto", 0, 0)
	entry.high = Plan{URL: upstream.URL, Engine: "device", Expires: time.Now().Add(time.Hour).Unix()}
	var group sync.WaitGroup
	for range 8 {
		group.Add(1)
		go func() {
			defer group.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			body, err := service.Playlist(ctx, channel, "auto", 0, 0)
			if err != nil || !strings.HasPrefix(body, "#EXTM3U") {
				t.Errorf("cold start failed: %v", err)
			}
		}()
	}
	group.Wait()
	if calls.Load() != 1 {
		t.Fatalf("cold start fetched %d times", calls.Load())
	}
}

func TestForegroundSwitchCancelsPromotion(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	previous := &playlistEntry{promoting: true, promotion: 1, promoteCancel: cancel, firstUsed: time.Now()}
	service := &Service{foreground: previous}
	service.selectPlayback(&playlistEntry{})
	if ctx.Err() != context.Canceled || previous.promoting || previous.promotion != 2 || !previous.firstUsed.IsZero() {
		t.Fatal("previous channel promotion was not canceled")
	}
	current := service.foreground
	current.promoting = true
	if _, err := service.Command("idle", nil); err != nil || service.foreground != nil || current.promoting {
		t.Fatal("idle player retained a foreground promotion")
	}
}

func TestSubscriptionSupportsHTTPSProxy(t *testing.T) {
	service, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "http://tv.example/all.m3u", nil)
	request.Header.Set("X-Forwarded-Proto", "https")
	if got := service.subscription(request); !strings.Contains(got, "https://tv.example/live/cctv1.m3u8") {
		t.Fatal("HTTPS proxy origin was lost")
	}
}

func TestProxyKeepsRangeAfterRedirect(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/part", http.StatusTemporaryRedirect)
			return
		}
		if r.Header.Get("Range") != "bytes=1-3" {
			t.Error("Range missing after redirect")
		}
		w.Header().Set("Content-Range", "bytes 1-3/5")
		w.Header().Set("Accept-Ranges", "bytes")
		w.WriteHeader(http.StatusPartialContent)
		fmt.Fprint(w, "bcd")
	}))
	defer upstream.Close()
	service, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	path := service.registerAsset(upstream.URL+"/redirect", nil)
	request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1"+path, nil)
	request.Header.Set("Range", "bytes=1-3")
	response := httptest.NewRecorder()
	service.ServeHTTP(response, request)
	if response.Code != http.StatusPartialContent || response.Body.String() != "bcd" || response.Header().Get("Content-Range") != "bytes 1-3/5" || service.cacheBytes != 0 {
		t.Fatalf("range response changed: %d %q", response.Code, response.Body.String())
	}
}

func TestDeviceRecoveryPersistsAcrossRestart(t *testing.T) {
	root := t.TempDir()
	device := newDeviceClient(root)
	before := device.state.Profile["android_id"]
	if !device.rotate(&upstreamError{Status: 400, Host: "control.example"}) {
		t.Fatal("first recovery rejected")
	}
	restored := newDeviceClient(root)
	if restored.state.Rotations != 1 || restored.state.Profile["android_id"] == before || restored.rotate(&upstreamError{Status: 400, Host: "control.example"}) {
		t.Fatal("recovery identity or rate limit was not persisted")
	}
	if _, err := os.Stat(filepath.Join(root, "plans.json")); err != nil {
		t.Fatal(err)
	}
}
