package core

import (
	"context"
	"crypto/aes"
	"encoding/hex"
	"errors"
	"fmt"
	"math/bits"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	model, err := downloader.hongguoPlaybackModel(ctx, videoID)
	if err != nil {
		return providerMedia{}, err
	}
	media, directErr := selectHongguoAppMedia(model)
	if directErr == nil {
		return media, nil
	}
	var fallbackErr error
	if model["fallback_api"] != nil {
		var media providerMedia
		media, fallbackErr = downloader.resolveHongguoFallbackMedia(ctx, model)
		if fallbackErr == nil {
			return media, nil
		}
		if ctx.Err() != nil {
			return providerMedia{}, ctx.Err()
		}
	}
	return providerMedia{}, errors.Join(fallbackErr, directErr)
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := hongguoModelVariants(model)
	seed, seedErr := hongguoModelKeySeed(model, 0)
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		var addresses []string
		if len(seed) > 0 {
			addresses = hongguoSeededMediaAddresses(variant, seed)
		} else {
			addresses = hongguoMediaAddresses(variant)
		}
		if len(addresses) == 0 {
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoPlaybackContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			parsed, _ := url.Parse(address)
			media.credentials = &providerMediaCredentials{origin: providerMediaOrigin(parsed), userAgent: "com.phoenix.read/71332"}
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	if seedErr != nil {
		return providerMedia{}, seedErr
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

func hongguoPlaybackContentKey(value string) ([]byte, error) {
	if len(value) > 1024 {
		return nil, errors.New("红果媒体密钥数据过长")
	}
	raw, err := decodeHongguoBase64(value)
	if err != nil || len(raw) < 3 {
		return nil, errors.New("红果媒体密钥编码无效")
	}
	length := len(raw) - int(raw[0]^raw[1]^raw[2]) + 47
	if length <= 0 || length+1 > len(raw) {
		length = len(raw) - 1
	}
	if length < 33 {
		return nil, errors.New("红果媒体密钥结构无效")
	}
	decoded := make([]byte, length)
	even, odd := byte(246), byte(85)
	for index, current := range raw[1 : 1+length] {
		previous := even
		if index%2 == 0 {
			even = current
		} else {
			previous, odd = odd, current
		}
		decoded[index] = byte(int(previous^current) - 21 - bits.OnesCount(uint(index)))
	}
	key, err := hex.DecodeString(string(decoded[1:33]))
	if err != nil || len(key) != aes.BlockSize {
		return nil, errors.New("红果媒体密钥不是有效的 AES-128 密钥")
	}
	return key, nil
}

var hongguoDefinitionHint = regexp.MustCompile(`2160|1440|1080|720|576|540|480|360`)

func hongguoModelVariants(model map[string]any) []any {
	var variants []any
	var collect func(any, string, int)
	collect = func(value any, hint string, depth int) {
		if depth > 12 {
			return
		}
		switch value := value.(type) {
		case []any:
			for _, row := range value {
				collect(row, hint, depth+1)
			}
		case map[string]any:
			for _, field := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list", "play_addr", "url"} {
				if value[field] == nil {
					continue
				}
				variant := make(map[string]any, len(value)+2)
				for key, item := range value {
					variant[key] = item
				}
				meta := map[string]any{}
				for _, field := range []string{"codec_type", "definition", "vheight", "vwidth"} {
					meta[field] = firstNonEmpty(mapString(nestedMap(value, "video_meta"), field), mapString(value, field))
				}
				if mapString(meta, "definition", "vheight", "vwidth") == "" && hint != "" {
					meta["definition"] = hint
				}
				encryption := map[string]any{}
				for key, item := range nestedMap(value, "encrypt_info") {
					encryption[key] = item
				}
				for _, field := range []string{"spade_a", "encrypt", "encryption_method", "kid"} {
					if item, ok := value[field]; ok {
						encryption[field] = item
					}
				}
				variant["video_meta"], variant["encrypt_info"] = meta, encryption
				variants = append(variants, variant)
				return
			}
			keys := make([]string, 0, len(value))
			for key := range value {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			for _, key := range keys {
				nextHint := hint
				if quality := hongguoDefinitionHint.FindString(key); quality != "" {
					nextHint = quality
				}
				collect(value[key], nextHint, depth+1)
			}
		}
	}
	collect(hongguoModelVideoList(model, 0), "", 0)
	return variants
}

func hongguoModelVideoList(model map[string]any, depth int) any {
	if len(model) == 0 || depth > 12 {
		return nil
	}
	for _, field := range []string{"video_list", "dynamic_video_list", "list"} {
		switch value := model[field].(type) {
		case map[string]any:
			if len(value) > 0 {
				return value
			}
		case []any:
			if len(value) > 0 {
				return value
			}
		}
	}
	for _, field := range []string{"dynamic_video", "video_info", "data"} {
		if value := hongguoModelVideoList(nestedMap(model, field), depth+1); value != nil {
			return value
		}
	}
	return nil
}

func hongguoModelKeySeed(model map[string]any, depth int) ([]byte, error) {
	if depth > 12 {
		return nil, errors.New("红果播放模型嵌套过深")
	}
	if value := mapString(model, "key_seed"); value != "" {
		seed, err := decodeHongguoBase64(value)
		if err != nil || len(seed) == 0 || len(seed) > 4096 {
			return nil, errors.New("红果播放地址的解密种子无效")
		}
		return seed, nil
	}
	for _, field := range []string{"dynamic_video", "video_info", "data"} {
		if nested := nestedMap(model, field); len(nested) > 0 {
			seed, err := hongguoModelKeySeed(nested, depth+1)
			if err != nil || len(seed) > 0 {
				return seed, err
			}
		}
	}
	return nil, nil
}

func hongguoMediaAddresses(info map[string]any) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any, int)
	add = func(value any, depth int) {
		if depth > 12 {
			return
		}
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				decoded, err := decodeHongguoBase64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item, depth+1)
			}
		case map[string]any:
			for _, field := range []string{"url", "uri", "src", "download_url", "main_url", "backup_url", "url_list"} {
				add(value[field], depth+1)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list", "play_addr", "url"} {
		add(info[key], 0)
	}
	return addresses
}

func hongguoSeededMediaAddresses(info map[string]any, seed []byte) []string {
	decoded := map[string]any{}
	var decode func(any, int) any
	decode = func(raw any, depth int) any {
		if depth > 12 {
			return nil
		}
		switch value := raw.(type) {
		case string:
			if isProviderHTTPMediaURL(value) {
				return value
			}
			if address, err := decryptHongguoSpadeURL(value, seed); err == nil {
				return address
			}
			return value
		case []any:
			out := make([]any, 0, len(value))
			for _, item := range value {
				out = append(out, decode(item, depth+1))
			}
			return out
		case map[string]any:
			out := map[string]any{}
			for key, item := range value {
				out[key] = decode(item, depth+1)
			}
			return out
		}
		return nil
	}
	for _, field := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list", "play_addr", "url"} {
		decoded[field] = decode(info[field], 0)
	}
	return hongguoMediaAddresses(decoded)
}
