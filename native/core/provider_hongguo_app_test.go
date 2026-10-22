package core

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHongguoCatalogUsesFullAppSignatureAndMatchingProfile(t *testing.T) {
	var signatures []string
	var device, install string
	downloader := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		query := request.URL.Query()
		for _, key := range []string{"version_code", "manifest_version_code", "update_version_code", "pv_player"} {
			if query.Get(key) != "71332" {
				t.Error("catalog profile does not match the full App signer", key)
			}
		}
		if query.Get("version_name") != "7.1.3.32" || request.Header.Get("User-Agent") != hongguoPlaybackUserAgent || query.Get("ts") != request.Header.Get("X-Khronos") || query.Get("_rticket") != request.Header.Get("X-SS-Req-Ticket") {
			t.Error("catalog request profile or timestamps are inconsistent")
		}
		for _, name := range []string{"X-Gorgon", "X-Medusa", "X-Helios", "X-Argus", "X-Ladon", "X-SS-STUB"} {
			if request.Header.Get(name) == "" {
				t.Error("catalog request is missing a full App signature header", name)
			}
		}
		if query.Get("device_id") != device || query.Get("iid") != install || request.Header.Get("X-SS-From-Web") != "0" {
			t.Error("catalog signing changed the saved device identity or client marker")
		}
		signatures = append(signatures, request.Header.Get("X-Medusa"))
		return nativeHongguoResponse(request, payload.Offset+18, true, "fixture-session", strconv.Itoa(1000+payload.Offset)), nil
	})
	state := downloader.hongguoCatalogSnapshot()
	device, install = state.DeviceID, state.InstallID
	ctx := context.WithValue(context.Background(), libraryMoreKey{}, true)
	for page := 0; page < 2; page++ {
		if _, err := downloader.fetchHongguoAppCatalogCategory(ctx, "short_play"); err != nil {
			t.Fatal("signed catalog could not advance to the next page", err)
		}
	}
	if len(signatures) != 2 || signatures[0] == signatures[1] {
		t.Fatal("catalog reused a signature across different page payloads")
	}
}

func TestHongguoAppRetriesEmptyResponsesWithFreshSignatures(t *testing.T) {
	for _, empty := range []string{"", " \r\n\t"} {
		t.Run(map[bool]string{true: "empty", false: "whitespace"}[empty == ""], func(t *testing.T) {
			var tickets []string
			downloader := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				body, err := io.ReadAll(request.Body)
				if err != nil || string(body) != `{"series_id":"1000"}` {
					t.Fatal("retry changed the requested payload", err)
				}
				tickets = append(tickets, request.Header.Get("X-SS-Req-Ticket"))
				if len(tickets) == 1 {
					return sourceFixtureResponse(request, http.StatusOK, empty), nil
				}
				return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"valid":true}}`), nil
			})
			downloader.cfg.Retries = 2
			result, err := downloader.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": "1000"})
			if err != nil || nestedMap(result, "data")["valid"] != true || len(tickets) != 2 || tickets[0] == "" || tickets[0] == tickets[1] {
				t.Fatal("empty response was not retried with a refreshed request signature", err, len(tickets))
			}
		})
	}
}

func TestHongguoAppEmptyResponseRetryHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	downloader := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls++
		cancel()
		return sourceFixtureResponse(request, http.StatusOK, ""), nil
	})
	downloader.cfg.Retries = 3
	_, err := downloader.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": "1000"})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal("canceled empty-response retry issued another request", err, calls)
	}
}

func TestHongguoEmptyResponsesAreBoundedAndKeepSavedCursor(t *testing.T) {
	calls := 0
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		if payload.Offset != 90 || payload.Session != "" {
			t.Fatal("empty response changed the saved request position")
		}
		calls++
		return sourceFixtureResponse(request, http.StatusOK, ""), nil
	})
	engine := reopenCatalogEngine(t, t.TempDir(), transport)
	engine.downloader.cfg.Retries = 2
	cursor := hongguoCatalogCursor{Offset: 90, Pages: 5, Initialized: true, UpdatedAt: time.Now()}
	state := engine.downloader.hongguoCatalogSnapshot()
	state.Feeds["category:ai_series"] = cursor
	engine.downloader.hongguoClient().state = *state
	engine.hongguoCatalog = cloneHongguoCatalogState(state)
	engine.catalogs["hongguo|ai_series"] = []nativeDrama{{ID: "hongguo:1000", Source: sourceHongguo, Title: "已保存剧目"}}
	if err := engine.writeCatalogDiskLocked(); err != nil {
		t.Fatal(err)
	}
	ctx := context.WithValue(context.Background(), libraryScanKey{}, true)
	_, err := engine.nativeCatalog(ctx, nativeInput{Source: sourceHongguo, Category: "ai_series", Page: 2, Force: true})
	if err == nil || !strings.Contains(err.Error(), "HTTP 200 返回空内容") || calls != 2 {
		t.Fatal("persistent empty responses were hidden or retried without a bound", err, calls)
	}
	restored := reopenCatalogEngine(t, engine.directory, transport)
	saved := restored.downloader.hongguoCatalogSnapshot().Feeds["category:ai_series"]
	samePosition := saved.Offset == cursor.Offset && saved.Pages == cursor.Pages && saved.Initialized == cursor.Initialized &&
		saved.Exhausted == cursor.Exhausted && saved.SessionID == cursor.SessionID && saved.UpdatedAt.Equal(cursor.UpdatedAt)
	if !samePosition || saved.StopReason != "error" || len(restored.catalogs["hongguo|ai_series"]) != 1 {
		t.Fatal("persistent empty responses advanced the cursor or discarded the saved catalog")
	}
}

func TestHongguoHealthProbesAppFeedsWithoutChangingSavedProgress(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(map[bool]string{false: "valid", true: "partial-empty"}[failure], func(t *testing.T) {
			var calls []nativeHongguoRequest
			engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
				payload := nativeHongguoRequestForTest(t, request)
				calls = append(calls, payload)
				if failure && payload.Scene == "default" {
					return sourceFixtureResponse(request, http.StatusOK, ""), nil
				}
				id := map[string]string{"default": "1000", "comic_series": "2000", "ai_series": "3000"}[payload.Scene]
				return nativeHongguoResponse(request, 18, true, "probe-session", id), nil
			})
			state := engine.downloader.hongguoCatalogSnapshot()
			state.ScanStartedAt = time.Now()
			for _, genre := range hongguoAppGenres {
				state.Feeds[genre.key] = hongguoCatalogCursor{Offset: 180, Pages: 10, Initialized: true, Exhausted: true, SessionID: "saved-session", UpdatedAt: time.Now()}
			}
			engine.downloader.hongguoClient().state = *cloneHongguoCatalogState(state)
			engine.hongguoCatalog = cloneHongguoCatalogState(state)
			if err := engine.writeCatalogDiskLocked(); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(engine.directory, "catalogs.json")
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			err = engine.checkSource(context.Background(), sourceHongguo, nativeDrama{}, false)
			health := engine.sourceStatus(sourceHongguo).Health
			if (err != nil) != failure || health == nil || len(health.Steps) != 1 {
				t.Fatal("health check concealed an App catalog failure", err, health)
			}
			if failure && health.State != "failed" || !failure && health.State != "catalogOnly" {
				t.Fatal("health state does not match the App feeds", health.State)
			}
			if len(calls) != 3 || health.Steps[0].Host != "api5-normal-sinfonlineb.fqnovel.com" || health.Steps[0].HTTPStatus != http.StatusOK {
				t.Fatal("App health check used a different catalog or read more than one page per feed", len(calls), health.Steps)
			}
			for _, payload := range calls {
				if payload.Offset != 0 || payload.Session != "" {
					t.Fatal("health probe reused a saved scan cursor")
				}
			}
			after, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(before, after) || !reflect.DeepEqual(state, engine.downloader.hongguoCatalogSnapshot()) {
				t.Fatal("health check changed the saved catalog or scan progress", err)
			}
		})
	}
}
