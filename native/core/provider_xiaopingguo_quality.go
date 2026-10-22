package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const mediaResolutionProbeBytes = 256 << 10

func (d *Downloader) mediaResolutionBytes(ctx context.Context, address, referer, span string, limit int64) ([]byte, string, error) {
	if !isProviderHTTPMediaURL(address) {
		return nil, "", errors.New("媒体信息地址无效")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, "", err
	}
	request.Header.Set("Referer", referer)
	request.Header.Set("Range", span)
	response, err := d.doMediaRequest(request)
	if err != nil {
		return nil, "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return nil, "", fmt.Errorf("媒体信息 HTTP %d", response.StatusCode)
	}
	if strings.HasPrefix(span, "bytes=-") && response.StatusCode != http.StatusPartialContent {
		return nil, "", errors.New("媒体服务器不支持尾部读取")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit))
	if response.Request != nil && response.Request.URL != nil {
		address = response.Request.URL.String()
	}
	return body, address, err
}

func (d *Downloader) mediaResolutionKey(ctx context.Context, media providerMedia, raw string) ([]byte, error) {
	if len(media.HLSKey) == 16 {
		return media.HLSKey, nil
	}
	if strings.HasPrefix(raw, "data:") {
		header, content, found := strings.Cut(raw, ",")
		if !found {
			return nil, errors.New("媒体密钥无效")
		}
		if strings.HasSuffix(header, ";base64") {
			return base64.StdEncoding.DecodeString(content)
		}
		plain, err := url.PathUnescape(content)
		return []byte(plain), err
	}
	body, _, err := d.mediaResolutionBytes(ctx, raw, media.Referer, "bytes=0-16", 17)
	return body, err
}

func (d *Downloader) inspectMediaResolution(ctx context.Context, media providerMedia) providerMedia {
	ctx = providerMediaContext(ctx, media.credentials)
	body, base := media.Playlist, media.URL
	if body == "" && providerMediaHLSURL(media.URL) {
		var err error
		body, base, err = d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return media
		}
	}
	if body == "" {
		prefix, finalURL, err := d.mediaResolutionBytes(ctx, media.URL, media.Referer, "bytes=0-262143", mediaResolutionProbeBytes)
		if err != nil {
			return media
		}
		if nativePlaylistPrefix(prefix) {
			body, base, err = d.fetchMediaPlaylist(ctx, finalURL, media.Referer)
			if err != nil {
				return media
			}
		} else {
			media.Width, media.Height = mediaResolution(prefix)
			if media.Width == 0 {
				span := "bytes=-262144"
				if offset := mediaMP4MetadataOffset(prefix); offset > 0 {
					span = fmt.Sprintf("bytes=%d-%d", offset, offset+mediaResolutionProbeBytes-1)
				}
				tail, _, err := d.mediaResolutionBytes(ctx, media.URL, media.Referer, span, mediaResolutionProbeBytes)
				if err == nil {
					media.Width, media.Height = mediaMP4Resolution(tail)
				}
			}
			return media
		}
	}
	for depth := 0; depth < 6; depth++ {
		if !nativePlaylistPrefix([]byte(body)) {
			return media
		}
		lines, _, master := nativeHLSSelect(strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n"), 0)
		if depth == 0 {
			media.URL, media.Playlist = base, strings.Join(lines, "\n")
		}
		parsed, err := url.Parse(base)
		if err != nil {
			return media
		}
		resolve := func(raw string) string {
			reference, err := url.Parse(raw)
			if err != nil {
				return ""
			}
			return parsed.ResolveReference(reference).String()
		}
		segment, initialization := "", ""
		key := map[string]string{}
		sequence := uint64(0)
		for _, raw := range lines {
			line := strings.TrimSpace(raw)
			switch {
			case strings.HasPrefix(line, "#EXT-X-MEDIA-SEQUENCE:"):
				sequence, _ = strconv.ParseUint(strings.TrimPrefix(line, "#EXT-X-MEDIA-SEQUENCE:"), 10, 64)
			case strings.HasPrefix(line, "#EXT-X-KEY:"):
				key = nativeHLSAttributes(line)
			case strings.HasPrefix(line, "#EXT-X-MAP:"):
				initialization = resolve(nativeHLSAttributes(line)["URI"])
			case strings.HasPrefix(line, "#EXT-X-BYTERANGE:"):
				return media
			case line != "" && !strings.HasPrefix(line, "#"):
				segment = resolve(line)
			}
			if segment != "" {
				break
			}
		}
		if master {
			body, base, err = d.fetchMediaPlaylist(ctx, segment, media.Referer)
			if err != nil {
				return media
			}
			continue
		}
		address := firstNonEmpty(initialization, segment)
		data, _, err := d.mediaResolutionBytes(ctx, address, media.Referer, "bytes=0-262143", mediaResolutionProbeBytes)
		if err != nil {
			return media
		}
		if method := key["METHOD"]; method != "" && method != "NONE" {
			if method != "AES-128" || key["KEYFORMAT"] != "" && key["KEYFORMAT"] != "identity" {
				return media
			}
			secret, err := d.mediaResolutionKey(ctx, media, resolve(key["URI"]))
			if err != nil || len(secret) != aes.BlockSize {
				return media
			}
			iv := make([]byte, aes.BlockSize)
			binary.BigEndian.PutUint64(iv[8:], sequence)
			if encoded := key["IV"]; encoded != "" {
				encoded = strings.TrimPrefix(strings.TrimPrefix(encoded, "0x"), "0X")
				if len(encoded) > 32 {
					return media
				}
				iv, err = hex.DecodeString(strings.Repeat("0", 32-len(encoded)) + encoded)
				if err != nil {
					return media
				}
			}
			block, _ := aes.NewCipher(secret)
			data = data[:len(data)/aes.BlockSize*aes.BlockSize]
			cipher.NewCBCDecrypter(block, iv).CryptBlocks(data, data)
		}
		media.Width, media.Height = mediaResolution(data)
		return media
	}
	return media
}

func (d *Downloader) prepareXiaopingguoPlayback(ctx context.Context, media providerMedia) providerMedia {
	routes := append([]providerMedia{media}, media.Variants...)
	media.Variants = nil
	probe, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	slots := make(chan struct{}, 4)
	var group sync.WaitGroup
	for index := range routes {
		routes[index].Variants = nil
		group.Add(1)
		go func(index int) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
				routes[index] = d.inspectMediaResolution(probe, routes[index])
			case <-probe.Done():
			}
			if routes[index].Width > 0 && routes[index].Height > 0 {
				routes[index].Quality = min(routes[index].Width, routes[index].Height)
				routes[index].RouteName += fmt.Sprintf(" · %d×%d", routes[index].Width, routes[index].Height)
			} else {
				routes[index].RouteName += " · 分辨率未知"
			}
		}(index)
	}
	group.Wait()
	media = routes[0]
	media.Variants = routes[1:]
	return media
}
