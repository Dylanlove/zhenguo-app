package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHongguoSourcePublishesAndPersistsPagesBeforeTaskStops(t *testing.T) {
	blocked := make(chan struct{})
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		if payload.Scene == "ai_series" {
			close(blocked)
			<-request.Context().Done()
			return nil, request.Context().Err()
		}
		ids := []string{"1001"}
		if payload.Scene == "default" {
			ids = append(ids, "1000")
		}
		return nativeHongguoResponse(request, 18, true, "fixture", ids...), nil
	})
	engine.catalogs[sourceHongguo] = []nativeDrama{{ID: "hongguo:1000", Source: sourceHongguo, Title: "保留剧目", Description: "保留资料"}}
	engine.deferCatalogSave = true
	status, err := engine.startSourceTask(sourceHongguo, "more", nativeDrama{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		engine.cancelSourceTask(sourceHongguo)
		awaitSourceTask(t, engine, sourceHongguo)
	})
	if status.DeadlineAt.Sub(status.StartedAt) < 11*time.Minute || status.DeadlineAt.Sub(status.StartedAt) > 12*time.Minute {
		t.Fatal("task did not expose its actual time limit", status)
	}
	select {
	case <-blocked:
	case <-time.After(3 * time.Second):
		t.Fatal("scan did not reach the blocked request")
	}
	status = engine.sourceStatus(sourceHongguo)
	if !status.Running || status.Count != 2 || status.Added != 1 || status.CatalogScan.Feeds[0].Pages != 1 || status.CatalogScan.Feeds[1].Pages != 1 || !strings.Contains(status.Stage, "漫剧") {
		t.Fatal("completed pages were invisible while the task was still running", status)
	}
	body, err := os.ReadFile(filepath.Join(engine.directory, "catalogs.json"))
	if err != nil {
		t.Fatal(err)
	}
	var disk nativeCatalogDisk
	if err := json.Unmarshal(body, &disk); err != nil {
		t.Fatal(err)
	}
	if len(disk.Catalogs[sourceHongguo]) != 2 || disk.HongguoApp.Feeds["short_play"].Offset != 18 || disk.HongguoApp.Feeds["comic_series"].Offset != 18 || disk.HongguoApp.Feeds["ai_series"].Initialized {
		t.Fatal("page items and cursors were not saved together before the next request", disk.HongguoApp)
	}
	engine.mu.Lock()
	deferred := engine.deferCatalogSave
	engine.mu.Unlock()
	if !deferred {
		t.Fatal("page checkpoint changed another source's deferred-save setting")
	}
	engine.cancelSourceTask(sourceHongguo)
	status = awaitSourceTask(t, engine, sourceHongguo)
	if status.Count != 2 || status.Added != 1 || !status.DeadlineAt.IsZero() {
		t.Fatal("stopping changed the published count or retained a finished deadline", status)
	}
	var offsets []int
	restored := reopenCatalogEngine(t, engine.directory, func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		offsets = append(offsets, payload.Offset)
		return nativeHongguoResponse(request, payload.Offset+18, false, "fixture", strconv.Itoa(2000+len(offsets))), nil
	})
	if err := restored.loadHongguoSourceCatalog(context.Background(), "more"); err != nil || !reflect.DeepEqual(offsets, []int{18, 18, 0}) || restored.sourceStatus(sourceHongguo).Count != 5 {
		t.Fatal("restart did not resume the last durable page", err, offsets)
	}
}

func TestHongguoPageSaveFailureStopsBeforeAnotherRequest(t *testing.T) {
	calls := 0
	var path string
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		nativeHongguoRequestForTest(t, request)
		calls++
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
		return nativeHongguoResponse(request, 18, true, "fixture", "1000"), nil
	})
	path = filepath.Join(engine.directory, "catalogs.json")
	err := engine.loadHongguoSourceCatalog(context.Background(), "update")
	var persistence *nativePersistenceError
	if !errors.As(err, &persistence) || calls != 1 || engine.sourceStatus(sourceHongguo).Count != 1 || engine.sourceStatus(sourceHongguo).StorageError == "" {
		t.Fatal("failed page save allowed further requests or hid unsaved content", err, calls)
	}
}

func TestHongguoSourceUpdateRescansEndedCatalogPastKnownPages(t *testing.T) {
	calls := map[string][]int{}
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		calls[payload.Scene] = append(calls[payload.Scene], payload.Offset)
		base := map[string]int{"default": 1000, "comic_series": 2000, "ai_series": 3000}[payload.Scene]
		return nativeHongguoResponse(request, payload.Offset+18, payload.Offset < 72, "fixture-new", strconv.Itoa(base+payload.Offset/18)), nil
	})
	engine.downloader.cfg.MaxPagesPerSort = 6
	state := engine.downloader.hongguoCatalogSnapshot()
	device, install := state.DeviceID, state.InstallID
	for _, genre := range hongguoAppGenres {
		state.Feeds[genre.key] = hongguoCatalogCursor{Offset: 72, Initialized: true, Exhausted: true, UpdatedAt: time.Now()}
		base := map[string]int{"short_play": 1000, "comic_series": 2000, "ai_series": 3000}[genre.key]
		for page := 0; page < 4; page++ {
			id := "hongguo:" + strconv.Itoa(base+page)
			engine.catalogs[sourceHongguo] = append(engine.catalogs[sourceHongguo], nativeDrama{ID: id, Source: sourceHongguo, Title: id, Description: "保留资料"})
		}
	}
	category := hongguoCatalogCursor{Offset: 144, Initialized: true, Exhausted: false, SessionID: "category-session"}
	state.Feeds["category:short_play"] = category
	engine.downloader.hongguoClient().state = *state
	engine.hongguoCatalog = cloneHongguoCatalogState(state)
	engine.catalogStates[sourceHongguo] = nativeCatalogState{Page: 3, HasMore: false}
	if err := engine.writeCatalogDiskLocked(); err != nil {
		t.Fatal(err)
	}
	if err := engine.loadHongguoSourceCatalog(context.Background(), "update"); err != nil {
		t.Fatal(err)
	}
	for scene, offsets := range calls {
		if !reflect.DeepEqual(offsets, []int{0, 18, 36, 54, 72}) {
			t.Fatal("rescan stopped at known pages or reused an ended cursor", scene, offsets)
		}
	}
	if len(calls) != 3 || len(engine.catalogs[sourceHongguo]) != 15 || engine.catalogs[sourceHongguo][0].Description != "保留资料" {
		t.Fatal("rescan lost old metadata, skipped a feed or duplicated entries")
	}
	restored := reopenCatalogEngine(t, engine.directory, engine.downloader.client.Transport.(sourceFixtureTransport))
	snapshot := restored.downloader.hongguoCatalogSnapshot()
	if snapshot.DeviceID != device || snapshot.InstallID != install || snapshot.Feeds["category:short_play"] != category || snapshot.ScanStartedAt.IsZero() {
		t.Fatal("rescan changed catalog identity or an independent category cursor")
	}
	status := restored.sourceStatus(sourceHongguo)
	if status.HasMore || status.Page != 1 || status.CatalogScan.State != "complete" {
		t.Fatal("new scan did not reset its batch number or persist its completion", status)
	}
	for _, feed := range status.CatalogScan.Feeds {
		if feed.Offset != 90 || feed.Pages != 5 || !feed.Exhausted {
			t.Fatal("feed diagnostics did not reflect successful pages", feed)
		}
	}
}

func TestHongguoSourceUpdateResumesAfterRestartAndExplicitRescanRestarts(t *testing.T) {
	var calls []int
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		payload := nativeHongguoRequestForTest(t, request)
		calls = append(calls, payload.Offset)
		base := map[string]int{"default": 1000, "comic_series": 2000, "ai_series": 3000}[payload.Scene]
		return nativeHongguoResponse(request, payload.Offset+18, true, "fixture", strconv.Itoa(base+payload.Offset/18)), nil
	})
	engine := reopenCatalogEngine(t, t.TempDir(), transport)
	if err := engine.loadHongguoSourceCatalog(context.Background(), "update"); err != nil {
		t.Fatal(err)
	}
	started := engine.hongguoCatalog.ScanStartedAt
	engine = reopenCatalogEngine(t, engine.directory, transport)
	calls = nil
	if err := engine.loadHongguoSourceCatalog(context.Background(), "update"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(calls, []int{18, 18, 18}) || !engine.hongguoCatalog.ScanStartedAt.Equal(started) || len(engine.catalogs[sourceHongguo]) != 6 {
		t.Fatal("update restarted an unfinished round or lost its saved content", calls)
	}
	calls = nil
	if err := engine.loadHongguoSourceCatalog(context.Background(), "rescan"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(calls, []int{0, 0, 0}) || len(engine.catalogs[sourceHongguo]) != 6 || !engine.hongguoCatalog.ScanStartedAt.After(started) {
		t.Fatal("explicit rescan did not start from zero while retaining content", calls)
	}
}

func TestHongguoSourceScanFailuresKeepSavedOffsetsAndAllowResume(t *testing.T) {
	for _, scenario := range []string{"canceled", "request-error"} {
		t.Run(scenario, func(t *testing.T) {
			transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
				payload := nativeHongguoRequestForTest(t, request)
				base := map[string]int{"default": 1000, "comic_series": 2000, "ai_series": 3000}[payload.Scene]
				return nativeHongguoResponse(request, payload.Offset+18, true, "fixture", strconv.Itoa(base+payload.Offset/18)), nil
			})
			engine := reopenCatalogEngine(t, t.TempDir(), transport)
			if err := engine.loadHongguoSourceCatalog(context.Background(), "update"); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			engine.downloader.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
				payload := nativeHongguoRequestForTest(t, request)
				if payload.Offset != 18 {
					t.Error("failed read changed the last successful offset", payload)
				}
				if scenario == "canceled" {
					cancel()
					return nil, ctx.Err()
				}
				return sourceFixtureResponse(request, http.StatusBadGateway, "fixture failure"), nil
			})
			err := engine.loadHongguoSourceCatalog(ctx, "update")
			if err == nil || scenario == "canceled" && !errors.Is(err, context.Canceled) {
				t.Fatal("scan discarded the cancellation or request failure", err)
			}
			engine = reopenCatalogEngine(t, engine.directory, transport)
			status := engine.sourceStatus(sourceHongguo)
			if status.Count != 3 || !status.HasMore || status.CatalogScan.State != "interrupted" {
				t.Fatal("failure was persisted as an exhausted or empty catalog", status)
			}
			for _, feed := range status.CatalogScan.Feeds {
				if feed.Offset != 18 || feed.Exhausted {
					t.Fatal("failure advanced or exhausted a saved cursor", feed)
				}
			}
			if err := engine.loadHongguoSourceCatalog(context.Background(), "update"); err != nil || len(engine.catalogs[sourceHongguo]) != 6 {
				t.Fatal("failed scan could not resume its saved position", err)
			}
		})
	}
}

func TestHongguoEmptyScanCompletesWithoutDroppingOldCatalog(t *testing.T) {
	engine := reopenCatalogEngine(t, t.TempDir(), func(request *http.Request) (*http.Response, error) {
		nativeHongguoRequestForTest(t, request)
		return nativeHongguoResponse(request, 0, false, "fixture"), nil
	})
	engine.catalogs[sourceHongguo] = []nativeDrama{{ID: "hongguo:1000", Source: sourceHongguo, Title: "保留剧目"}}
	if err := engine.loadHongguoSourceCatalog(context.Background(), "rescan"); err != nil {
		t.Fatal("valid empty end was treated as a request failure", err)
	}
	status := engine.sourceStatus(sourceHongguo)
	if status.Count != 1 || status.HasMore || status.CatalogScan.State != "complete" {
		t.Fatal("empty round dropped the old library or remained unfinished", status)
	}
}

func TestHongguoRescanSaveFailureStopsBeforeCatalogRequests(t *testing.T) {
	calls := 0
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		calls++
		return nil, errors.New("catalog requests must wait until the reset is saved")
	})
	engine.catalogs[sourceHongguo] = []nativeDrama{{ID: "hongguo:1000", Source: sourceHongguo, Title: "保留剧目"}}
	path := filepath.Join(engine.directory, "catalogs.json")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	err := engine.loadHongguoSourceCatalog(context.Background(), "rescan")
	var persistence *nativePersistenceError
	if !errors.As(err, &persistence) || calls != 0 || len(engine.catalogs[sourceHongguo]) != 1 {
		t.Fatal("unsaved reset fetched new pages or dropped existing content", err, calls)
	}
	if engine.sourceStatus(sourceHongguo).StorageError == "" {
		t.Fatal("unsaved reset was not reported")
	}
}
