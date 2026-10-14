package core

import "testing"

func TestRemovedDuanjuSourcesCannotBeDispatched(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "true"
	t.Cleanup(func() { buildAllSources = previous })
	for _, source := range []string{"fanguo", "guanguo", "niuguo", "xifan", "weiguan", "niuniu"} {
		if isDuanjuProviderSource(source) || nativeSourceAvailable(source) || duanjuSupportsSearch(source) || duanjuSupportsPaging(source) {
			t.Fatalf("removed source remains callable: %s", source)
		}
		if _, _, valid := splitProviderDramaID(source + ":1"); valid {
			t.Fatalf("removed source accepts stored drama IDs: %s", source)
		}
	}
	for _, board := range rankingBoards {
		if board.Source == "fanguo" || board.Source == "guanguo" || board.Source == "niuguo" {
			t.Fatalf("removed source still has a ranking: %s", board.ID)
		}
	}
}
