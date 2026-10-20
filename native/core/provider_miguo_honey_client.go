package core

import (
	"compress/gzip"
	"compress/zlib"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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

const (
	sourceMiguoHoney    = "miguo-honey"
	miguoHoneyBaseURL   = "https://mitaoline.com"
	miguoHoneyReferer   = "https://honeypeach.cc/"
	miguoHoneyUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
)

type miguoHoneyAccess struct {
	sid     string
	key     []byte
	expires time.Time
}

type miguoHoneySession struct {
	mu      sync.Mutex
	device  string
	access  *miguoHoneyAccess
	pending chan struct{}
}

func miguoHoneyHash(text string) uint32 {
	hash := uint32(0x811c9dc5)
	for _, char := range text {
		hash = (hash ^ uint32(char)) * 0x01000193
	}
	return hash
}

func miguoHoneyProof(challenge, nonce string) uint32 {
	hash := miguoHoneyHash(challenge + ":" + nonce)
	for round := 0; round < 4; round++ {
		hash = miguoHoneyHash(fmt.Sprintf("%08x", hash) + challenge)
	}
	return hash
}

func miguoHoneySolve(ctx context.Context, challenge string, bits int) (string, error) {
	if challenge == "" || len(challenge) > 512 || bits < 0 || bits > 32 {
		return "", errors.New("蜜果握手挑战无效")
	}
	leading := uint(bits>>2) * 4
	for nonce := 0; nonce < 20000000; nonce++ {
		if nonce%256 == 0 {
			if err := ctx.Err(); err != nil {
				return "", err
			}
		}
		hexNonce := strconv.FormatInt(int64(nonce), 16)
		proof := miguoHoneyProof(challenge, hexNonce)
		if leading == 0 || uint64(proof)>>(32-leading) == 0 {
			return challenge + "." + hexNonce, nil
		}
	}
	return "", errors.New("蜜果握手挑战计算未完成，请稍后重试")
}

func (d *Downloader) miguoHoneyRaw(ctx context.Context, path string, values url.Values, headers map[string]string) ([]byte, int, error) {
	address := d.providerBaseURL(sourceMiguoHoney) + path
	if query := values.Encode(); query != "" {
		address += "?" + query
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("User-Agent", miguoHoneyUserAgent)
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
	request.Header.Set("Referer", miguoHoneyReferer)
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response, err := d.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	var reader io.Reader = response.Body
	var decompressor io.ReadCloser
	switch strings.ToLower(response.Header.Get("Content-Encoding")) {
	case "gzip":
		decompressor, err = gzip.NewReader(response.Body)
	case "deflate":
		decompressor, err = zlib.NewReader(response.Body)
	}
	if err != nil {
		return nil, response.StatusCode, errors.New("蜜果响应解压失败")
	}
	if decompressor != nil {
		defer decompressor.Close()
		reader = decompressor
	}
	payload, err := io.ReadAll(io.LimitReader(reader, providerMaxBodyBytes+1))
	if err != nil {
		return nil, response.StatusCode, err
	}
	if len(payload) > providerMaxBodyBytes {
		return nil, response.StatusCode, errors.New("蜜果响应内容过大")
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusUnauthorized {
		return nil, response.StatusCode, fmt.Errorf("蜜果接口 HTTP %d", response.StatusCode)
	}
	return payload, response.StatusCode, nil
}

func miguoHoneyJSON(payload []byte) (map[string]any, error) {
	var response map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.UseNumber()
	if decoder.Decode(&response) != nil || response == nil {
		return nil, errors.New("蜜果接口返回的数据无效")
	}
	if message := duanjuFindString(response, "error"); message != "" && message != "0" {
		return nil, fmt.Errorf("蜜果接口：%s", truncate(message, 200))
	}
	return response, nil
}

func (d *Downloader) miguoHoneyHandshake(ctx context.Context, device string) (*miguoHoneyAccess, error) {
	values := url.Values{"dev": {device}}
	payload, status, err := d.miguoHoneyRaw(ctx, "/api/handshake", values, nil)
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, errors.New("蜜果握手被拒绝")
	}
	response, err := miguoHoneyJSON(payload)
	if err != nil {
		return nil, err
	}
	if challenge := duanjuFindString(response, "need_chal"); challenge != "" {
		bits := 16
		if _, found := response["bits"]; found {
			bits = duanjuFindInt(response, "bits")
		}
		proof, err := miguoHoneySolve(ctx, challenge, bits)
		if err != nil {
			return nil, err
		}
		values.Set("c", proof)
		payload, status, err = d.miguoHoneyRaw(ctx, "/api/handshake", values, nil)
		if err != nil {
			return nil, err
		}
		if status != http.StatusOK {
			return nil, errors.New("蜜果握手验证失败")
		}
		response, err = miguoHoneyJSON(payload)
		if err != nil {
			return nil, err
		}
	}
	sid := duanjuFindString(response, "sid")
	key, err := hex.DecodeString(duanjuFindString(response, "skey"))
	expiry, expiryErr := strconv.ParseInt(duanjuFindString(response, "exp"), 10, 64)
	if sid == "" || len(sid) > 512 || strings.ContainsAny(sid, "\r\n") || err != nil || len(key) == 0 || expiryErr != nil || expiry <= time.Now().Unix() {
		return nil, errors.New("蜜果未返回有效的会话签名凭证")
	}
	return &miguoHoneyAccess{sid: sid, key: key, expires: time.Unix(expiry, 0)}, nil
}

func (d *Downloader) miguoHoneyCredentials(ctx context.Context) (*miguoHoneyAccess, error) {
	session := &d.miguoHoney
	for {
		session.mu.Lock()
		if access := session.access; access != nil && time.Now().Add(time.Minute).Before(access.expires) {
			session.mu.Unlock()
			return access, nil
		}
		if pending := session.pending; pending != nil {
			session.mu.Unlock()
			select {
			case <-pending:
				continue
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if session.device == "" {
			device, err := xiaopingguoRandom(32, "0123456789abcdef")
			if err != nil {
				session.mu.Unlock()
				return nil, err
			}
			session.device = device
		}
		pending, device := make(chan struct{}), session.device
		session.pending = pending
		session.mu.Unlock()
		access, err := d.miguoHoneyHandshake(ctx, device)
		session.mu.Lock()
		if err == nil {
			session.access = access
		}
		session.pending = nil
		close(pending)
		session.mu.Unlock()
		return access, err
	}
}

func miguoHoneySignature(path, query, timestamp, nonce string, access *miguoHoneyAccess) string {
	empty := sha256.Sum256(nil)
	canonical := strings.Join([]string{"GET", path, query, hex.EncodeToString(empty[:]), timestamp, nonce, access.sid}, "\n")
	signer := hmac.New(sha256.New, access.key)
	signer.Write([]byte(canonical))
	return hex.EncodeToString(signer.Sum(nil))
}

func (d *Downloader) miguoHoneyRequest(ctx context.Context, path string, values url.Values) (map[string]any, error) {
	for attempt := 0; attempt < 2; attempt++ {
		access, err := d.miguoHoneyCredentials(ctx)
		if err != nil {
			return nil, err
		}
		timestamp := strconv.FormatInt(time.Now().Unix(), 10)
		nonce, err := xiaopingguoRandom(24, "0123456789abcdef")
		if err != nil {
			return nil, err
		}
		payload, status, err := d.miguoHoneyRaw(ctx, path, values, map[string]string{
			"X-Hp-Sid": access.sid, "X-Hp-Ts": timestamp, "X-Hp-Nonce": nonce,
			"X-Hp-Sign": miguoHoneySignature(path, values.Encode(), timestamp, nonce, access),
		})
		if err != nil {
			return nil, err
		}
		if status == http.StatusUnauthorized {
			d.miguoHoney.mu.Lock()
			if d.miguoHoney.access == access {
				d.miguoHoney.access = nil
			}
			d.miguoHoney.mu.Unlock()
			continue
		}
		return miguoHoneyJSON(payload)
	}
	return nil, errors.New("蜜果会话已失效，重新握手后仍未获准访问")
}
