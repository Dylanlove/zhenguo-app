package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const hongguoDeviceRegisterURL = "https://log5-applog-lq.fqnovel.com/service/2/device_register/"

const hongguoDeviceRefreshCooldown = time.Minute

const hongguoRegisterUserAgent = "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

func hongguoRegisterStub(body []byte) string {
	sum := md5.Sum(body)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

type hongguoPlaybackDevice struct {
	DeviceID  string
	InstallID string
	CDID      string
}

type hongguoDeviceCall struct {
	done   chan struct{}
	device hongguoPlaybackDevice
	err    error
}

func (d *Downloader) hongguoPlaybackSession(ctx context.Context, rejectedID string) (hongguoPlaybackDevice, error) {
	if err := ctx.Err(); err != nil {
		return hongguoPlaybackDevice{}, err
	}
	client := d.hongguoClient()
	client.mu.Lock()
	device := client.playbackDevice
	if pending := client.devicePending; pending != nil {
		client.mu.Unlock()
		select {
		case <-ctx.Done():
			return hongguoPlaybackDevice{}, ctx.Err()
		case <-pending.done:
			if (errors.Is(pending.err, context.Canceled) || errors.Is(pending.err, context.DeadlineExceeded)) && ctx.Err() == nil {
				return d.hongguoPlaybackSession(ctx, rejectedID)
			}
			return pending.device, pending.err
		}
	}
	if device.DeviceID != "" && (rejectedID == "" || device.DeviceID != rejectedID) {
		client.mu.Unlock()
		return device, nil
	}
	if rejectedID == "" {
		deviceID, installID, err := newHongguoPlaybackDeviceIDs()
		device = hongguoPlaybackDevice{DeviceID: deviceID, InstallID: installID}
		if err == nil {
			client.playbackDevice = device
		}
		client.mu.Unlock()
		return device, err
	}
	if time.Now().Before(client.deviceRefreshAt) {
		client.mu.Unlock()
		deviceID, installID, err := newHongguoPlaybackDeviceIDs()
		return hongguoPlaybackDevice{DeviceID: deviceID, InstallID: installID}, err
	}
	client.deviceRefreshAt = time.Now().Add(hongguoDeviceRefreshCooldown)
	pending := &hongguoDeviceCall{done: make(chan struct{})}
	client.devicePending = pending
	client.mu.Unlock()

	device, err := d.registerHongguoPlaybackDevice(ctx)
	if err != nil && ctx.Err() == nil {
		deviceID, installID, randomErr := newHongguoPlaybackDeviceIDs()
		device, err = hongguoPlaybackDevice{DeviceID: deviceID, InstallID: installID}, randomErr
	}
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	client.mu.Lock()
	if err == nil {
		client.playbackDevice = device
	}
	pending.device, pending.err = device, err
	client.devicePending = nil
	close(pending.done)
	client.mu.Unlock()
	return device, err
}

func (d *Downloader) registerHongguoPlaybackDevice(ctx context.Context) (hongguoPlaybackDevice, error) {
	openUDID, clientUDID, cdid, requestID := randomHex(8), uuidLike(), uuidLike(), uuidLike()
	if openUDID == "" || clientUDID == "" || cdid == "" || requestID == "" {
		return hongguoPlaybackDevice{}, errors.New("红果设备注册初始化失败")
	}
	now := time.Now()
	body, err := hongguoRegisterBody(openUDID, clientUDID, cdid, requestID, now)
	if err != nil {
		return hongguoPlaybackDevice{}, err
	}
	client := d.hongguoClient()
	client.mu.Lock()
	address := client.deviceRegisterURL
	client.mu.Unlock()
	query := url.Values{"req_id": {requestID}, "tt_data": {"a"}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, address+"?"+query.Encode(), bytes.NewReader(body))
	if err != nil {
		return hongguoPlaybackDevice{}, err
	}
	request.Header.Set("User-Agent", hongguoRegisterUserAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/octet-stream;tt-data=a")
	request.Header.Set("log-encode-type", "gzip")
	request.Header.Set("sdk-version", "2")
	request.Header.Set("passport-sdk-version", "5051452")
	request.Header.Set("x-vc-bdturing-sdk-version", "4.0.3.cn")
	request.Header.Set("x-ss-dp", "8662")
	request.Header.Set("x-ss-stub", hongguoRegisterStub(body))
	response, err := d.doCatalogRequestWithTimeout(request, 20*time.Second)
	if err != nil {
		return hongguoPlaybackDevice{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return hongguoPlaybackDevice{}, fmt.Errorf("红果设备注册 HTTP %d", response.StatusCode)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, (64<<10)+1))
	if err != nil {
		return hongguoPlaybackDevice{}, err
	}
	if len(content) > 64<<10 {
		return hongguoPlaybackDevice{}, errors.New("红果设备注册响应过大")
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if decoder.Decode(&result) != nil || result == nil {
		return hongguoPlaybackDevice{}, errors.New("红果设备注册返回格式异常")
	}
	if code := mapString(result, "code", "Code"); code != "" && code != "0" {
		return hongguoPlaybackDevice{}, fmt.Errorf("红果设备注册被拒绝（%s）", truncate(code, 20))
	}
	device := hongguoPlaybackDevice{
		DeviceID: mapString(result, "device_id_str", "device_id"), InstallID: mapString(result, "install_id_str", "install_id"), CDID: cdid,
	}
	for _, value := range []string{device.DeviceID, device.InstallID} {
		if !hongguoNumericID.MatchString(value) || strings.TrimLeft(value, "0") == "" {
			return hongguoPlaybackDevice{}, errors.New("红果设备注册未返回有效标识")
		}
	}
	return device, nil
}

func hongguoRegisterBody(openUDID, clientUDID, cdid, requestID string, now time.Time) ([]byte, error) {
	header := map[string]any{
		"display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
		"app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
		"app_version": "7.3.9.32", "version_code": 73932, "os": "Android", "os_version": "16", "os_api": 36,
		"device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi", "cpu_abi": "arm64-v8a",
		"language": "zh", "timezone": 8, "access": "wifi", "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
		"cdid": cdid, "openudid": openUDID, "clientudid": clientUDID, "ipv6_list": []any{}, "sim_serial_number": []any{},
		"oaid_may_support": false, "req_id": requestID, "device_platform": "android", "guest_mode": 0,
		"is_system_app": 0, "sdk_flavor": "china", "device_id": "0", "install_id": "0",
	}
	order := []string{"display_name", "update_version_code", "manifest_version_code", "app_version_minor", "aid", "channel", "package", "app_version", "version_code", "os", "os_version", "os_api", "device_model", "device_brand", "device_manufacturer", "cpu_abi", "language", "timezone", "access", "region", "tz_name", "tz_offset", "cdid", "openudid", "clientudid", "ipv6_list", "sim_serial_number", "oaid_may_support", "req_id", "device_platform", "guest_mode", "is_system_app", "sdk_flavor", "device_id", "install_id"}
	headerJSON, err := hongguoOrderedJSON(header, order)
	if err != nil {
		return nil, err
	}
	var payload bytes.Buffer
	payload.WriteString(`{"magic_tag":"ss_app_log","header":`)
	payload.Write(headerJSON)
	payload.WriteString(`,"_gen_time":`)
	payload.WriteString(strconv.FormatInt(now.UnixMilli(), 10))
	payload.WriteByte('}')
	var compressed bytes.Buffer
	writer, err := gzip.NewWriterLevel(&compressed, gzip.DefaultCompression)
	if err != nil {
		return nil, err
	}
	writer.Header.ModTime = now.UTC()
	writer.Header.OS = 255
	if _, err := writer.Write(payload.Bytes()); err != nil {
		writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return hongguoTTEncrypt(compressed.Bytes()), nil
}

func hongguoOrderedJSON(values map[string]any, order []string) ([]byte, error) {
	seen := map[string]bool{}
	keys := make([]string, 0, len(values))
	for _, key := range order {
		if _, ok := values[key]; ok {
			keys = append(keys, key)
			seen[key] = true
		}
	}
	rest := make([]string, 0)
	for key := range values {
		if !seen[key] {
			rest = append(rest, key)
		}
	}
	sort.Strings(rest)
	keys = append(keys, rest...)
	var out bytes.Buffer
	out.WriteByte('{')
	for i, key := range keys {
		if i > 0 {
			out.WriteByte(',')
		}
		keyJSON, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
		valueJSON, err := json.Marshal(values[key])
		if err != nil {
			return nil, err
		}
		out.Write(keyJSON)
		out.WriteByte(':')
		out.Write(valueJSON)
	}
	out.WriteByte('}')
	return out.Bytes(), nil
}
