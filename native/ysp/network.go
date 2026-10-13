package ysp

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"time"
)

const browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

type upstreamError struct {
	Status int
	Host   string
}

func (e *upstreamError) Error() string { return fmt.Sprintf("%s HTTP %d", e.Host, e.Status) }

func safeError(err error) string {
	var request *url.Error
	if errors.As(err, &request) {
		return "上游连接失败：" + request.Err.Error()
	}
	return err.Error()
}

func directClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = (&net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	transport.MaxIdleConns = 48
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 10 * time.Second
	jar, _ := cookiejar.New(nil)
	return &http.Client{Transport: transport, Jar: jar, Timeout: 20 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 6 {
				return errors.New("央视频重定向次数过多")
			}
			if request.URL.Scheme != "http" && request.URL.Scheme != "https" {
				return errors.New("央视频播放地址协议无效")
			}
			return nil
		},
	}
}

func randomHex(size int) string {
	raw := make([]byte, size)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return hex.EncodeToString(raw)
}

func sha256Text(value string) string {
	result := sha256.Sum256([]byte(value))
	return hex.EncodeToString(result[:])
}

func fetch(ctx context.Context, client *http.Client, method, address string, body []byte, headers map[string]string, limit int64) ([]byte, string, http.Header, error) {
	uri, err := url.Parse(address)
	if err != nil || uri.Host == "" || (uri.Scheme != "http" && uri.Scheme != "https") {
		return nil, "", nil, errors.New("央视频地址无效")
	}
	request, err := http.NewRequestWithContext(ctx, method, address, bytes.NewReader(body))
	if err != nil {
		return nil, "", nil, err
	}
	request.Header.Set("User-Agent", browserUA)
	for key, value := range headers {
		if value != "" {
			request.Header.Set(key, value)
		}
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, "", nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, "", response.Header, &upstreamError{response.StatusCode, uri.Hostname()}
	}
	var reader io.Reader = response.Body
	if strings.EqualFold(response.Header.Get("Content-Encoding"), "gzip") {
		compressed, err := gzip.NewReader(response.Body)
		if err != nil {
			return nil, "", nil, err
		}
		defer compressed.Close()
		reader = compressed
	}
	raw, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, "", nil, err
	}
	if int64(len(raw)) > limit {
		return nil, "", nil, errors.New("央视频响应超过大小限制")
	}
	return raw, response.Request.URL.String(), response.Header, nil
}

func jsonRequest(ctx context.Context, client *http.Client, address string, value any, headers map[string]string) (map[string]any, error) {
	body, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	copyHeaders := cloneHeaders(headers)
	copyHeaders["Content-Type"] = "application/json; charset=utf-8"
	raw, _, _, err := fetch(ctx, client, "POST", address, body, copyHeaders, 2<<20)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err = json.Unmarshal(raw, &result); err != nil {
		return nil, errors.New("央视频返回的 JSON 无效")
	}
	return result, nil
}

func cloneHeaders(input map[string]string) map[string]string {
	result := make(map[string]string, len(input))
	for key, value := range input {
		result[key] = value
	}
	return result
}

func object(value any) map[string]any { result, _ := value.(map[string]any); return result }
func text(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case float64:
		return fmt.Sprintf("%.0f", value)
	case json.Number:
		return value.String()
	}
	return ""
}

func readPlaylist(ctx context.Context, client *http.Client, plan Plan) (string, string, error) {
	raw, address, _, err := fetch(ctx, client, "GET", plan.URL, nil, plan.Headers, 4<<20)
	if err != nil {
		return "", "", err
	}
	value := strings.TrimPrefix(string(raw), "\ufeff")
	if !strings.HasPrefix(strings.TrimSpace(value), "#EXTM3U") {
		return "", "", errors.New("央视频未返回有效播放列表")
	}
	return value, address, nil
}
