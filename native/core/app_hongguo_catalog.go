package core

import (
	"context"
	"errors"
	"time"
)

type nativeCatalogScanFeed struct {
	Name        string    `json:"name"`
	Offset      int       `json:"offset"`
	Pages       int       `json:"pages"`
	Initialized bool      `json:"initialized"`
	Exhausted   bool      `json:"exhausted"`
	Reason      string    `json:"reason"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type nativeCatalogScan struct {
	State     string                  `json:"state"`
	StartedAt time.Time               `json:"startedAt"`
	Feeds     []nativeCatalogScanFeed `json:"feeds"`
}

func (engine *nativeEngine) hongguoScanStatusLocked(record nativeSourceRecord) *nativeCatalogScan {
	scan := &nativeCatalogScan{State: "not_started", Feeds: []nativeCatalogScanFeed{}}
	state := engine.hongguoCatalog
	if state != nil {
		scan.StartedAt = state.ScanStartedAt
	}
	initialized, ended, interrupted := false, true, false
	if !record.Running && (record.Operation == "update" || record.Operation == "more" || record.Operation == "rescan") && record.Error != "" {
		interrupted = true
	}
	for _, genre := range hongguoAppGenres {
		var cursor hongguoCatalogCursor
		if state != nil {
			cursor = state.Feeds[genre.key]
		}
		initialized = initialized || cursor.Initialized
		ended = ended && cursor.Initialized && cursor.Exhausted
		reason := "可继续读取"
		if !cursor.Initialized {
			reason = "尚未读取"
		}
		switch cursor.StopReason {
		case "batch":
			reason = "本批读取完成，可继续"
		case "error":
			reason, interrupted = "请求或分页异常，位置已保留", true
		case "canceled":
			reason, interrupted = "任务已停止，进度已保留", true
		case "timeout":
			reason, interrupted = "任务达到时限，进度已保留", true
		}
		if cursor.Exhausted {
			reason = "接口返回本轮结束"
		}
		scan.Feeds = append(scan.Feeds, nativeCatalogScanFeed{Name: genre.name, Offset: cursor.Offset, Pages: cursor.Pages,
			Initialized: cursor.Initialized, Exhausted: cursor.Exhausted, Reason: reason, UpdatedAt: cursor.UpdatedAt})
	}
	switch {
	case ended:
		scan.State = "complete"
	case record.Running && (record.Operation == "update" || record.Operation == "more" || record.Operation == "rescan"):
		scan.State = "scanning"
	case interrupted || engine.catalogStates[sourceHongguo].Warning != "":
		scan.State = "interrupted"
	case initialized || !scan.StartedAt.IsZero():
		scan.State = "ready"
	}
	return scan
}

func (engine *nativeEngine) prepareHongguoCatalogScan(ctx context.Context, operation string) error {
	unlock, err := engine.lockSourceCatalog(ctx, sourceHongguo)
	if err != nil {
		return err
	}
	defer unlock()
	if _, err := engine.retryCatalogSave(); err != nil {
		return err
	}
	client := engine.downloader.hongguoClient()
	client.catalogMu.Lock()
	defer client.catalogMu.Unlock()
	state := engine.downloader.hongguoCatalogSnapshot()
	initialized := false
	for _, genre := range hongguoAppGenres {
		initialized = initialized || state.Feeds[genre.key].Initialized
	}
	restart := operation == "rescan" || !initialized || operation == "update" && !hongguoCatalogHasMore(state)
	if !restart {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	state.ScanStartedAt = time.Now()
	for _, genre := range hongguoAppGenres {
		state.Feeds[genre.key] = hongguoCatalogCursor{}
	}
	client.mu.Lock()
	client.state = *cloneHongguoCatalogState(state)
	client.mu.Unlock()
	engine.mu.Lock()
	defer engine.mu.Unlock()
	engine.hongguoCatalog = cloneHongguoCatalogState(state)
	engine.catalogStates[sourceHongguo] = nativeCatalogState{HasMore: true}
	return engine.writeCatalogCheckpointLocked()
}

func (engine *nativeEngine) loadHongguoSourceCatalog(ctx context.Context, operation string) error {
	if err := engine.prepareHongguoCatalogScan(ctx, operation); err != nil {
		return err
	}
	ctx = context.WithValue(ctx, libraryScanKey{}, true)
	engine.mu.Lock()
	initialCount := len(engine.catalogs[sourceHongguo])
	engine.mu.Unlock()
	limit := engine.downloader.cfg.MaxPagesPerSort
	if limit < 1 {
		limit = defaultConfig().MaxPagesPerSort
	}
	limit = min(limit, 200)
	if operation == "more" {
		limit = 1
	}
	for batch := 0; batch < limit; batch++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		engine.mu.Lock()
		state := engine.catalogStates[sourceHongguo]
		more := hongguoCatalogHasMore(engine.hongguoCatalog)
		engine.mu.Unlock()
		if !more {
			return nil
		}
		page := max(1, state.Page+1)
		if page > 1_000_000 {
			return errors.New("站源分页已达到接口范围，已保留目录位置")
		}
		engine.changeSourceRecord(sourceHongguo, func(record *nativeSourceRecord) {
			record.Stage = "扫描红果 App 目录"
		})
		checkpoint := hongguoCatalogCheckpointFunc(func(items []Drama, snapshot *hongguoCatalogState, genre string) error {
			return engine.saveHongguoCatalogPage(items, snapshot, genre, page, initialCount)
		})
		batchContext := context.WithValue(ctx, hongguoCatalogCheckpointKey{}, checkpoint)
		result, err := engine.nativeCatalog(batchContext, nativeInput{Source: sourceHongguo, Page: page, Force: true})
		if result.saveError != nil {
			return result.saveError
		}
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if result.Warning != "" {
			return errors.New(result.Warning)
		}
	}
	return nil
}

func (engine *nativeEngine) saveHongguoCatalogPage(items []Drama, snapshot *hongguoCatalogState, genre string, page, initialCount int) error {
	result := nativeCatalogResult{Items: []nativeDrama{}, Page: page, HasMore: hongguoCatalogHasMore(snapshot), hongguo: snapshot, immediateSave: true}
	for _, drama := range items {
		result.Items = append(result.Items, nativeNormalize(drama))
	}
	if err := engine.saveCatalogCache(sourceHongguo, &result); err != nil {
		return err
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	record := engine.sourceRecords[sourceHongguo]
	record.Stage = "扫描红果 App 目录 · " + genre
	record.Added = max(0, len(engine.catalogs[sourceHongguo])-initialCount)
	engine.sourceRecords[sourceHongguo] = record
	return engine.saveSourceRecordsLocked()
}
