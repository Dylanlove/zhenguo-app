package core

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var xiaopingguoRRSPDramaPattern = regexp.MustCompile(`/drama/([0-9]+)(?:/|$)`)

func (d *Downloader) xiaopingguoRRSPRequest(ctx context.Context, path string, params url.Values) (map[string]any, error) {
	device, err := xiaopingguoRandom(32, "0123456789abcdef")
	if err != nil {
		return nil, err
	}
	timestamp := strconv.FormatInt(time.Now().UnixMilli(), 10)
	query := params.Encode()
	canonical := "GET\naliId:" + device + "\nct:web_applet\ncv:1.0.0\nt:" + timestamp + "\n" + path + "?" + query
	signer := hmac.New(sha256.New, []byte(xiaopingguoRRSPSignKey))
	signer.Write([]byte(canonical))
	payload, err := d.duanjuDo(ctx, duanjuRequest{Source: sourceXiaopingguo,
		Address: xiaopingguoRRSPBaseURL + path + "?" + query, Agent: xiaopingguoRRSPAgent, Referer: xiaopingguoRRSPReferer,
		Headers: map[string]string{"x-ca-sign": base64.StdEncoding.EncodeToString(signer.Sum(nil)),
			"t": timestamp, "aliId": device, "umid": device, "deviceId": device, "clientVersion": "1.0.0",
			"cv": "1.0.0", "clientType": "web_applet", "ct": "web_applet", "uet": "9", "Origin": strings.TrimRight(xiaopingguoRRSPReferer, "/")}})
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if json.Unmarshal(payload, &response) == nil && response != nil {
		return response, nil
	}
	var encoded string
	if json.Unmarshal(payload, &encoded) != nil {
		encoded = string(payload)
	}
	plain, err := xiaopingguoDecrypt(encoded, xiaopingguoRRSPResponseKey, "")
	if err != nil {
		return nil, errors.New("小苹果 RRSP 响应无法解密")
	}
	if json.Unmarshal(plain, &response) != nil || response == nil {
		return nil, errors.New("小苹果 RRSP 数据无效")
	}
	return response, nil
}

func (d *Downloader) resolveXiaopingguoRRSP(ctx context.Context, token string) (string, error) {
	parsed, err := url.Parse(token)
	if err != nil {
		return "", errors.New("小苹果 RRSP 剧集地址无效")
	}
	match := xiaopingguoRRSPDramaPattern.FindStringSubmatch(parsed.Path)
	if match == nil {
		return "", errors.New("小苹果 RRSP 剧集地址无效")
	}
	id := match[1]
	episode := firstNonEmpty(parsed.Query().Get("episodeNo"), "1")
	number, err := strconv.Atoi(episode)
	if err != nil || number < 1 {
		return "", errors.New("小苹果 RRSP 集数无效")
	}
	response, err := d.xiaopingguoRRSPRequest(ctx, "/m-station/drama/page", url.Values{
		"hsdrOpen": {"0"}, "isAgeLimit": {"0"}, "dramaId": {id}, "pageNum": {"1"}, "pageSize": {"200"},
	})
	if err != nil {
		return "", err
	}
	sid := ""
	for _, item := range duanjuMapList(duanjuFindMap(response, "data")["episodeList"]) {
		if duanjuFindInt(item, "episodeNo") == number {
			sid = duanjuFindString(item, "sid")
			break
		}
	}
	if sid == "" {
		return "", errors.New("小苹果 RRSP 没有对应分集")
	}
	last := ""
	var lastError error
	for attempt := 0; attempt < 8; attempt++ {
		for _, quality := range []string{"HD", "SD"} {
			if err := ctx.Err(); err != nil {
				return "", err
			}
			response, err := d.xiaopingguoRRSPRequest(ctx, "/m-station/drama/play", url.Values{
				"hsdrOpen": {"0"}, "dramaId": {id}, "episodeSid": {sid}, "quality": {quality}, "hevcOpen": {"0"}, "tria4k": {"0"},
			})
			if err != nil {
				lastError = err
				continue
			}
			data := duanjuFindMap(response, "data")
			encoded, sign := duanjuFindString(duanjuFindMap(data, "m3u8"), "url"), duanjuFindString(data, "newSign")
			if encoded == "" || len(sign) < 20 {
				continue
			}
			plain, err := xiaopingguoDecrypt(encoded, sign[4:20], xiaopingguoRRSPPlayIV)
			if err != nil {
				lastError = err
				continue
			}
			candidate := strings.TrimSpace(string(plain))
			if !isProviderHTTPMediaURL(candidate) {
				continue
			}
			last = candidate
			if address, err := url.Parse(candidate); err == nil && address.Query().Get("auth_key") != "" {
				return candidate, nil
			}
		}
	}
	if last != "" {
		return last, nil
	}
	return "", errors.Join(errors.New("小苹果 RRSP 未返回可播放地址"), lastError)
}
