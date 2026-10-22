package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

type nativeSourceCapabilities struct {
	ID              string `json:"id"`
	OnlineSearch    bool   `json:"onlineSearch"`
	SearchPaging    bool   `json:"searchPaging"`
	CatalogPaging   bool   `json:"catalogPaging"`
	Suggestions     bool   `json:"suggestions"`
	Categories      bool   `json:"categories"`
	Rankings        bool   `json:"rankings"`
	Recommendations bool   `json:"recommendations"`
	Film            bool   `json:"film"`
	Fingerprint     string `json:"fingerprint"`
}

func nativeCapabilities(version string) []nativeSourceCapabilities {
	sources := []string{sourceHongguo, sourceHuangdou, sourceHuangju, sourceYeguo, sourceDSD, sourceHuangguoVideo, sourceHuangguoAI, sourceCloudFront, sourceIkanbot, sourceA123}
	for _, spec := range duanjuProviderCatalog {
		sources = append(sources, spec.ID)
	}
	sources = append(sources, sourceXiaopingguo, sourceMiguoHoney)
	items := []nativeSourceCapabilities{}
	for _, source := range sources {
		if !nativeSourceAvailable(source) {
			continue
		}
		film := isFilmProviderSource(source)
		item := nativeSourceCapabilities{ID: source, Categories: source != sourceHuangdou, CatalogPaging: true, Film: film}
		switch source {
		case sourceHongguo, sourceHuangguoAI, sourceHuangju, sourceYeguo, sourceDSD, sourceIkanbot, sourceA123, sourceXiaopingguo, sourceMiguoHoney:
			item.OnlineSearch, item.SearchPaging = true, true
		}
		if spec, found := duanjuSourceSpecFor(source); found {
			item.OnlineSearch = spec.Searcher
			item.SearchPaging = source == sourceChaoguo && spec.Searcher
			item.CatalogPaging = spec.Paged
		}
		item.Suggestions = source == sourceHongguo
		item.Recommendations = source == sourceHongguo
		for _, board := range rankingBoards {
			if board.Source == source {
				item.Rankings = true
				break
			}
		}
		body, _ := json.Marshal(item)
		digest := sha256.Sum256(append([]byte(version+":"), body...))
		item.Fingerprint = hex.EncodeToString(digest[:8])
		items = append(items, item)
	}
	return items
}
