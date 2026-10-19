package ysp

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

const appKey = "9f5c54c4ed0e50109b800f7e28fec205"
const devicePublicKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkKeLy4ywWLSnBkwRyqYgF3HMIj05V5uuh5HjyEsZOWnu1NHu3jPQv3sr32wwQNYv5qapsNXmNgLUDHtgHZxqPQAYXltjSRc0qhcD286t62wOIHId8zXS3s1Jy4rgU4qjQWzI9rp/1sE0pMsmwTaJa4zuJ5iz8VwF8Av5oJ1k+HxY+/HLnjNlW1hmWLpuDYmkZYuAoTHa1VGeHQh9FEKI8ZcL3GTQphShUoC+Kg3P1hGUVTtCYapmzPS5lkAdwebuzwvTCfGiTErYZCnPBUSeV7BVlgjtLYIi29KvF0a8FHsJMfe/UdHcyW/RihsIYOtDQcRRpFGXyPXbVrzFJse24QIDAQAB"
const reportKey = "1178c84d-4818-44ff-b415-02106e87e144"

type deviceState struct {
	Profile      map[string]string `json:"profile"`
	Screen       string            `json:"screen"`
	Cast         string            `json:"cast"`
	GUID         string            `json:"guid"`
	LastRotation int64             `json:"lastRotation"`
	RotationDay  string            `json:"rotationDay"`
	Rotations    int               `json:"rotations"`
}

type deviceSession struct {
	headers    map[string]string
	key        string
	guid       string
	created    time.Time
	heartbeat  time.Time
	heartbeats int
}

type deviceClient struct {
	mu          sync.Mutex
	state       deviceState
	session     *deviceSession
	path        string
	client      *http.Client
	lastRequest time.Time
	links       map[string]time.Time
	plans       map[string]Plan
}

func newDeviceClient(root string) *deviceClient {
	result := &deviceClient{path: filepath.Join(root, "device.json"), client: directClient(), links: map[string]time.Time{}, plans: map[string]Plan{}}
	if raw, err := os.ReadFile(result.path); err == nil && len(raw) < 128<<10 {
		json.Unmarshal(raw, &result.state)
	}
	if result.state.Profile["android_id"] == "" {
		result.state = result.makeDevice(0, "", 0)
		result.save()
	}
	if raw, err := os.ReadFile(filepath.Join(root, "plans.json")); err == nil && len(raw) < 1<<20 {
		var plans map[string]Plan
		if json.Unmarshal(raw, &plans) == nil {
			for id, plan := range plans {
				if plan.Expires > time.Now().Unix()+60 && plan.Headers["UID"] == result.state.Profile["android_id"] {
					result.plans[id] = plan
				}
			}
		}
	}
	return result
}

func (d *deviceClient) makeDevice(last int64, day string, count int) deviceState {
	raw, _ := bundled.ReadFile("assets/profiles.json")
	var pool []map[string]string
	json.Unmarshal(raw, &pool)
	candidates := []map[string]string{}
	for _, profile := range pool {
		if strings.Contains(profile["source"], "8k") {
			candidates = append(candidates, profile)
		}
	}
	if len(candidates) == 0 {
		candidates = pool
	}
	if len(candidates) == 0 {
		return deviceState{}
	}
	choice := make([]byte, 2)
	rand.Read(choice)
	index := int(choice[0])<<8 | int(choice[1])
	template := candidates[index%len(candidates)]
	clean := func(value string) string {
		return strings.Trim(strings.Map(func(r rune) rune {
			if r >= 'A' && r <= 'Z' {
				return r + 32
			}
			if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
				return r
			}
			return '_'
		}, value), "_")
	}
	device := clean(template["brand"]) + "_" + clean(template["model"])
	androidID := randomHex(8)
	macRaw := make([]byte, 6)
	rand.Read(macRaw)
	macRaw[0] = (macRaw[0] & 0xfc) | 2
	mac := fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", macRaw[0], macRaw[1], macRaw[2], macRaw[3], macRaw[4], macRaw[5])
	resolution := strings.Split(template["screen_param"], "-")
	screen := "3840*2160"
	if len(resolution) >= 2 {
		screen = resolution[0] + "*" + resolution[1]
	}
	profile := map[string]string{"android_id": androidID, "mac": mac, "hardware": template["hardware"], "board": template["board"], "brand": template["brand"], "device": device, "manufacturer": template["manufacturer"], "model": template["model"], "product": device, "tags": "release-keys", "build_type": "user", "user": "build", "resolution": screen, "display": template["model"] + "-user 13 " + template["version_id"] + " 2024 release-keys", "version_id": template["version_id"], "host": clean(template["brand"]) + "-tv-build", "fingerprint": template["manufacturer"] + "/" + device + "/" + device + ":13/" + template["version_id"] + "/2024:user/release-keys", "report_model": template["report_model"]}
	return deviceState{Profile: profile, Screen: template["screen_param"], Cast: template["cast_model"], LastRotation: last, RotationDay: day, Rotations: count}
}

func (d *deviceClient) save() {
	savePrivateJSON(d.path, d.state)
}

func javaHash(value string) int32 {
	var hash int32
	for _, character := range utf16.Encode([]rune(value)) {
		hash = hash*31 + int32(character)
	}
	return hash
}
func deviceUID(profile map[string]string) string {
	value := "1698"
	for _, field := range []string{"hardware", "board", "brand", "device", "manufacturer", "model", "product", "tags", "build_type", "user", "resolution", "mac"} {
		value += profile[field]
	}
	hashes := fmt.Sprintf("%016x%016x", uint64(int64(javaHash(value))), uint64(int64(javaHash(profile["model"]))))
	hash := sha1.Sum([]byte(profile["android_id"] + "|" + hashes))
	return strings.ToUpper(hex.EncodeToString(hash[:]))
}
func fingerprint(uid string, now int64) string {
	day := (now/1000+28800)/86400*86400000 - 28800000
	return sha256Text(sha256Text(appKey + uid + strconv.FormatInt(now, 10) + strconv.FormatInt(day, 10)))
}
func nonce() string {
	value := randomHex(16)
	return value[:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:]
}

func deviceHeaders(profile map[string]string, stamp int64) map[string]string {
	uid := deviceUID(profile)
	return map[string]string{"Accept": "application/json", "Accept-Language": "zh-CN,zh;q=0.8", "Referer": "api.cctv.cn", "User-Agent": "cctv_app_tv", "UID": profile["android_id"], "appChannel": "dangbei", "X-Uid": uid, "X-Fingerprint": fingerprint(uid, stamp), "X-Version": "1.4.1", "X-Timestamp": strconv.FormatInt(stamp, 10), "X-Nonce": nonce(), "Cache-Control": "no-cache"}
}
func freshDeviceHeaders(headers map[string]string) map[string]string {
	result := cloneHeaders(headers)
	result["X-Timestamp"] = strconv.FormatInt(time.Now().UnixMilli(), 10)
	result["X-Nonce"] = nonce()
	return result
}

func reportValue(profile map[string]string) map[string]string {
	uid := deviceUID(profile)
	value := map[string]string{"cctv_id": uid, "device_id": profile["android_id"], "idfa": "", "idfv": "", "user_id": "", "app_key": reportKey, "imei": "", "android_id": profile["android_id"], "mac": profile["mac"], "system_type": "Android", "device_type": "TV", "app_language": "CHINESE", "app_version": "1.4.1", "sdk_version": "", "os_version": "13", "app_channel": "dangbei", "data_time": strconv.FormatInt(time.Now().UnixMilli(), 10)}
	for _, field := range []string{"hardware", "board", "brand", "display", "version_id", "host", "product", "tags", "user", "fingerprint", "manufacturer", "resolution"} {
		value["device_"+field] = profile[field]
	}
	value["device_builder_type"] = profile["build_type"]
	value["device_params"] = profile["device"]
	value["device_model"] = profile["report_model"]
	if value["device_model"] == "" {
		value["device_model"] = profile["model"]
	}
	for key, entry := range value {
		limit := 64
		if key == "device_host" || key == "device_fingerprint" {
			limit = 128
		}
		characters := []rune(entry)
		if len(characters) > limit {
			value[key] = string(characters[:limit])
		}
	}
	return value
}

func gcmKey(value string) []byte { key := make([]byte, 32); copy(key, []byte(value)); return key }
func decryptGCM(value, key string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(raw) < 28 {
		return "", errors.New("央视频加密响应无效")
	}
	block, err := aes.NewCipher(gcmKey(key))
	if err != nil {
		return "", err
	}
	mode, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	plain, err := mode.Open(nil, raw[:12], raw[12:], nil)
	if err != nil {
		return "", errors.New("央视频会话响应解密失败")
	}
	return string(plain), nil
}
func encryptGCM(value, key string) (string, error) {
	block, err := aes.NewCipher(gcmKey(key))
	if err != nil {
		return "", err
	}
	mode, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	iv := make([]byte, 12)
	if _, err = rand.Read(iv); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(mode.Seal(iv, iv, []byte(value), nil)), nil
}
func encryptedDevice(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(devicePublicKey)
	if err != nil {
		return "", err
	}
	decoded, err := x509.ParsePKIXPublicKey(raw)
	if err != nil {
		return "", err
	}
	key, ok := decoded.(*rsa.PublicKey)
	if !ok {
		return "", errors.New("央视频设备公钥无效")
	}
	encrypted, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, key, []byte(value), nil)
	return base64.StdEncoding.EncodeToString(encrypted), err
}

func (d *deviceClient) slot(ctx context.Context) error {
	delay := 350*time.Millisecond - time.Since(d.lastRequest)
	if delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	d.lastRequest = time.Now()
	return nil
}
func (d *deviceClient) post(ctx context.Context, address string, body any, headers map[string]string) (map[string]any, error) {
	if err := d.slot(ctx); err != nil {
		return nil, err
	}
	return jsonRequest(ctx, d.client, address, body, headers)
}
func cloudResult(value map[string]any) string {
	for _, key := range []string{"result", "code", "errCode", "errcode", "ret"} {
		if found, ok := value[key]; ok {
			result := text(found)
			if _, err := strconv.ParseInt(result, 10, 64); err == nil {
				return result
			}
		}
	}
	for _, key := range []string{"data", "error", "response"} {
		if nested := object(value[key]); nested != nil {
			if result := cloudResult(nested); result != "" {
				return result
			}
		}
	}
	return ""
}
func cloudGUID(value map[string]any) string {
	for _, container := range []map[string]any{value, object(value["data"])} {
		for _, key := range []string{"guid", "GUID", "device_guid"} {
			if found := text(container[key]); found != "" {
				return found
			}
		}
	}
	return ""
}

func (d *deviceClient) bootstrap(ctx context.Context) error {
	if d.session != nil && time.Since(d.session.created) < 55*time.Minute {
		return nil
	}
	d.client.Jar, _ = cookiejar.New(nil)
	now := time.Now().UnixMilli()
	headers := deviceHeaders(d.state.Profile, now)
	headers["UID"] = ""
	value, err := d.post(ctx, "https://ytpaddr.cctv.cn/gsnw/api/app/start/v1/01", map[string]any{"key": "app_start_d1", "value": reportValue(d.state.Profile)}, headers)
	if err != nil {
		return err
	}
	encrypted := text(value["data"])
	if encrypted == "" {
		encrypted = text(object(value["data"])["key"])
	}
	key, err := decryptGCM(encrypted, headers["X-Fingerprint"][:32])
	if err != nil {
		return err
	}
	headers["UID"] = d.state.Profile["android_id"]
	cipherID, err := encryptedDevice(deviceUID(d.state.Profile))
	if err != nil {
		return err
	}
	body := map[string]string{"device_name": "央视频电视投屏助手", "device_id": cipherID}
	value, err = d.post(ctx, "https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/get", body, freshDeviceHeaders(headers))
	if err != nil {
		return err
	}
	guid := cloudGUID(value)
	result := cloudResult(value)
	if guid == "" && (result == "601" || result == "2") {
		for count := 0; count < 2; count++ {
			value, err = d.post(ctx, "https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/register", body, freshDeviceHeaders(headers))
			if err != nil {
				return err
			}
			guid = cloudGUID(value)
			if guid != "" || cloudResult(value) != "695" {
				break
			}
		}
	}
	if guid == "" && (cloudResult(value) == "0" || cloudResult(value) == "694" || cloudResult(value) == "2") {
		value, err = d.post(ctx, "https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/get", body, freshDeviceHeaders(headers))
		if err != nil {
			return err
		}
		guid = cloudGUID(value)
	}
	if guid == "" && d.state.GUID != "" {
		guid = d.state.GUID
	}
	if guid == "" {
		return errors.New("央视频设备注册暂不可用，保留高清线路")
	}
	d.state.GUID = guid
	d.save()
	d.session = &deviceSession{headers: headers, key: key, guid: guid, created: time.Now()}
	if err = d.heartbeatOnce(ctx); err != nil {
		d.session = nil
		return err
	}
	return nil
}

func (d *deviceClient) heartbeat() {
	if !d.mu.TryLock() {
		return
	}
	defer d.mu.Unlock()
	if d.session == nil || time.Since(d.session.heartbeat) < 30*time.Second {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	d.heartbeatOnce(ctx)
}

func (d *deviceClient) heartbeatOnce(ctx context.Context) error {
	value := reportValue(d.state.Profile)
	value["network_type"] = "WiFi"
	value["guid"] = d.session.guid
	value["other"] = ""
	_, err := d.post(ctx, "https://ytpdata.cctv.cn/das/app/data/message/single", map[string]any{"key": "app_heartbeat", "value": value}, freshDeviceHeaders(d.session.headers))
	if err == nil {
		d.session.heartbeats++
		d.session.heartbeat = time.Now()
	}
	return err
}

func (d *deviceClient) rotate(err error) bool {
	var upstream *upstreamError
	if !errors.As(err, &upstream) || upstream.Status != 400 {
		return false
	}
	now := time.Now()
	day := now.In(time.FixedZone("CST", 8*3600)).Format("2006-01-02")
	count := d.state.Rotations
	if d.state.RotationDay != day {
		count = 0
	}
	if now.Unix()-d.state.LastRotation < 300 || count >= 5 {
		return false
	}
	d.state = d.makeDevice(now.Unix(), day, count+1)
	d.session = nil
	d.plans = map[string]Plan{}
	d.links = map[string]time.Time{}
	d.save()
	d.savePlans()
	return true
}
func (d *deviceClient) touch(id string) {
	if !d.mu.TryLock() {
		return
	}
	if _, ok := d.links[id]; ok {
		d.links[id] = time.Now()
	}
	d.mu.Unlock()
}

func (d *deviceClient) cached(id string) Plan {
	if !d.mu.TryLock() {
		return Plan{}
	}
	defer d.mu.Unlock()
	for key, last := range d.links {
		if time.Since(last) > 15*time.Second {
			delete(d.links, key)
		}
	}
	if _, present := d.links[id]; !present && len(d.links) >= 6 {
		return Plan{}
	}
	if plan := d.plans[id]; plan.URL != "" && plan.Expires > time.Now().Unix()+60 {
		d.links[id] = time.Now()
		return plan
	}
	return Plan{}
}

func (d *deviceClient) invalidate(id string) {
	d.mu.Lock()
	delete(d.plans, id)
	d.savePlans()
	d.mu.Unlock()
}

func (d *deviceClient) savePlans() {
	savePrivateJSON(filepath.Join(filepath.Dir(d.path), "plans.json"), d.plans)
}

func (d *deviceClient) lock(ctx context.Context) error {
	if d.mu.TryLock() {
		return nil
	}
	timer := time.NewTicker(10 * time.Millisecond)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			if d.mu.TryLock() {
				return nil
			}
		}
	}
}

func (d *deviceClient) resolve(ctx context.Context, channel Channel) (Plan, error) {
	if err := d.lock(ctx); err != nil {
		return Plan{}, err
	}
	defer d.mu.Unlock()
	for id, last := range d.links {
		if time.Since(last) > 15*time.Second {
			delete(d.links, id)
		}
	}
	if _, ok := d.links[channel.ID]; !ok && len(d.links) >= 6 {
		return Plan{}, errors.New("央视频设备并发已达 6 路，使用高清线路")
	}
	if plan, ok := d.plans[channel.ID]; ok && int64(plan.Expires) > time.Now().Unix()+60 {
		d.links[channel.ID] = time.Now()
		return plan, nil
	}
	plan, err := d.resolveOnce(ctx, channel)
	if err != nil && d.rotate(err) {
		plan, err = d.resolveOnce(ctx, channel)
	}
	if err == nil {
		d.plans[channel.ID] = plan
		d.links[channel.ID] = time.Now()
		d.savePlans()
	}
	return plan, err
}

func (d *deviceClient) resolveOnce(ctx context.Context, channel Channel) (Plan, error) {
	if channel.LiveID == "" {
		return Plan{}, errors.New("该频道不提供设备协议")
	}
	if err := d.bootstrap(ctx); err != nil {
		return Plan{}, err
	}
	session := d.session
	body := map[string]any{"screenParam": d.state.Screen, "rate": "", "systemType": "ios", "model": d.state.Cast, "id": channel.LiveID, "userId": "BAEBFF2B-C516-4F34-ABC0-A824A6461CBD", "clientSign": "cctvVideo", "deviceId": map[string]string{"serial": "", "imei": "", "android_id": ""}}
	value, err := d.post(ctx, "https://ytpaddr.cctv.cn/gsnw/api/live/v1/01", body, freshDeviceHeaders(session.headers))
	if err != nil {
		return Plan{}, err
	}
	data := object(value["data"])
	videos, _ := data["videoList"].([]any)
	if len(videos) == 0 {
		videos, _ = data["videos"].([]any)
	}
	var selected map[string]any
	for _, entry := range videos {
		video := object(entry)
		if text(video["url"]) == "" {
			continue
		}
		if selected == nil {
			selected = video
		}
		if text(video["rate"]) == "36p" {
			selected = video
			break
		}
	}
	if selected == nil {
		return Plan{}, errors.New("央视频设备协议未返回频道地址")
	}
	address := text(selected["url"])
	if !strings.HasPrefix(address, "http") {
		address, err = decryptGCM(address, session.key)
		if err != nil {
			return Plan{}, err
		}
	}
	guid, err := encryptGCM("", session.key)
	if err != nil {
		return Plan{}, err
	}
	value, err = d.post(ctx, "https://ytpaddr.cctv.cn/gsnw/api/live/v1/02", map[string]string{"guid": guid}, freshDeviceHeaders(session.headers))
	if err != nil {
		return Plan{}, err
	}
	encrypted := text(value["data"])
	data = object(value["data"])
	if encrypted == "" {
		encrypted = text(data["appSecret"])
	}
	if encrypted == "" {
		encrypted = text(data["app_secret"])
	}
	secret, err := decryptGCM(encrypted, session.key)
	if err != nil {
		return Plan{}, err
	}
	random := randomHex(4) + "-0000-" + randomHex(2) + "-0000-00000000" + randomHex(2)
	sign := md5.Sum([]byte(appKey + secret + random))
	headers := freshDeviceHeaders(session.headers)
	headers["APPID"] = appKey
	headers["APPSIGN"] = hex.EncodeToString(sign[:])
	headers["APPRANDOMSTR"] = random
	headers["Content-Type"] = "application/x-www-form-urlencoded"
	common, _ := json.Marshal(map[string]string{"adid": "", "av": "1.4.1", "an": "央视频电视投屏助手", "ap": "cctv_app_tv"})
	form := url.Values{"appcommon": {string(common)}, "url": {address}}.Encode()
	if err = d.slot(ctx); err != nil {
		return Plan{}, err
	}
	raw, _, _, err := fetch(ctx, d.client, "POST", "https://ytpvdn.cctv.cn/cctvmobileinf/rest/cctv/videoliveUrl/getstream", []byte(form), headers, 2<<20)
	if err != nil {
		return Plan{}, err
	}
	if err = json.Unmarshal(raw, &value); err != nil {
		return Plan{}, err
	}
	final := text(value["url"])
	if text(value["succeed"]) != "1" || final == "" {
		return Plan{}, errors.New("央视频签名线路暂不可用")
	}
	playback := map[string]string{"UID": d.state.Profile["android_id"], "APPID": appKey, "Referer": "api.cctv.cn", "User-Agent": "cctv_app_tv", "APPSIGN": headers["APPSIGN"], "APPRANDOMSTR": random}
	quality := text(selected["rateName"])
	if channel.Ultra {
		quality = "4K 超高清"
	} else if quality == "" || strings.Contains(quality, "4K") || strings.Contains(quality, "8K") {
		quality = "高码率高清"
	}
	return Plan{URL: final, Headers: playback, Engine: "device", Quality: quality, Expires: time.Now().Add(30 * time.Minute).Unix()}, nil
}
