package core

import (
	"strconv"
	"strings"
)

func huangguoMediaQualities(media providerMedia) providerMedia {
	lines := strings.Split(strings.ReplaceAll(media.Playlist, "\r\n", "\n"), "\n")
	selected, quality, master := nativeHLSSelect(lines, 0)
	if !master {
		return media
	}
	media.Playlist = strings.Join(selected, "\n")
	media.Quality = quality
	media.Variants = nil
	seen := map[int]bool{quality: true}
	for _, line := range lines {
		if !strings.HasPrefix(strings.TrimSpace(line), "#EXT-X-STREAM-INF:") {
			continue
		}
		resolution := strings.Split(nativeHLSAttributes(line)["RESOLUTION"], "x")
		if len(resolution) != 2 {
			continue
		}
		height, _ := strconv.Atoi(resolution[1])
		if height <= 0 || seen[height] {
			continue
		}
		seen[height] = true
		selected, actual, _ := nativeHLSSelect(lines, height)
		variant := media
		variant.Playlist = strings.Join(selected, "\n")
		variant.Quality = actual
		variant.Variants = nil
		media.Variants = append(media.Variants, variant)
	}
	return media
}
