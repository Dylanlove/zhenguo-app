package ysp

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

func checksum(raw []byte) uint32 {
	var value uint32
	for _, b := range raw {
		value = (value*131 + uint32(b)) & 0x7fffffff
	}
	return value
}
func teaBlock(raw, key []byte) []byte {
	left, right := binary.BigEndian.Uint32(raw), binary.BigEndian.Uint32(raw[4:])
	keys := [4]uint32{}
	for index := range keys {
		keys[index] = binary.BigEndian.Uint32(key[index*4:])
	}
	var sum uint32
	for count := 0; count < 16; count++ {
		sum += 0x9e3779b9
		left += ((right << 4) + keys[0]) ^ (right + sum) ^ ((right >> 5) + keys[1])
		right += ((left << 4) + keys[2]) ^ (left + sum) ^ ((left >> 5) + keys[3])
	}
	output := make([]byte, 8)
	binary.BigEndian.PutUint32(output, left)
	binary.BigEndian.PutUint32(output[4:], right)
	return output
}
func teaPacket(raw, key []byte) []byte {
	padding := (8 - (len(raw)+10)%8) % 8
	plain := make([]byte, 1+padding+2)
	rand.Read(plain)
	plain[0] = (plain[0] & 248) | byte(padding)
	plain = append(plain, raw...)
	plain = append(plain, make([]byte, 7)...)
	previousPlain, previousCipher := make([]byte, 8), make([]byte, 8)
	output := make([]byte, 0, len(plain))
	for offset := 0; offset < len(plain); offset += 8 {
		mixed := make([]byte, 8)
		for index := 0; index < 8; index++ {
			mixed[index] = plain[offset+index] ^ previousCipher[index]
		}
		encrypted := teaBlock(mixed, key)
		for index := range encrypted {
			encrypted[index] ^= previousPlain[index]
		}
		output = append(output, encrypted...)
		previousPlain, previousCipher = mixed, encrypted
	}
	return output
}
func lp(raw []byte) []byte {
	result := make([]byte, 2, len(raw)+2)
	binary.BigEndian.PutUint16(result, uint16(len(raw)))
	return append(result, raw...)
}
func uint32Bytes(value uint32) []byte {
	raw := make([]byte, 4)
	binary.BigEndian.PutUint32(raw, value)
	return raw
}
func decodeHex(value string) []byte { raw, _ := hex.DecodeString(value); return raw }
func guard(stamp uint32, guid string) string {
	body := uint32Bytes(stamp)
	for _, value := range []string{guid[len(guid)-5:], "", "", "-1"} {
		body = append(body, lp([]byte(value))...)
	}
	plain := lp(body)
	encrypted := append(teaPacket(plain, decodeHex("110DBEC10C23E7D2E56A1CAD6914EF1B")), uint32Bytes(checksum(plain))...)
	mask := []byte{179, 201, 83, 160, 105, 19, 173, 77}
	for index := range encrypted {
		encrypted[index] ^= mask[index&7]
	}
	return strings.ToUpper(hex.EncodeToString(encrypted))
}
func backupKey(cnlid string) (string, string, int64, string) {
	stamp := time.Now().Unix()
	guid := randomHex(16)
	body := decodeHex("0000004200000004000004d2")
	for _, value := range []uint32{4330403, 0, uint32(stamp)} {
		body = append(body, uint32Bytes(value)...)
	}
	for _, value := range []string{"dcgh", "_zj1A5Gh6QYcxWjIUGos2w==", "V8.22.1035.3031", cnlid, guid} {
		body = append(body, lp([]byte(value))...)
	}
	body = append(body, uint32Bytes(1)...)
	body = append(body, uint32Bytes(1)...)
	for _, value := range []string{strings.ToUpper(randomHex(4)), "nil", "57eab0c4-2c58-44c6-8ae9-dd2757525dc5", "nil", "v0.1.000", "com.cctv.yangshipin.app.iphone", "4330403", "ex_json_bus", "ex_json_vs", guard(uint32(stamp), guid)} {
		body = append(body, lp([]byte(value))...)
	}
	plain := lp(body)
	binary.BigEndian.PutUint32(plain[18:22], checksum(plain))
	encrypted := append(teaPacket(plain, decodeHex("59b2f7cf725ef43c34fdd7c123411ed3")), uint32Bytes(checksum(plain))...)
	mask := []byte{132, 46, 237, 8, 240, 102, 230, 234, 72, 180, 202, 169, 145, 237, 111, 243}
	for index := range encrypted {
		encrypted[index] ^= mask[index&15]
	}
	key := base64.StdEncoding.EncodeToString(encrypted)
	key = strings.NewReplacer("+", "_", "/", "-", "=", "").Replace(key)
	return "--01" + key, guid, stamp, strings.ToUpper(randomHex(16)) + "_4330403"
}
func backupPlans(ctx context.Context, client *http.Client, channel Channel) ([]Plan, error) {
	key, guid, stamp, flow := backupKey(channel.CnlID)
	query := url.Values{"atime": {"120"}, "livepid": {channel.PID}, "cnlid": {channel.CnlID}, "appVer": {"V8.22.1035.3031"}, "app_version": {"300090"}, "caplv": {"1"}, "cmd": {"2"}, "defn": {channel.Definition}, "device": {"iPhone"}, "encryptVer": {"4.2"}, "getpreviewinfo": {"0"}, "hevclv": {"0"}, "lang": {"zh-Hans_CN"}, "livequeue": {"0"}, "logintype": {"1"}, "nettype": {"1"}, "newnettype": {"1"}, "newplatform": {"4330403"}, "platform": {"4330403"}, "sdtfrom": {"v3021"}, "spacode": {"23"}, "spaudio": {"1"}, "spdemuxer": {"6"}, "spdrm": {"2"}, "spdynamicrange": {"1"}, "spflv": {"1"}, "spflvaudio": {"1"}, "sphdrfps": {"60"}, "sphttps": {"1"}, "spvcode": {base64.StdEncoding.EncodeToString([]byte("H(30:1080,60:1080|30:1080,60:1080)"))}, "spvideo": {"4"}, "stream": {"1"}, "system": {"1"}, "sysver": {"ios18.2.1"}, "uhd_flag": {"0"}, "cKey": {key}, "guid": {guid}, "fntick": {strconv.FormatInt(stamp, 10)}, "flowid": {flow}, "playbacktime": {"0"}}
	raw, _, _, err := fetch(ctx, client, "GET", "https://bkliveinfo.ysp.cctv.cn/?"+query.Encode(), nil, map[string]string{"User-Agent": "qqlive", "Accept": "application/json"}, 2<<20)
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err = json.Unmarshal(raw, &response); err != nil {
		return nil, err
	}
	if text(response["iretcode"]) != "0" {
		return nil, errors.New("央视频 bkliveinfo 线路暂不可用")
	}
	candidates := []string{}
	if address := text(response["playurl"]); address != "" {
		candidates = append(candidates, address)
	}
	for _, key := range []string{"backurl_list", "backurlList", "backurl"} {
		switch extra := response[key].(type) {
		case []any:
			for _, entry := range extra {
				address := text(entry)
				if address == "" {
					row := object(entry)
					address = text(row["url"])
					if address == "" {
						address = text(row["playurl"])
					}
				}
				candidates = append(candidates, address)
			}
		case string:
			candidates = append(candidates, strings.FieldsFunc(extra, func(r rune) bool { return r == ';' || r == ',' })...)
		}
	}
	seen := map[string]bool{}
	addresses := []string{}
	for _, address := range candidates {
		if address != "" && strings.Contains(address, ".cctv.") && !seen[address] {
			seen[address] = true
			addresses = append(addresses, address)
		}
	}
	sort.SliceStable(addresses, func(left, right int) bool {
		return strings.Contains(addresses[left], "bklive-") && !strings.Contains(addresses[right], "bklive-")
	})
	plans := make([]Plan, 0, len(addresses))
	for _, address := range addresses {
		plans = append(plans, Plan{URL: address, Headers: map[string]string{"User-Agent": browserUA}, Engine: "bkliveinfo", Quality: "1080p", Expires: time.Now().Add(5 * time.Minute).Unix()})
	}
	if len(plans) == 0 {
		return nil, errors.New("央视频备用引擎未返回播放地址")
	}
	return plans, nil
}
