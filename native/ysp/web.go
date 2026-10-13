package ysp

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

func md5Text(value string) string { raw := md5.Sum([]byte(value)); return hex.EncodeToString(raw[:]) }
func sortedForm(body map[string]any, fold bool) string {
	keys := make([]string, 0, len(body))
	for key := range body {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool {
		a, b := keys[left], keys[right]
		if fold {
			a, b = strings.ToLower(a), strings.ToLower(b)
		}
		if a == b {
			return keys[left] < keys[right]
		}
		return a < b
	})
	values := make([]string, 0, len(keys))
	for _, key := range keys {
		values = append(values, key+"="+fmt.Sprint(body[key]))
	}
	return strings.Join(values, "&")
}
func webCKey(cnlid, guid string, stamp int64) string {
	source := strings.Join([]string{"", cnlid, strconv.FormatInt(stamp, 10), "mg3c3b04ba", "V1.0.0", guid, "5910204", "https://www.yangshipin.c", "mozilla/5.0 (macintosh; ", "", "Mozilla", "Netscape", "MacIntel", ""}, "|")
	plain := []byte("|" + strconv.FormatInt(int64(javaHash(source)), 10) + source)
	padding := 16 - len(plain)%16
	for count := 0; count < padding; count++ {
		plain = append(plain, byte(padding))
	}
	key, _ := hex.DecodeString("48e5918a74ae21c972b90cce8af6c8be")
	iv, _ := hex.DecodeString("9a7e7d23610266b1d9fbf98581384d92")
	block, _ := aes.NewCipher(key)
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(plain, plain)
	return "--01" + strings.ToUpper(hex.EncodeToString(plain))
}
func webPlan(ctx context.Context, client *http.Client, channel Channel) (Plan, error) {
	now := time.Now()
	stamp := strconv.FormatInt(now.UnixMilli(), 10)
	guid := strconv.FormatInt(now.UnixMilli(), 36) + "_" + randomHex(7)[:13]
	cookie := "guid=" + guid + "; versionName=99.99.99; versionCode=999999; vplatform=109; platformVersion=Chrome; deviceModel=148; newLogin=1; pc_version=1.1.16"
	headers := map[string]string{"Origin": "https://www.yangshipin.cn", "Referer": "https://www.yangshipin.cn/", "User-Agent": browserUA, "Cookie": cookie, "yspappid": "519748109", "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"}
	auth := map[string]any{"pid": channel.PID, "guid": guid, "appid": "ysp_pc", "rand_str": randomHex(5)}
	auth["signature"] = md5Text(sortedForm(auth, false) + "n@7QKk%YeSjfw%22")
	form := url.Values{}
	for key, value := range auth {
		form.Set(key, fmt.Sprint(value))
	}
	raw, _, _, err := fetch(ctx, client, "POST", "https://player-api.yangshipin.cn/v1/player/auth", []byte(form.Encode()), headers, 2<<20)
	if err != nil {
		return Plan{}, err
	}
	var response map[string]any
	if err = json.Unmarshal(raw, &response); err != nil {
		return Plan{}, err
	}
	authData := object(response["data"])
	if text(authData["token"]) == "" {
		return Plan{}, errors.New("央视频网页认证暂不可用")
	}
	rnd, err := keygen(ctx, signingState(guid, "", "", stamp), "get_token_rnd")
	if err != nil {
		return Plan{}, err
	}
	query := url.Values{"yspappid": {"519748109"}, "guid": {guid}, "vappid": {"59306155"}, "vsecret": {"b42702bf7309a179d102f3d51b1add2fda0bc7ada64cb801"}, "raw": {"1"}, "version": {"v1"}, "ts": {stamp}, "rnd": {rnd}}
	raw, _, _, err = fetch(ctx, client, "GET", "https://h5access.yangshipin.cn/web/open/token?"+query.Encode(), nil, headers, 2<<20)
	if err != nil {
		return Plan{}, err
	}
	if err = json.Unmarshal(raw, &response); err != nil {
		return Plan{}, err
	}
	tokenData := object(response["data"])
	token := text(tokenData["token"])
	if token == "" {
		return Plan{}, errors.New("央视频网页签名令牌暂不可用")
	}
	body := map[string]any{"adjust": 1, "appVer": "V1.0.0", "app_version": "V1.0.0", "cKey": webCKey(channel.CnlID, guid, now.Unix()), "channel": "ysp_tx", "cmd": "2", "cnlid": channel.CnlID, "defn": channel.Definition, "devid": "devid", "dtype": "1", "encryptVer": "8.1", "guid": guid, "livepid": channel.PID, "otype": "ojson", "platform": "5910204", "sphttps": "1", "stream": "2"}
	bodyMD5 := md5Text(sortedForm(body, true))
	requestID := "999999" + randomHex(5) + stamp
	input := bodyMD5 + "-" + guid + "-1-" + requestID
	tokenStamp := text(tokenData["ts"])
	if tokenStamp == "" {
		tokenStamp = stamp
	}
	sign, err := keygen(ctx, signingState(guid, token, input, tokenStamp), "get_signature")
	if err != nil {
		return Plan{}, err
	}
	ticket, err := ticket(ctx, channel.PID, text(authData["ts"]), channel.CnlID, guid)
	if err != nil {
		return Plan{}, err
	}
	body["rand_str"] = randomHex(5)
	body["signature"] = md5Text(sortedForm(body, false) + "0f$IVHi9Qno?G")
	headers["yspsdkinput"] = bodyMD5
	headers["yspsdksign"] = sign + "-" + input
	headers["seqId"] = "1"
	headers["request-id"] = requestID
	headers["yspPlayerToken"] = text(authData["token"])
	headers["yspticket"] = ticket
	response, err = jsonRequest(ctx, client, "https://player-api.yangshipin.cn/v1/player/get_live_info", body, headers)
	if err != nil {
		return Plan{}, err
	}
	data := object(response["data"])
	address := text(data["playurl"])
	if address == "" {
		return Plan{}, errors.New("央视频网页引擎未返回播放地址")
	}
	address += text(data["extended_param"])
	return Plan{URL: address, Headers: map[string]string{"User-Agent": browserUA, "Referer": "https://www.yangshipin.cn/"}, Engine: "web", Quality: "1080p", Expires: now.Add(30 * time.Second).Unix()}, nil
}
